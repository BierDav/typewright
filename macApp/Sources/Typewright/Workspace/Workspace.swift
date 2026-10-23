import AppKit
import Observation
import PDFKit
import TypewrightCore
import UniformTypeIdentifiers

struct FileNode: Identifiable, Hashable {
    let url: URL
    let kind: FileKind
    let children: [FileNode]?
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isTypst: Bool { kind == .typst }
    var isPreviewable: Bool { Workspace.isPreviewable(url) }
}

struct RevealRequest: Equatable {
    let id = UUID()
    let line: Int
    let column: Int
    /// Characters selected from the column on, e.g. a search match.
    var length = 0
    /// Characters flashed from the column on without selecting them, e.g. a symbol jumped to.
    var marked = 0
    /// Previews reveal without taking the keyboard from the search field.
    var focus = true
}

/// One open space folder: files, buffers, autosave and compilation.
@MainActor @Observable
final class Workspace: EditorLanguage {
    let root: URL
    private(set) var tree: [FileNode] = []
    private(set) var selectedFile: URL?
    private(set) var selectedKind: FileKind?
    private(set) var text = ""
    private(set) var revision = 0
    /// The file compiled for the preview; nil hides the preview.
    private(set) var previewFile: URL?
    /// The file the preview last showed, brought back when it's shown again.
    private(set) var lastPreviewFile: URL?
    var split: Double { didSet { schedulePersist() } }
    /// Folders open in the sidebar; everything else starts collapsed.
    var expanded: Set<URL> = [] { didSet { schedulePersist() } }
    var reveal: RevealRequest? {
        // Jumps are remembered for going back, except right after a file switch, which already was.
        didSet { if let reveal, reveal.focus, !justSelected { recordJump() } }
    }

    /// Each file keeps its own format; files never previewed before use the last one picked.
    var renderMode: RenderMode {
        didSet {
            if renderMode == .svg { renderMode = .pdf }
            // Switching files brings their format along; `setPreview` does the rest.
            guard !isFollowingFile else { return }
            UserDefaults.standard.set(renderMode.rawValue, forKey: "renderMode")
            // The new format opens where the old one was.
            capturePreviewState(mode: oldValue)
            if let previewFile { positions[previewFile, default: DocumentPosition()].mode = renderMode }
            schedulePersist()
            // Output from the last time a format was shown is stale; it would flash an older document.
            html = nil
            htmlPreview.clear()
            restorePreviews(for: previewFile)
            invalidateCompile()
            scheduleCompile(delay: 0)
        }
    }
    private(set) var document: PDFDocument?
    private(set) var html: String?
    /// The previewed Markdown file as HTML.
    private(set) var markdownHTML: String?
    private(set) var diagnostics: [Diagnostic] = []
    /// Universe packages imported at an older version; shown while the package list could be fetched.
    var packageDiagnostics: [Diagnostic] {
        guard PackageLibrary.shared.isOnline, selectedKind == .typst, let file = selectedFile, let path = relative(file) else {
            return []
        }
        let source = text as NSString
        let library = PackageLibrary.shared
        return PackageLibrary.upgrades(in: text) { library.latestVersion(namespace: "preview", name: $0) }.map { upgrade in
            let (line, column) = Self.lineAndColumn(of: upgrade.range.location, in: source)
            return Diagnostic(path: path, line: line + 1, column: column + 1, severity: .warning,
                              message: "Package \(upgrade.spec) can be updated to \(upgrade.latest).",
                              length: upgrade.range.length)
        }
    }
    /// Compiler output when compilation failed without diagnostics.
    private(set) var failureLog: String?
    private(set) var isCompiling = false
    private(set) var lastDuration: TimeInterval?

    /// Find and replace in the editor.
    @ObservationIgnored let find = FindModel()
    @ObservationIgnored let preview = PreviewController()
    @ObservationIgnored let htmlPreview = HTMLPreviewController()
    @ObservationIgnored let markdownPreview = HTMLPreviewController(markdown: true)
    /// Shows a selected PDF file instead of the compiled document.
    @ObservationIgnored let filePreview = PreviewController()
    /// Shows a selected image file.
    @ObservationIgnored let imagePreview = ImagePreviewController()
    /// Shares the shown file with the account's other devices while they have it open too.
    let live: LiveEditing
    private var buffers: [URL: String] = [:]
    private var dirty: Set<URL> = []

    /// Edits not yet on disk, for searches that read files.
    var unsavedBuffers: [URL: String] { buffers.filter { dirty.contains($0.key) || $0.key == selectedFile } }
    private var compileTask: Task<Void, Never>?
    /// Bumped on new work so an old preview never interrupts newer edits.
    private var generation = 0
    private var compileRunning = false
    private var compileQueued = false
    private let exportRunner = TypstRunner()
    @ObservationIgnored private let builtin: BuiltinCompiler
    @ObservationIgnored private var watcher: TypstWatcher?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var editorStates: [URL: EditorState] = [:]
    @ObservationIgnored private var previewStates: [URL: PreviewState] = [:]
    /// Where each previewed file was left, shared by its formats.
    @ObservationIgnored private var positions: [URL: DocumentPosition] = [:]
    @ObservationIgnored private var isFollowingFile = false
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    /// Font folders passed to every compiler, see `FontLibrary`.
    @ObservationIgnored private var fontDirs: [URL] = []
    @ObservationIgnored private var fontObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var language: LanguageClient?
    @ObservationIgnored private var languageObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var packageObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var syncObservers: [any NSObjectProtocol] = []
    /// File tree changes with undo; its undo manager is the window's.
    @ObservationIgnored lazy var fileOps = FileOperations(workspace: self)
    /// The note after a deletion, offering undo.
    var notice: FileNotice?
    /// Images pasted into the editor, removed again when undo takes their reference out.
    @ObservationIgnored var pastedImages: [PastedImage] = []

    init(url: URL, session: WorkspaceSession? = nil) {
        let url = url.standardizedFileURL
        root = Self.root(of: url)
        let isDir = root == url
        builtin = BuiltinCompiler(root: root)
        live = LiveEditing(root: root)
        renderMode = UserDefaults.standard.string(forKey: "renderMode").flatMap(RenderMode.init)?.migrated ?? .pdf

        let saved = session?.state ?? SpaceStore.state(for: root)
        let state = saved ?? SpaceState()
        buffers = session?.buffers ?? [:]
        split = state.split
        reloadTree()
        let base = root
        func resolve(_ path: String?) -> URL? {
            guard let path else { return nil }
            let url = base.appendingPathComponent(path).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        editorStates = Dictionary(state.editors.compactMap { k, v in resolve(k).map { ($0, v) } }) { a, _ in a }
        previewStates = Dictionary(state.previews.compactMap { k, v in resolve(k).map { ($0, v) } }) { a, _ in a }
        positions = Dictionary(state.positions.compactMap { k, v in resolve(k).map { ($0, v) } }) { a, _ in a }
        expanded = Set(state.expanded.compactMap(resolve))
        let initial = isDir ? resolve(state.selected) ?? defaultMain() : url
        if let initial { select(initial) }
        // New spaces start out previewing their main file; known ones keep their choice, even none.
        if saved == nil {
            previewFile = initial?.pathExtension == "typ" ? initial : defaultMain()
        } else {
            previewFile = resolve(state.preview)
        }
        lastPreviewFile = resolve(state.lastPreview) ?? previewFile
        followPreviewMode()
        if fontFolders != fontDirs { updateFonts() }
        restorePreviews(for: previewFile)
        live.currentText = { [weak self] in self?.text ?? "" }
        live.replaceText = { [weak self] new in
            guard let self, let url = self.selectedFile else { return }
            self.updateBuffer(url, text: new)
            self.reloadEditorIfNeeded()
        }
        startLive()
        Self.open.append(WeakWorkspace(self))
        fontObserver = NotificationCenter.default.addObserver(forName: FontLibrary.didChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateFonts()
                self?.restartWatcher()
                self?.restartLanguageServer()
            }
        }
        // Sync merges with what's on disk, so pending edits go there first.
        // Notifications carry the space root; bridged URLs never match an `object:` filter.
        let root = root
        syncObservers = [
            NotificationCenter.default.addObserver(forName: SyncService.willChangeFiles, object: nil, queue: .main) { [weak self] note in
                guard (note.object as? URL)?.standardizedFileURL == root else { return }
                MainActor.assumeIsolated { self?.flushSaves() }
            },
            NotificationCenter.default.addObserver(forName: SyncService.didChangeFiles, object: nil, queue: .main) { [weak self] note in
                guard (note.object as? URL)?.standardizedFileURL == root else { return }
                MainActor.assumeIsolated { self?.refreshFromDisk() }
            },
            // Restores, resolves and repairs of a stale working copy rewrite files under open editors.
            NotificationCenter.default.addObserver(forName: SpaceRepository.didCommit, object: nil, queue: .main) { [weak self] note in
                guard note.userInfo?["wrote"] as? Bool == true else { return }
                let changed = note.userInfo?["changed"] as? [String] ?? []
                MainActor.assumeIsolated {
                    guard let space = SpaceRepository.shared.relativePath(of: root),
                          changed.isEmpty || changed.contains(where: { $0.hasPrefix(space + "/") })
                    else { return }
                    self?.refreshFromDisk()
                }
            },
            NotificationCenter.default.addObserver(forName: SyncService.syncedSpacesDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.live.close()
                    self?.startLive()
                }
            },
        ]
        languageObserver = NotificationCenter.default.addObserver(forName: LanguageServerManager.didChange, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartLanguageServer() }
        }
        packageObserver = NotificationCenter.default.addObserver(forName: PackageLibrary.didChange, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Failed imports are cached until the package shows up.
                self?.builtin.reset()
                self?.restartWatcher()
                self?.scheduleCompile(delay: 0)
            }
        }
    }

    /// Whether the previewed file is Markdown, which renders without a compiler.
    var previewIsMarkdown: Bool { previewFile.map(MarkdownRenderer.isMarkdown) ?? false }

    /// Typst and Markdown files can be previewed.
    nonisolated static func isPreviewable(_ url: URL) -> Bool { url.pathExtension == "typ" || MarkdownRenderer.isMarkdown(url) }

    /// Whether the compiled output for the current render mode is available.
    var hasOutput: Bool {
        if previewIsMarkdown { return markdownHTML != nil }
        return switch renderMode {
        case .pdf, .svg: document != nil
        case .html: html != nil
        }
    }

    var name: String { root.lastPathComponent }

    func isInSpace(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(root.path + "/") }

    /// Path from the space folder, like `sub/chapter.typ`.
    func relativePath(of url: URL) -> String { relative(url) ?? url.path }

    /// A folder's name, or the space's name for its root.
    func displayName(of dir: URL) -> String { dir.standardizedFileURL == root ? name : dir.lastPathComponent }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// The editor's selection (UTF-16), for the status bar.
    private(set) var selection = NSRange(location: 0, length: 0)

    /// Line and column of the caret, both from 1, and what the selection spans.
    var caret: (line: Int, column: Int, lines: Int, characters: Int, words: Int) {
        let s = text as NSString
        let start = min(selection.location, s.length), end = min(NSMaxRange(selection), s.length)
        var line = 1, lineStart = 0
        for i in 0..<start where s.character(at: i) == 10 {
            line += 1
            lineStart = i + 1
        }
        let column = s.substring(with: NSRange(location: lineStart, length: start - lineStart)).count + 1
        let selected = s.substring(with: NSRange(location: start, length: end - start))
        let lines = selected.isEmpty ? 0 : selected.split(omittingEmptySubsequences: false) { $0.isNewline }.count
        return (line, column, lines, selected.count, selected.split { $0.isWhitespace || $0.isNewline }.count)
    }

    // MARK: - Files

    func reloadTree() {
        tree = Self.scan(root, depth: 0)
        // New, removed or renamed files must reach the built-in compiler too.
        builtin.reset()
        // Fonts may have been added to the space's font folders.
        updateFonts()
    }

    /// Font folders are looked up from the previewed file's folder up, so a chapter's own fonts count too.
    private var fontFolders: [URL] {
        let folder = previewFile.map { $0.deletingLastPathComponent() }.flatMap { isInSpace($0) ? $0 : nil } ?? root
        return FontLibrary.shared.directories(for: folder)
    }

    private func updateFonts() {
        fontDirs = fontFolders
        htmlPreview.setFontDirectories(fontDirs)
        builtin.setFontPaths(fontDirs) { [weak self] in self?.scheduleCompile(delay: 0) }
        if let watcher, watcher.fontPaths != fontDirs { restartWatcher() }
    }

    /// `typst watch` only scans fonts at launch.
    private func restartWatcher() {
        guard watcher != nil else { return }
        stopWatcher()
        scheduleCompile(delay: 0)
    }

    func select(_ url: URL) {
        guard url != selectedFile else { return }
        let kind = FileKind(url: url)
        guard kind.isOpenable else { return }
        recordJump()
        justSelected = true
        DispatchQueue.main.async { [weak self] in self?.justSelected = false }
        captureFileState()
        flushSaves()
        solvengContextCache = nil
        selectedFile = url
        selectedKind = kind
        if kind.isEditable {
            text = buffers[url] ?? Self.read(url) ?? ""
            buffers[url] = text
        } else {
            text = ""
        }
        if kind == .pdf {
            // Each PDF reopens where it was left; new ones start at the top.
            filePreview.pendingRestore = previewStates[url] ?? PreviewState()
            filePreview.show(PDFDocument(url: url), keepingPosition: false)
        }
        if kind == .image { imagePreview.show(url) }
        if kind == .typst { languageClient()?.open(url, text: text) }
        revision += 1
        schedulePersist()
        startLive()
        updateSolvengDiagnostics()
        scheduleSolvengCheck(delay: 0)
    }

    // MARK: - Navigation history

    struct NavigationPoint: Equatable {
        let url: URL
        let location: Int
    }

    @ObservationIgnored private var backHistory: [NavigationPoint] = []
    @ObservationIgnored private var forwardHistory: [NavigationPoint] = []
    @ObservationIgnored private var isNavigating = false
    @ObservationIgnored private var justSelected = false

    private var caretPoint: NavigationPoint? {
        guard let file = selectedFile, selectedKind?.isEditable == true else { return nil }
        return NavigationPoint(url: file, location: selection.location)
    }

    /// Remembers where the caret was (or `location` in the shown file) before a jump, for `goBack`.
    func recordJump(from location: Int? = nil) {
        guard !isNavigating, var point = caretPoint else { return }
        if let location { point = NavigationPoint(url: point.url, location: location) }
        guard backHistory.last != point else { return }
        backHistory.append(point)
        if backHistory.count > 100 { backHistory.removeFirst() }
        forwardHistory.removeAll()
    }

    /// Moves the caret to where it was before the last jump, across files; mouse button 4 and ⌃⌘←.
    func goBack() { navigate(back: true) }

    func goForward() { navigate(back: false) }

    private func navigate(back: Bool) {
        while let target = back ? backHistory.popLast() : forwardHistory.popLast() {
            guard FileManager.default.fileExists(atPath: target.url.path) else { continue }
            if let current = caretPoint {
                if back { forwardHistory.append(current) } else { backHistory.append(current) }
            }
            isNavigating = true
            defer { isNavigating = false }
            select(target.url)
            guard selectedFile == target.url else { return }
            let source = text as NSString
            let (line, column) = Self.lineAndColumn(of: min(target.location, source.length), in: source)
            reveal = RevealRequest(line: line + 1, column: column + 1)
            return
        }
        NSSound.beep()
    }

    /// Live editing covers the shown text file of a synced space; it's (re)started on selection and sync changes.
    func startLive() {
        guard selectedKind?.isEditable == true, let file = selectedFile else { return live.close() }
        live.open(relative(file), text: text)
    }

    func reveal(_ diagnostic: Diagnostic) {
        guard !diagnostic.isFromPackage else { return }
        select(root.appendingPathComponent(diagnostic.path).standardizedFileURL)
        reveal = RevealRequest(line: diagnostic.line, column: diagnostic.column)
    }

    func togglePreview(_ url: URL) {
        setPreview(previewFile == url ? nil : url)
    }

    /// ⌘- hides the preview, and showing it again brings back the file it last showed.
    func togglePreviewVisibility() {
        guard previewFile == nil else { return setPreview(nil) }
        let remembered = [lastPreviewFile, selectedFile, defaultMain()]
            .compactMap { $0 }
            .first { isInSpace($0) && Self.isPreviewable($0) && FileManager.default.fileExists(atPath: $0.path) }
        guard let remembered else { return NSSound.beep() }
        setPreview(remembered)
    }

    /// ⇧⌘- switches the preview to the selected file.
    func previewSelectedFile() {
        guard let file = selectedFile, Self.isPreviewable(file) else { return NSSound.beep() }
        setPreview(file)
    }

    func setPreview(_ url: URL?) {
        guard url != previewFile else { return }
        capturePreviewState()
        previewFile = url
        if let url { lastPreviewFile = url }
        followPreviewMode()
        if fontFolders != fontDirs { updateFonts() }
        document = nil
        html = nil
        markdownHTML = nil
        preview.clear()
        htmlPreview.clear()
        markdownPreview.clear()
        failureLog = nil
        diagnostics = []
        lastDuration = nil
        restorePreviews(for: url)
        invalidateCompile()
        scheduleCompile(delay: 0)
        schedulePersist()
    }

    // MARK: - View state

    func editorState(for url: URL?) -> EditorState? {
        url.flatMap { editorStates[$0] }
    }

    func editorStateDidChange(_ state: EditorState) {
        let range = NSRange(location: state.selection, length: state.length)
        live.selectionDidChange(range)
        if selection != range { selection = range }
        guard let url = selectedFile, editorStates[url] != state else { return }
        editorStates[url] = state
        schedulePersist()
    }

    /// Zoom and position of a PDF shown as a file; kept with the compiled previews' states, keyed by the PDF.
    private func captureFileState() {
        guard let file = selectedFile, selectedKind == .pdf, let state = filePreview.state() else { return }
        previewStates[file] = state
    }

    /// Scroll offset of a font file's specimen.
    func fontOffset(for url: URL) -> Double { previewStates[url]?.y ?? 0 }

    func fontDidScroll(_ url: URL, to offset: Double) {
        guard previewStates[url]?.y != offset else { return }
        previewStates[url] = PreviewState(y: offset)
        schedulePersist()
    }

    /// Remembers where the preview in `mode` (by default the current one) shows the previewed file.
    private func capturePreviewState(mode: RenderMode? = nil) {
        guard let main = previewFile else { return }
        var position = positions[main] ?? DocumentPosition()
        if previewIsMarkdown {
            guard markdownHTML != nil, markdownPreview.pendingRestore == nil else { return }
            position.flow = markdownPreview.position().flow
            positions[main] = position
            return
        }
        // Only a preview that already shows this file's output, and isn't about to jump elsewhere, knows where it is.
        switch mode ?? renderMode {
        case .pdf, .svg:
            guard document != nil, preview.view.document === document, preview.pendingPosition == nil,
                  let shown = preview.position() else { return }
            position.page = shown.page
            position.zoom = shown.zoom
            position.pan = shown.pan
        case .html:
            guard html != nil, htmlPreview.pendingRestore == nil else { return }
            let shown = htmlPreview.position()
            if htmlPreview.paged {
                position.page = shown.page
                position.zoom = shown.zoom
                position.pan = shown.pan
            } else {
                position.flow = shown.flow
            }
        }
        positions[main] = position
    }

    /// Takes on the format the previewed file was last shown in.
    private func followPreviewMode() {
        guard let file = previewFile, !previewIsMarkdown else { return }
        let mode = (positions[file]?.mode ?? UserDefaults.standard.string(forKey: "renderMode").flatMap(RenderMode.init) ?? .pdf).migrated
        guard mode != renderMode else { return }
        isFollowingFile = true
        renderMode = mode
        isFollowingFile = false
    }

    /// Every preview jumps to where `url` was left once its output arrives; new files start at the top.
    private func restorePreviews(for url: URL?) {
        guard let url else { return }
        let position = positions[url] ?? DocumentPosition()
        preview.pendingRestore = nil
        preview.pendingPosition = position
        htmlPreview.pendingRestore = position
        markdownPreview.pendingRestore = position
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    func session() -> WorkspaceSession {
        capturePreviewState()
        captureFileState()
        var state = SpaceState()
        state.selected = selectedFile.flatMap(relative)
        state.preview = previewFile.flatMap(relative)
        state.lastPreview = lastPreviewFile.flatMap(relative)
        state.split = split
        for (url, s) in editorStates { if let key = relative(url) { state.editors[key] = s } }
        for (url, s) in previewStates { if let key = relative(url) { state.previews[key] = s } }
        for (url, s) in positions { if let key = relative(url) { state.positions[key] = s } }
        state.expanded = expanded.compactMap(relative).sorted()
        if let file = previewFile.flatMap(relative), !previewIsMarkdown {
            state.positions[file, default: DocumentPosition()].mode = renderMode
        }
        return WorkspaceSession(state: state, buffers: buffers)
    }

    func persist() {
        SpaceStore.save(session().state, for: root)
    }

    /// Picks up edits made by other apps for files without pending changes.
    func refreshFromDisk() {
        reloadTree()
        solvengContextCache = nil
        for url in buffers.keys where !dirty.contains(url) {
            buffers[url] = nil
        }
        if let selected = selectedFile, selectedKind?.isEditable == true, !dirty.contains(selected),
           let disk = Self.read(selected), disk != text {
            text = disk
            buffers[selected] = disk
            revision += 1
            live.textDidChange()
        }
        if let selected = selectedFile, selectedKind == .pdf {
            filePreview.show(PDFDocument(url: selected))
        }
        // Quick Look caches the document; a new revision makes a fresh preview.
        if selectedKind == .document { revision += 1 }
        scheduleCompile(delay: 0)
    }

    @discardableResult
    func createFile(in dir: URL? = nil, named name: String? = nil) -> URL {
        // A name without an extension becomes a Typst file.
        let typed = name?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-") ?? ""
        let base = typed.isEmpty ? "untitled" : (typed as NSString).deletingPathExtension
        let ext = typed.isEmpty || (typed as NSString).pathExtension.isEmpty ? "typ" : (typed as NSString).pathExtension
        let url = Self.unique(in: dir ?? root, name: base, ext: ext)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        reloadTree()
        select(url)
        recordCreation([url], name: "New File", verb: "Add")
        return url
    }

    @discardableResult
    func createFolder(in dir: URL? = nil, named name: String? = nil) -> URL {
        let typed = name?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-") ?? ""
        let url = Self.unique(in: dir ?? root, name: typed.isEmpty ? "New Folder" : typed, ext: nil)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        reloadTree()
        recordCreation([url], name: "New Folder", verb: "Add")
        return url
    }

    /// A copy next to the original, named like Finder's ("name copy.ext").
    @discardableResult
    func duplicate(_ url: URL) -> URL? {
        flushSaves()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let ext = isDir.boolValue || url.pathExtension.isEmpty ? nil : url.pathExtension
        let base = (ext == nil ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent) + " copy"
        let target = Self.unique(in: url.deletingLastPathComponent(), name: base, ext: ext)
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
        reloadTree()
        if !isDir.boolValue { select(target) }
        let repo = SpaceRepository.shared
        fileOps.performed(inverse: .delete([target]), name: "Duplicate “\(url.lastPathComponent)”",
                          message: "Duplicate \(repo.messagePath(url)) as \(repo.messagePath(target))")
        return target
    }

    /// Undo for new items deletes them; in spaces outside the library there's no history, so no undo.
    private func recordCreation(_ urls: [URL], name: String, verb: String) {
        guard SpaceList.isInRepository(root), !urls.isEmpty else { return }
        let paths = urls.map(SpaceRepository.shared.messagePath).joined(separator: ", ")
        fileOps.performed(inverse: .delete(urls), name: name, message: "\(verb) \(paths)")
    }

    /// Renames a file or folder and moves buffers, selection, preview and saved state along.
    func rename(_ url: URL, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != url.lastPathComponent else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        // Case-only renames hit the same file on case-insensitive volumes.
        let caseOnly = target.path.lowercased() == url.path.lowercased()
        guard caseOnly || !FileManager.default.fileExists(atPath: target.path) else { return }
        guard relocate(url, to: target) else { return }
        recordMove(url, to: target, name: "Rename “\(url.lastPathComponent)”", verb: "Rename")
    }

    private func recordMove(_ url: URL, to target: URL, name: String, verb: String) {
        guard SpaceList.isInRepository(root) else { return }
        let repo = SpaceRepository.shared
        fileOps.performed(inverse: .move([FileOp.Move(from: target, to: url)]), name: name,
                          message: "\(verb) \(repo.messagePath(url)) to \(repo.messagePath(target))")
    }

    /// Whether `url` can be moved into the folder `dir`.
    func canMove(_ url: URL, into dir: URL) -> Bool {
        dir.path != url.deletingLastPathComponent().path && dir.path != url.path && !dir.path.hasPrefix(url.path + "/")
            && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(url.lastPathComponent).path)
    }

    /// Moves a file or folder into `dir`, keeping its name.
    func move(_ url: URL, into dir: URL) {
        guard canMove(url, into: dir) else { return NSSound.beep() }
        let target = dir.appendingPathComponent(url.lastPathComponent).standardizedFileURL
        guard relocate(url, to: target) else { return }
        if dir.path != root.path { expanded.insert(dir.standardizedFileURL) }
        recordMove(url, to: target, name: "Move “\(url.lastPathComponent)”", verb: "Move")
    }

    /// Moves (or copies) files dropped from other apps into `dir`; name clashes get a number, like Finder.
    func importItems(_ urls: [URL], into dir: URL, copy: Bool) {
        let fm = FileManager.default
        var imported: [(url: URL, isDir: Bool)] = []
        var inverses: [FileOp] = []
        for url in urls.map(\.standardizedFileURL) {
            // Items already in the space move like tree drags.
            if url.path.hasPrefix(root.path + "/") {
                if canMove(url, into: dir) {
                    let target = dir.appendingPathComponent(url.lastPathComponent).standardizedFileURL
                    if relocate(url, to: target) { inverses.append(.move([FileOp.Move(from: target, to: url)])) }
                }
                continue
            }
            guard url.path != root.path, !root.path.hasPrefix(url.path + "/") else { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let ext = isDir.boolValue || url.pathExtension.isEmpty ? nil : url.pathExtension
            let target = Self.unique(in: dir, name: ext == nil ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent,
                                     ext: ext)
            do {
                if copy { try fm.copyItem(at: url, to: target) } else { try fm.moveItem(at: url, to: target) }
                imported.append((target, isDir.boolValue))
                // Undo takes copies away and puts moved items back where they came from.
                inverses.append(copy ? .delete([target]) : .moveExternal([FileOp.Move(from: target, to: url)]))
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if dir.path != root.path, !inverses.isEmpty { expanded.insert(dir.standardizedFileURL) }
        reloadTree()
        if imported.count == 1, let file = imported.first, !file.isDir { select(file.url) }
        schedulePersist()
        guard SpaceList.isInRepository(root), !inverses.isEmpty else { return }
        let names = urls.map(\.lastPathComponent)
        let name = names.count == 1 ? "Add “\(names[0])”" : "Add \(names.count) Items"
        let paths = imported.map { SpaceRepository.shared.messagePath($0.url) }
        fileOps.performed(inverse: .batch(inverses.reversed()), name: name,
                          message: paths.isEmpty ? "Move \(names.joined(separator: ", "))" : "Add \(paths.joined(separator: ", "))")
    }

    /// Saves images on the pasteboard next to the shown Typst or Markdown file and returns the text that shows them.
    /// Text on the pasteboard wins over a picture, except for copied image files.
    func pasteImage(from pasteboard: NSPasteboard) -> String? {
        guard let file = selectedFile else { return nil }
        let markdown = MarkdownRenderer.isMarkdown(file)
        guard markdown || selectedKind == .typst else { return nil }
        let dir = file.deletingLastPathComponent()
        let fm = FileManager.default
        var saved: [URL] = []
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !files.isEmpty {
            for url in files {
                let target = Self.unique(in: dir, name: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
                do { try fm.copyItem(at: url, to: target); saved.append(target) } catch { NSAlert(error: error).runModal() }
            }
        } else if pasteboard.string(forType: .string) == nil, let (data, ext) = Self.imageData(on: pasteboard) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let target = Self.unique(in: dir, name: "image-\(formatter.string(from: Date()))", ext: ext)
            do { try data.write(to: target); saved.append(target) } catch { NSAlert(error: error).runModal() }
        }
        guard !saved.isEmpty else { return nil }
        reloadTree()
        let references = saved.map { url in
            let name = url.lastPathComponent
            if markdown { return "![](\(name.contains(" ") ? "<\(name)>" : name))" }
            return "#image(\"\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\")"
        }
        if SpaceList.isInRepository(root) {
            for (url, reference) in zip(saved, references) {
                pastedImages.append(PastedImage(file: url, document: file, reference: reference))
            }
            pastedImages = pastedImages.suffix(20)
            let paths = saved.map(SpaceRepository.shared.messagePath).joined(separator: ", ")
            Task { await SpaceRepository.shared.commit("Add \(paths)") }
        }
        return references.joined(separator: "\n")
    }

    /// PNG and JPEG are written as they are; everything else (screenshots arrive as TIFF) becomes PNG.
    private static func imageData(on pasteboard: NSPasteboard) -> (Data, String)? {
        if let png = pasteboard.data(forType: .png) { return (png, "png") }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) { return (jpeg, "jpg") }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png")
    }

    /// Deletes a file or folder; in the library that's a commit, undone through the history (there's no trash).
    /// Outside it the item goes to the Trash as before.
    func delete(_ url: URL) { delete([url]) }

    func delete(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        flushSaves()
        guard SpaceList.isInRepository(root) else {
            for url in urls {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { NSAlert(error: error).runModal() }
            }
            forgetRemoved(urls)
            return
        }
        let repo = SpaceRepository.shared
        let title = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) Items"
        let paths = urls.map(repo.messagePath).joined(separator: ", ")
        fileOps.perform(.delete(urls), name: "Delete \(title)", message: "Delete \(paths)")
        // The tree drops the rows at once; the commit follows.
        forgetRemoved(urls, onDisk: false)
        notice = FileNotice(text: "Deleted \(title)", folder: urls.count == 1 ? urls[0].deletingLastPathComponent() : root)
    }

    /// Drops buffers, selection, preview and tree rows that pointed into removed items.
    func forgetRemoved(_ urls: [URL], onDisk: Bool = true) {
        func gone(_ u: URL) -> Bool { urls.contains { u == $0 || u.path.hasPrefix($0.path + "/") } }
        buffers = buffers.filter { !gone($0.key) }
        dirty = dirty.filter { !gone($0) }
        editorStates = editorStates.filter { !gone($0.key) }
        previewStates = previewStates.filter { !gone($0.key) }
        positions = positions.filter { !gone($0.key) }
        expanded = expanded.filter { !gone($0) }
        if onDisk { reloadTree() } else { tree = Self.removing(tree, where: gone) }
        if let file = previewFile, gone(file) { setPreview(nil) }
        lastPreviewFile = lastPreviewFile.flatMap { gone($0) ? nil : $0 }
        if let file = selectedFile, gone(file) {
            selectedFile = nil
            selectedKind = nil
            text = ""
            revision += 1
            if let main = defaultMain(), !gone(main) { select(main) }
        }
        schedulePersist()
    }

    private static func removing(_ nodes: [FileNode], where gone: (URL) -> Bool) -> [FileNode] {
        nodes.filter { !gone($0.url) }.map { node in
            FileNode(url: node.url, kind: node.kind, children: node.children.map { removing($0, where: gone) })
        }
    }

    /// Undo's moves: `relocate` without registering another undo; the target's folder is made if it went away.
    func relocateForUndo(_ url: URL, to target: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: target.path)
                || target.path.lowercased() == url.path.lowercased() else { return false }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return relocate(url, to: target)
    }

    @discardableResult
    private func relocate(_ url: URL, to target: URL) -> Bool {
        flushSaves()
        guard let references = referenceEdits(moving: url, to: target) else { return false }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        // Shares at or inside the moved item follow it instead of losing their folder.
        SpaceRepository.shared.noteMoved(from: url, to: target)
        func moved(_ u: URL) -> URL {
            if u == url { return target }
            guard u.path.hasPrefix(url.path + "/") else { return u }
            return URL(fileURLWithPath: target.path + u.path.dropFirst(url.path.count)).standardizedFileURL
        }
        func remap<V>(_ d: [URL: V]) -> [URL: V] {
            Dictionary(d.map { (moved($0.key), $0.value) }) { a, _ in a }
        }
        buffers = remap(buffers)
        editorStates = remap(editorStates)
        previewStates = remap(previewStates)
        positions = remap(positions)
        selectedFile = selectedFile.map(moved)
        expanded = Set(expanded.map(moved))
        if let file = previewFile, moved(file) != file {
            previewFile = moved(file)
            scheduleCompile(delay: 0)
        }
        if let file = lastPreviewFile, moved(file) != file {
            lastPreviewFile = moved(file)
        }
        reloadTree()
        // Paths in the space's files follow the move.
        for (file, edits) in references {
            let file = moved(file)
            guard let text = bufferText(file) else { continue }
            updateBuffer(file, text: applyTextEdits(edits: edits, text: text))
        }
        if !references.isEmpty { flushSaves() }
        schedulePersist()
        return true
    }

    /// Edits that keep the space's paths pointing at `url` once it moves to `target`, keyed by the files before the move.
    /// Paths that might not be references, like ones in comments or passed to other functions, are up to the user;
    /// nil when they cancel the move.
    private func referenceEdits(moving url: URL, to target: URL) -> [URL: [TypewrightCore.TextEdit]]? {
        guard let from = relative(url), let to = relative(target) else { return [:] }
        var found: [(file: URL, text: String, reference: PathReference)] = []
        for node in Self.flatten(tree) where node.isTypst {
            guard let path = relative(node.url), let text = bufferText(node.url) else { continue }
            let references = movedPathReferences(text: text, file: path, from: from, to: to, exists: ExistsIn(root))
            found += references.map { (node.url, text, $0) }
        }
        let unsure = found.indices.filter { !found[$0].reference.certain }
        var skipped = Set<Int>()
        if !unsure.isEmpty {
            guard let chosen = confirmReferences(unsure.map { found[$0] }, moving: url) else { return nil }
            skipped = Set(unsure.enumerated().filter { !chosen.contains($0.offset) }.map(\.element))
        }
        var edits: [URL: [TypewrightCore.TextEdit]] = [:]
        for (index, item) in found.enumerated() where !skipped.contains(index) {
            edits[item.file, default: []].append(TypewrightCore.TextEdit(range: item.reference.range, newText: item.reference.newPath))
        }
        return edits
    }

    /// Asks which of the uncertain references to update; nil cancels the move.
    private func confirmReferences(_ items: [(file: URL, text: String, reference: PathReference)], moving url: URL) -> Set<Int>? {
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? "Update this path to “\(url.lastPathComponent)”?"
            : "Update these paths to “\(url.lastPathComponent)”?"
        alert.informativeText = "They look like paths to it, but sit in comments, raw text or calls to functions that may "
            + "resolve paths differently, like ones from packages. Imports, includes and images are updated either way."
        let boxes = items.map { item in
            let line = Self.lineText(Int(item.reference.line), in: item.text as NSString).trimmingCharacters(in: .whitespaces)
            let title = "\(relative(item.file) ?? item.file.lastPathComponent):\(item.reference.line + 1)  \(line)"
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = item.reference.inComment ? .off : .on
            box.lineBreakMode = .byTruncatingTail
            box.toolTip = "\(item.reference.oldPath) → \(item.reference.newPath)"
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.frame.size = stack.fittingSize
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: min(stack.fittingSize.height, 220)))
        scroll.documentView = stack
        scroll.hasVerticalScroller = stack.fittingSize.height > 220
        scroll.drawsBackground = false
        boxes.forEach { $0.widthAnchor.constraint(lessThanOrEqualToConstant: 370).isActive = true }
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Set(boxes.indices.filter { boxes[$0].state == .on })
    }

    private static func unique(in dir: URL, name: String, ext: String?) -> URL {
        let file = uniqueName(name: name, ext: ext, exists: ExistsIn(dir))
        return dir.appendingPathComponent(file).standardizedFileURL
    }

    // MARK: - Editing

    /// `live` edits (color wheel drags) compile at once so the preview keeps up.
    func textDidChange(_ newText: String, live: Bool) {
        guard let url = selectedFile else { return }
        text = newText
        buffers[url] = newText
        siblings.forEach { $0.siblingDidEdit(url, text: newText) }
        self.live.textDidChange()
        if selectedKind == .typst { languageClient()?.change(url, text: newText) }
        // External compilers only see the disk, so every edit is saved right away.
        if case .binary = CompilerManager.shared.active {
            try? newText.write(to: url, atomically: true, encoding: .utf8)
            if previewIsMarkdown { scheduleCompile(delay: 0) }
            scheduleSolvengCheck(delay: 0.25)
            return
        }
        dirty.insert(url)
        scheduleAutosave()
        // Incremental PDF pages and HTML both update without waiting for an idle pause.
        scheduleCompile(delay: 0)
    }

    /// Edits only reach disk every 30 s and on file, window or app switches; the built-in compiler reads the buffers.
    /// Synced spaces save within a second, so the other devices keep up; repository spaces within two, for their history.
    private func scheduleAutosave() {
        guard autosaveTask == nil else { return }
        let delay: Double = SyncService.shared.syncsAnything(in: root) ? 1 : SpaceList.isInRepository(root) ? 2 : 30
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flushSaves()
        }
    }

    func flushSaves() {
        autosaveTask?.cancel()
        autosaveTask = nil
        for url in dirty {
            try? buffers[url]?.write(to: url, atomically: true, encoding: .utf8)
        }
        if !dirty.isEmpty, SpaceList.isInRepository(root) { CommitScheduler.shared.noteChange() }
        dirty.removeAll()
    }

    // MARK: - Other files' buffers

    /// The selected file was changed outside its editor, e.g. in the search preview.
    @ObservationIgnored private var editorNeedsReload = false

    /// A file's text including unsaved edits.
    func bufferText(_ url: URL) -> String? { buffers[url] ?? Self.read(url) }

    /// Edits a file that may not be the selected one, keeping saving, the language server and compiling in step.
    func updateBuffer(_ url: URL, text new: String, live: Bool = false) {
        guard isInSpace(url) else { return }
        buffers[url] = new
        siblings.forEach { $0.siblingDidEdit(url, text: new) }
        if url == selectedFile {
            text = new
            editorNeedsReload = true
            self.live.textDidChange()
        }
        if FileKind(url: url) == .typst { languageClient()?.change(url, text: new) }
        if case .binary = CompilerManager.shared.active {
            try? new.write(to: url, atomically: true, encoding: .utf8)
            if previewIsMarkdown { scheduleCompile(delay: 0) }
            scheduleSolvengCheck(delay: 0.25)
            return
        }
        dirty.insert(url)
        scheduleAutosave()
        scheduleCompile(delay: 0)
    }

    // MARK: - Other windows

    private final class WeakWorkspace {
        weak var value: Workspace?
        init(_ value: Workspace) { self.value = value }
    }

    /// Every open space; windows showing the same folder keep their unsaved edits in step.
    private static var open: [WeakWorkspace] = []

    private var siblings: [Workspace] {
        Self.open.compactMap(\.value).filter { $0 !== self && !$0.isClosed && $0.root == root }
    }

    /// Another window on this space edited a file; that window saves it.
    private func siblingDidEdit(_ url: URL, text new: String) {
        guard buffers[url] ?? (url == selectedFile ? text : nil) != new else { return }
        if url == selectedFile, selectedKind?.isEditable == true {
            let old = text
            let edit = textDifference(old: old, new: new)
            let change = LiveResult.Edit(location: Int(edit.range.location), length: Int(edit.range.length), text: edit.newText)
            // Through the editor, so this window keeps its caret, scroll and undo.
            if live.applyEdits?([change]) == true { return }
            text = new
            editorNeedsReload = true
            reloadEditorIfNeeded()
        }
        buffers[url] = new
        if FileKind(url: url) == .typst { languageClient()?.change(url, text: new) }
        scheduleCompile(delay: 0.25)
    }

    /// Applies server edits (LSP JSON) to a file other than the shown one.
    func applyEdits(_ json: [[String: Any]], to url: URL) {
        guard isInSpace(url), let old = bufferText(url) else { return }
        updateBuffer(url, text: TextEdit.apply(LanguageClient.edits(json, in: old as NSString), to: old))
    }

    /// Shows edits made elsewhere in the main editor.
    func reloadEditorIfNeeded() {
        guard editorNeedsReload else { return }
        editorNeedsReload = false
        revision += 1
    }

    // MARK: - Language server

    /// The space's tinymist, started on demand and again if it died.
    /// The space's language server, for editors of files other than the selected one.
    var sharedLanguageClient: LanguageClient? { languageClient() }

    var fontDirectories: [URL] { fontDirs }

    private func languageClient() -> LanguageClient? {
        if let language, language.isRunning { return language }
        guard !isClosed, let binary = LanguageServerManager.shared.binary else { return nil }
        language = LanguageClient(binary: binary, root: root, fontPaths: fontDirs.map(\.path))
        if let language, let file = selectedFile, selectedKind == .typst { language.open(file, text: text) }
        return language
    }

    /// Font folders are only read at launch, and the binary may have changed.
    private func restartLanguageServer() {
        language?.stop()
        language = nil
        _ = languageClient()
    }

    func documentation(of item: CompletionItem) async -> String? {
        // solveng's functions document themselves, the same as their hover.
        if item.kind == .function, let f = SolvengSupport.function(item.label) { return FunctionDocs.markdown(for: f) }
        // Package docs come from the cache and the downloaded manifest, so they work offline.
        if let spec = PackageLibrary.spec(in: item.label), let docs = PackageLibrary.shared.documentation(for: spec) {
            return docs
        }
        guard let client = languageClient() else { return item.documentation }
        if let docs = await client.documentation(of: item) { return docs }
        guard let file = selectedFile, selectedKind == .typst else { return nil }
        return await client.hoverDocumentation(of: item, in: file, text: text as NSString)
    }

    func completions(at offset: Int) async -> [CompletionItem] {
        guard let file = selectedFile, selectedKind == .typst else { return [] }
        let solveng = Self.solvengCompletions(in: text, context: solvengContext(), at: offset)
        if let solveng, solveng.exclusive { return solveng.items }
        let packages = packageCompletions(at: offset)
        guard let client = languageClient() else { return (solveng?.items ?? []) + packages }
        let items = await client.completions(in: file, text: text as NSString, at: offset).map { item -> CompletionItem in
            guard PackageLibrary.spec(in: item.label) != nil else { return item }
            var item = item
            item.showsDetailAsSignature = false
            return item
        }
        // tinymist quotes package specs; compare them with the package list's unquoted ones.
        let labels = Set(items.map { PackageLibrary.spec(in: $0.label) ?? $0.label })
        // In math the calculation's names come before Typst's symbols.
        let names = solveng?.items ?? []
        let named = Set(names.map(\.label))
        return names + items.filter { !named.contains($0.label) } + packages.filter { !labels.contains($0.label) }
    }

    /// Inside solveng code and its calls' strings tinymist has nothing to offer; names, units and option values come
    /// from solveng. In math and argument lists they join tinymist's.
    private static func solvengCompletions(in text: String, context: String, at offset: Int) -> (items: [CompletionItem], exclusive: Bool)? {
        guard let result = SolvengSupport.complete(text, context: context, offset: offset), result.from <= offset else { return nil }
        let range = NSRange(location: result.from, length: max(offset, result.to ?? offset) - result.from)
        return (result.items.enumerated().map { index, item in
            let kind: CompletionItem.Kind = switch item.kind {
            case 1: .function
            case 2, 4: .field
            case 3, 5: .constant
            case 6: .keyword
            default: .variable
            }
            let snippet = item.insert.contains("$0")
            return CompletionItem(label: item.label, detail: item.detail, kind: kind,
                                  filterText: item.filter ?? item.insert.replacingOccurrences(of: "$0", with: ""),
                                  sortText: String(format: "%05d", index), newText: item.insert, isSnippet: snippet,
                                  range: range, documentation: item.documentation ?? "`\(item.label)` \(item.detail)")
        }, result.exclusive)
    }

    @ObservationIgnored private var solvengContextCache: (key: [String], text: String)?
    /// solveng's report from the last built-in compile of the previewed file, see `tw_world_solveng`.
    @ObservationIgnored private var solvengReport = ""
    /// solveng's report on the shown file compiled on its own, when it isn't the previewed one.
    @ObservationIgnored private var solvengFileReport: (file: URL, report: String)?
    @ObservationIgnored private var solvengCheckTask: Task<Void, Never>?
    /// Counts new reports, so the editor restyles with what the compiler saw.
    private(set) var solvengRevision = 0

    /// The files around the shown one, for solveng: the previewed main file and what it and the shown file import
    /// or include, so a `worksheet`, `integration`, units and definitions set up elsewhere count here too.
    func solvengContext() -> String {
        guard selectedKind == .typst, let file = selectedFile else { return "" }
        func references(_ text: String) -> [String] {
            SolvengSupport.references(text)
        }
        let key = [file.path, previewFile?.path ?? "", String(solvengRevision)] + references(text)
        if let cache = solvengContextCache, cache.key == key { return cache.text }
        func resolve(_ path: String, from: URL) -> URL {
            path.hasPrefix("/") ? root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
                : from.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        }
        var queue = key.dropFirst(3).map { resolve($0, from: file) }
        if let main = previewFile, main != file, main.pathExtension == "typ" { queue.insert(main, at: 0) }
        var seen: Set<URL> = [file.standardizedFileURL]
        var parts: [(path: String, text: String)] = []
        var size = 0
        // Bounded, since a space can be large and imports can loop.
        while !queue.isEmpty, parts.count < 24, size < 1_000_000 {
            let next = queue.removeFirst()
            guard next.pathExtension == "typ", seen.insert(next).inserted, let text = buffers[next] ?? Self.read(next) else { continue }
            parts.append((relative(next) ?? next.path, text))
            size += text.utf16.count
            queue += references(text).map { resolve($0, from: next) }
        }
        // The compiler's report says for sure what solveng calculates here; reading the settings is the fallback.
        let text = SolvengSupport.context(files: parts, report: solvengReport, path: relative(file) ?? "", main: file == previewFile,
                                          mainPath: previewFile.flatMap(relative) ?? "",
                                          fileReport: solvengFileReport?.file == file ? solvengFileReport!.report : "")
        solvengContextCache = (key, text)
        return text
    }

    /// Compiles what the preview doesn't with the built-in compiler, for solveng's reports: the shown file if it isn't
    /// the previewed one, and the previewed file under an external compiler. Without a report nothing is calculated.
    private func scheduleSolvengCheck(delay: TimeInterval) {
        solvengCheckTask?.cancel()
        solvengCheckTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.checkSolveng()
        }
    }

    private func checkSolveng() async {
        guard selectedKind == .typst, let file = selectedFile else { return }
        var changed = false
        if let main = previewFile, main.pathExtension == "typ", CompilerManager.shared.active != .builtin, let path = relative(main),
           let report = await builtin.check(main: path, buffers: relativeBuffers()), !Task.isCancelled, report != solvengReport {
            solvengReport = report
            changed = true
        }
        if file != previewFile, let path = relative(file) {
            // A file that never mentions solveng has nothing to report.
            let report = text.contains("solve") ? await builtin.check(main: path, buffers: relativeBuffers()) : ""
            if let report, !Task.isCancelled, file == selectedFile, solvengFileReport?.file != file || solvengFileReport?.report != report {
                solvengFileReport = (file, report)
                changed = true
            }
        }
        guard changed else { return }
        solvengRevision += 1
        updateSolvengDiagnostics()
    }

    /// Problems solveng finds in the shown file while typing, like unknown units; the compile may report them later.
    private(set) var solvengDiagnostics: [Diagnostic] = []

    private func updateSolvengDiagnostics() {
        guard selectedKind == .typst, let file = selectedFile, let path = relative(file) else {
            if !solvengDiagnostics.isEmpty { solvengDiagnostics = [] }
            return
        }
        let source = text as NSString
        let found = SolvengSupport.diagnostics(text, context: solvengContext()).compactMap { p -> Diagnostic? in
            guard p.start <= p.end, p.end <= source.length else { return nil }
            let (line, column) = Self.lineAndColumn(of: p.start, in: source)
            return Diagnostic(path: path, line: line + 1, column: column + 1,
                              severity: p.severity == "error" ? .error : .warning, message: p.message, length: p.end - p.start)
        }
        let same = found.count == solvengDiagnostics.count && zip(found, solvengDiagnostics).allSatisfy {
            $0.line == $1.line && $0.column == $1.column && $0.message == $1.message && $0.length == $1.length
        }
        if !same { solvengDiagnostics = found }
    }

    /// Zero-based line and UTF-16 column of `offset`.
    private static func lineAndColumn(of offset: Int, in text: NSString) -> (line: Int, column: Int) {
        var line = 0
        var index = 0
        while index < offset {
            let r = text.lineRange(for: NSRange(location: index, length: 0))
            if NSMaxRange(r) > offset { break }
            line += 1
            index = NSMaxRange(r)
        }
        return (line, offset - index)
    }

    private func sourceLocation(_ location: SolvengSupport.Location, from file: URL) -> SourceLocation? {
        let url = location.path.map { root.appendingPathComponent($0).standardizedFileURL } ?? file
        guard let text = (url == file ? self.text : buffers[url] ?? Self.read(url)) as NSString?, location.end <= text.length else { return nil }
        let (line, column) = Self.lineAndColumn(of: location.start, in: text)
        return SourceLocation(url: url, line: line, character: column, length: location.end - location.start)
    }

    /// ⌘B on a solveng name: jumps to its definition, or on the definition lists its usages; nil off solveng names.
    private func solvengDefinition(at offset: Int, in file: URL) -> [SymbolUsage]? {
        let context = solvengContext()
        guard let definition = SolvengSupport.definition(text, context: context, offset: offset),
              let target = sourceLocation(definition, from: file) else { return nil }
        if definition.path == nil, definition.start <= offset, offset <= definition.end {
            let usages = SolvengSupport.usages(text, context: context, offset: offset)
                .filter { !($0.path == nil && $0.start == definition.start) }
                .compactMap { sourceLocation($0, from: file) }
                .compactMap(usage)
            if usages.isEmpty { NSSound.beep() }
            return usages
        }
        open(target)
        return []
    }

    /// tinymist only knows `@preview`; local namespaces and downloaded packages come from the package folders.
    /// Universe's cached list adds every online version, so names and versions complete offline too.
    private func packageCompletions(at offset: Int) -> [CompletionItem] {
        let start = Int(packageSpecStart(text: text, offset: Int32(offset)))
        guard start >= 0 else { return [] }
        let library = PackageLibrary.shared
        let local = library.namespaces.flatMap(\.packages) + library.downloaded
        let localSpecs = Set(local.map(\.spec))
        var seen = Set<String>()
        let specs = (library.universeSpecs + local.map(\.spec)).filter { seen.insert($0).inserted }
        let latest = Dictionary(grouping: library.universe, by: \.name).compactMapValues {
            $0.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }?.version
        }
        let typed = (text as NSString).substring(with: NSRange(location: start, length: offset - start))
        let range = NSRange(location: start, length: offset - start)
        return packageCandidates(typed: typed, specs: specs).enumerated().map { index, spec in
            let detail: String
            if localSpecs.contains(spec) {
                detail = spec.hasPrefix("@preview/") ? "Downloaded" : "Local package"
            } else if let parts = PackageLibrary.parts(of: spec), let version = parts.version,
                      library.universePackage(for: spec) != nil {
                detail = latest[parts.name] == version ? "Typst Universe · Latest" : "Typst Universe"
            } else {
                detail = "Typst Universe"
            }
            return CompletionItem(label: spec, detail: detail, kind: .file, filterText: spec,
                                  sortText: String(format: "%05d", index), newText: spec, isSnippet: false,
                                  range: range, showsDetailAsSignature: false)
        }
    }

    func hover(at offset: Int) async -> (markdown: String, range: NSRange?)? {
        guard let file = selectedFile, selectedKind == .typst else { return nil }
        if let solveng = SolvengSupport.hover(text, context: solvengContext(), offset: offset) {
            let range = NSRange(location: solveng.start, length: solveng.end - solveng.start)
            // One of solveng's functions: the docs its completion shows.
            let name = (text as NSString).substring(with: range)
            if solveng.markdown.hasPrefix("`\(name)` (solveng)"), let f = SolvengSupport.function(name) {
                return (FunctionDocs.markdown(for: f), range)
            }
            return (solveng.markdown, range)
        }
        // Offline, tinymist's package hover fails; the cache and the package's manifest still describe it.
        if !PackageLibrary.shared.isOnline,
           let range = Self.stringLiteralRange(at: offset, in: text as NSString),
           let spec = PackageLibrary.spec(in: (text as NSString).substring(with: range)),
           let docs = PackageLibrary.shared.documentation(for: spec) {
            return (docs, range)
        }
        var docs = await languageClient()?.hover(in: file, text: text as NSString, at: offset)
        if docs == nil { docs = await languageClient()?.parameterDocs(in: file, text: text as NSString, at: offset) }
        // A path to an image shows the image above the docs.
        guard let (url, range) = imageReference(at: offset) else { return docs }
        let image = "![](\(url.absoluteString))"
        return (docs.map { image + "\n\n" + $0.markdown } ?? image, range)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "bmp"]

    /// The image file a string literal at `offset` names, resolved like typst does.
    private func imageReference(at offset: Int) -> (URL, NSRange)? {
        guard let file = selectedFile, let range = Self.stringLiteralRange(at: offset, in: text as NSString) else { return nil }
        let string = (text as NSString).substring(with: range)
        guard Self.imageExtensions.contains((string as NSString).pathExtension.lowercased()) else { return nil }
        let url = resolvePath(string, from: file)
        return FileManager.default.fileExists(atPath: url.path) ? (url, range) : nil
    }

    private func resolvePath(_ string: String, from file: URL) -> URL {
        let base = string.hasPrefix("/") ? root : file.deletingLastPathComponent()
        return base.appendingPathComponent(string.hasPrefix("/") ? String(string.dropFirst()) : string).standardizedFileURL
    }

    private static let packageSpec = try! NSRegularExpression(pattern: #"^@([\w-]+)/([\w-]+)(?::([\w.-]+))?$"#)

    /// For a package import like `"@preview/cetz:0.3.1"`: its Universe page, repository and files.
    func links(at offset: Int) async -> [(title: String, url: URL)] {
        guard selectedKind == .typst, let range = Self.stringLiteralRange(at: offset, in: text as NSString) else { return [] }
        let spec = (text as NSString).substring(with: range)
        guard let m = Self.packageSpec.firstMatch(in: spec, range: NSRange(location: 0, length: (spec as NSString).length)) else {
            return []
        }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : (spec as NSString).substring(with: r)
        }
        guard let namespace = group(1), let name = group(2) else { return [] }
        let library = PackageLibrary.shared
        func folder() -> URL? {
            let base = (namespace == "preview" ? library.cacheDirectory : library.dataDirectory)
                .appending(path: "\(namespace)/\(name)", directoryHint: .isDirectory)
            let version = group(3) ?? (try? FileManager.default.contentsOfDirectory(atPath: base.path))?
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending }.first
            return version.map { base.appending(path: $0, directoryHint: .isDirectory) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        }
        var links: [(title: String, url: URL)] = []
        if namespace == "preview", let universe = URL(string: "https://typst.app/universe/package/\(name)") {
            links.append(("Open on Typst Universe", universe))
        }
        // The repository is in the package's manifest; fetch the package if it isn't here yet.
        var local = folder()
        if local == nil, namespace == "preview", await library.download(spec) { local = folder() }
        if let local {
            let manifest = (try? String(contentsOf: local.appending(path: "typst.toml"), encoding: .utf8)) ?? ""
            for (key, title) in [("repository", "Open Repository"), ("homepage", "Open Homepage")] {
                let pattern = "(?m)^\\s*\(key)\\s*=\\s*\"([^\"]+)\""
                if let r = manifest.range(of: pattern, options: .regularExpression),
                   let value = manifest[r].split(separator: "\"").dropFirst().first, let url = URL(string: String(value)),
                   !links.contains(where: { $0.url == url }) {
                    links.append((title, url))
                }
            }
            links.append(("Show Package Files", local))
        }
        return links
    }

    func occurrences(at offset: Int) async -> [NSRange] {
        guard let file = selectedFile, selectedKind == .typst else { return [] }
        // A solveng name: what belongs to the same definition, in this file.
        let solveng = SolvengSupport.usages(text, context: solvengContext(), offset: offset).filter { $0.path == nil }
        if !solveng.isEmpty { return solveng.map { NSRange(location: $0.start, length: $0.end - $0.start) } }
        guard let client = languageClient() else { return [] }
        return await client.occurrences(in: file, text: text as NSString, at: offset)
    }

    /// Formats the shown file through its editor, so it's one undo step there.
    func formatSelected() {
        find.textView?.onFormat?()
    }

    func quickFixes(for diagnostic: Diagnostic) -> [QuickFix] {
        QuickFixes.fixes(for: diagnostic, root: root) + packageUpgradeFixes(for: diagnostic) + quotingFixes(for: diagnostic)
    }

    /// Replaces an outdated package's version where the diagnostic underlines it.
    private func packageUpgradeFixes(for diagnostic: Diagnostic) -> [QuickFix] {
        guard diagnostic.message.hasPrefix("Package "), let file = selectedFile,
              diagnostic.path == relativePath(of: file), let tv = find.textView,
              let length = diagnostic.length else { return [] }
        let s = text as NSString
        guard let line = CodeEditor.lineRange(diagnostic.line, in: s) else { return [] }
        let range = NSRange(location: line.location + max(diagnostic.column - 1, 0), length: length)
        guard NSMaxRange(range) <= s.length else { return [] }
        let spec = s.substring(with: range)
        guard let parts = PackageLibrary.parts(of: spec), let latest = PackageLibrary.shared.latestVersion(
            namespace: parts.namespace, name: parts.name), latest != parts.version else { return [] }
        let updated = "@\(parts.namespace)/\(parts.name):\(latest)"
        return [QuickFix(id: "package.update", title: "Update to \(latest)", icon: "arrow.up.circle") {
            guard tv.string == s as String else { return }
            tv.insertText(updated, replacementRange: range)
        }]
    }

    /// Typst reads a word of several letters in math as a variable of its own; solveng's names and units are quoted
    /// there (`"tews"`, `"mA"`).
    private func quotingFixes(for diagnostic: Diagnostic) -> [QuickFix] {
        let prefix = "unknown variable: "
        guard diagnostic.message.hasPrefix(prefix), let file = selectedFile, diagnostic.path == relativePath(of: file),
              text.contains(SolvengSupport.tag) || text.contains("worksheet") || text.contains("graph"),
              let tv = find.textView else { return [] }
        let name = String(diagnostic.message.dropFirst(prefix.count))
        let s = text as NSString
        guard let line = CodeEditor.lineRange(diagnostic.line, in: s) else { return [] }
        let range = NSRange(location: line.location + max(diagnostic.column - 1, 0), length: (name as NSString).length)
        guard NSMaxRange(range) <= s.length, s.substring(with: range) == name,
              s.substring(to: range.location).filter({ $0 == "$" }).count % 2 == 1 else { return [] }
        return [QuickFix(id: "solveng.quote", title: "Quote “\(name)” as a solveng name or unit", icon: "quote.opening") {
            guard tv.string == s as String else { return }
            tv.insertText("\"\(name)\"", replacementRange: range)
        }]
    }

    func formattingEdits() async -> [TextEdit] {
        guard let file = selectedFile, selectedKind == .typst, let client = languageClient() else { return [] }
        return await client.format(file, text: text as NSString)
    }

    func renameTarget(at offset: Int) async -> (range: NSRange, name: String)? {
        guard let file = selectedFile, selectedKind == .typst else { return nil }
        if let solveng = SolvengSupport.renameTarget(text, context: solvengContext(), offset: offset) {
            return (NSRange(location: solveng.start, length: solveng.end - solveng.start), solveng.name)
        }
        guard let client = languageClient() else { return nil }
        return await client.renameTarget(in: file, text: text as NSString, at: offset)
    }

    /// Renames the symbol everywhere: other files are rewritten here, the shown file's edits are returned for the editor.
    func rename(at offset: Int, to name: String) async -> [TextEdit] {
        guard let file = selectedFile, selectedKind == .typst else { return [] }
        let context = solvengContext()
        if SolvengSupport.renameTarget(text, context: context, offset: offset) != nil {
            return renameSolveng(at: offset, to: name, context: context, in: file)
        }
        guard let client = languageClient() else { return [] }
        let source = text as NSString
        let changes = await client.rename(in: file, text: source, at: offset, to: name)
        var shown: [TextEdit] = []
        for (url, json) in changes {
            if url == file {
                shown = LanguageClient.edits(json, in: source)
                continue
            }
            applyEdits(json, to: url)
        }
        if shown.isEmpty { scheduleCompile(delay: 0) }
        return shown
    }

    /// A solveng name's rename: the files around are rewritten here, the shown file's edits returned.
    private func renameSolveng(at offset: Int, to name: String, context: String, in file: URL) -> [TextEdit] {
        let edits = SolvengSupport.rename(text, context: context, offset: offset, to: name)
        let edit = { (e: SolvengSupport.Edit) in TextEdit(range: NSRange(location: e.start, length: e.end - e.start), newText: e.text) }
        for (path, group) in Dictionary(grouping: edits.filter { $0.path != nil }, by: { $0.path! }) {
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url != file, isInSpace(url), let old = bufferText(url) else { continue }
            updateBuffer(url, text: TextEdit.apply(group.map(edit), to: old))
        }
        return edits.filter { $0.path == nil }.map(edit)
    }

    /// Jumps to the definition at `offset`; on the definition itself it returns the usages to pick from instead.
    func goToDefinition(at offset: Int) async -> [SymbolUsage] {
        guard let file = selectedFile, selectedKind == .typst else { return [] }
        if let solveng = solvengDefinition(at: offset, in: file) { return solveng }
        let source = text as NSString
        // An import item's definition is in the package; its uses here are what's worth seeing.
        if Refactor.symbol(in: text, at: offset)?.kind == "import" {
            let usages = Refactor.usages(in: text, at: offset).compactMap { range -> SymbolUsage? in
                let line = source.substring(to: range.location).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
                let start = source.lineRange(for: NSRange(location: range.location, length: 0)).location
                return usage(SourceLocation(url: file, line: line, character: range.location - start, length: range.length))
            }
            if usages.isEmpty { NSSound.beep() }
            return usages
        }
        if let client = languageClient(), let target = await client.definition(in: file, text: source, at: offset) {
            let range = target.range(in: source)
            if target.url == file, NSLocationInRange(offset, range) || NSMaxRange(range) == offset {
                // Servers may list the definition itself among the references.
                let usages = await client.references(in: file, text: source, at: offset)
                    .filter { !($0.url == file && $0.range(in: source) == range) }
                    .compactMap(usage)
                if usages.isEmpty { NSSound.beep() }
                return usages
            }
            // Package sources live in a cache outside the space and aren't ours to edit.
            guard target.url == file || target.url.path.hasPrefix(root.path + "/") else {
                NSSound.beep()
                return []
            }
            open(target)
            return []
        }
        guard let string = Self.stringLiteral(at: offset, in: source) else {
            NSSound.beep()
            return []
        }
        let base = string.hasPrefix("/") ? root : file.deletingLastPathComponent()
        let path = base.appendingPathComponent(string.hasPrefix("/") ? String(string.dropFirst()) : string).standardizedFileURL
        if !string.isEmpty, FileManager.default.fileExists(atPath: path.path), path.path.hasPrefix(root.path + "/") {
            select(path)
        } else if let font = FontLocator.file(for: string, in: fontDirs + [root]) {
            select(font)
        } else {
            NSSound.beep()
        }
        return []
    }

    func open(_ location: SourceLocation) {
        select(location.url)
        // The caret goes to the symbol, which flashes, rather than its whole line.
        let marked = location.endLine == location.line ? max(location.endCharacter - location.character, 0) : 0
        reveal = RevealRequest(line: location.line + 1, column: location.character + 1, marked: marked)
    }

    private static let pathLiteral = try! NSRegularExpression(pattern: #""((?:\\.|[^"\\\n])+)""#)

    /// String literals in the space's Typst files that point at `target`, like imports, includes and images.
    func fileUsages(of target: URL) -> [SymbolUsage] {
        let target = target.standardizedFileURL
        var found: [SymbolUsage] = []
        for node in Self.flatten(tree) where node.isTypst {
            guard let text = (buffers[node.url] ?? Self.read(node.url)) as NSString? else { continue }
            let dir = node.url.deletingLastPathComponent()
            // Lines are counted as the matches go, so each file is scanned once.
            var line = 0, scanned = 0
            for m in Self.pathLiteral.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let path = text.substring(with: m.range(at: 1))
                let url = path.hasPrefix("/") ? root.appendingPathComponent(String(path.dropFirst()))
                    : dir.appendingPathComponent(path)
                guard url.standardizedFileURL == target else { continue }
                let range = m.range(at: 1)
                let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
                for i in scanned..<lineStart where text.character(at: i) == 10 { line += 1 }
                scanned = lineStart
                let location = SourceLocation(url: node.url, line: line, character: range.location - lineStart, length: range.length)
                if let usage = usage(location) { found.append(usage) }
            }
        }
        return found
    }

    /// Opens a usage with its range selected.
    func reveal(_ usage: SymbolUsage) {
        let l = usage.location
        select(l.url)
        reveal = RevealRequest(line: l.line + 1, column: l.character + 1, length: l.endCharacter - l.character)
    }

    /// A usage with its line's text, for the usages menu.
    private func usage(_ location: SourceLocation) -> SymbolUsage? {
        guard location.url.path.hasPrefix(root.path + "/") else { return nil }
        let text = (buffers[location.url] ?? Self.read(location.url) ?? "") as NSString
        let line = Self.lineText(location.line, in: text)
        return SymbolUsage(location: location, file: relative(location.url) ?? location.url.lastPathComponent,
                           preview: line.trimmingCharacters(in: .whitespaces))
    }

    static func lineText(_ line: Int, in text: NSString) -> String {
        TypewrightCore.lineText(line: Int32(clamping: line), text: text as String)
    }

    /// Contents of the string literal around `offset` on its line.
    private static func stringLiteral(at offset: Int, in text: NSString) -> String? {
        stringLiteralRange(at: offset, in: text).map(text.substring(with:))
    }

    /// Range of the contents of the string literal around `offset` on its line.
    private static func stringLiteralRange(at offset: Int, in text: NSString) -> NSRange? {
        TypewrightCore.stringLiteralRange(offset: Int32(clamping: offset), text: text as String)
            .map { NSRange(location: Int($0.location), length: Int($0.length)) }
    }

    // MARK: - Compilation

    func scheduleCompile(delay: TimeInterval) {
        invalidateCompile()
        scheduleSolvengCheck(delay: max(delay, 0.25))
        compileTask?.cancel()
        compileTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.compile()
        }
    }

    /// Never kills a running compile for a newer edit; one follow-up compile picks up everything typed meanwhile.
    private func compile() async {
        guard !compileRunning else {
            compileQueued = true
            return
        }
        compileRunning = true
        repeat {
            compileQueued = false
            await compileOnce()
        } while compileQueued
        compileRunning = false
    }

    private func invalidateCompile() {
        generation += 1
    }

    private func compileOnce() async {
        if let previewFile, previewIsMarkdown {
            stopWatcher()
            return await renderMarkdown(previewFile)
        }
        guard let previewFile, let compiler = CompilerManager.shared.active else {
            stopWatcher()
            return
        }
        switch compiler {
        case .builtin:
            stopWatcher()
            await compileBuiltin(main: previewFile)
        case .binary(let binary):
            flushSaves()
            guard renderMode != .svg else {
                stopWatcher()
                failureLog = "The incremental preview needs the built-in compiler. Choose it in Settings, or render as PDF."
                return
            }
            startWatcher(binary: binary, main: previewFile)
        }
    }

    private func renderMarkdown(_ url: URL) async {
        let current = generation
        let source = bufferText(url) ?? ""
        let start = Date()
        let html = await Task.detached { MarkdownRenderer.html(source) }.value
        guard current == generation else { return }
        markdownHTML = html
        lastDuration = Date().timeIntervalSince(start)
    }

    private func compileBuiltin(main: URL) async {
        guard let rel = relative(main) else { return }
        let current = generation
        let mode = renderMode
        isCompiling = true
        let result = await builtin.compile(main: rel, buffers: relativeBuffers(), format: mode, incremental: true)
        isCompiling = false
        guard current == generation else { return }
        apply(result, mode: mode)
    }

    /// Keeps one `typst watch` per previewed file and format; it recompiles on its own when files are saved.
    private func startWatcher(binary: URL, main: URL) {
        let mode = renderMode
        if let watcher, watcher.binary == binary, watcher.main == main, watcher.format == mode,
           watcher.fontPaths == fontDirs { return }
        stopWatcher()
        var started: TypstWatcher?
        let watcher = TypstWatcher(
            binary: binary, main: main, root: root, format: mode, fontPaths: fontDirs,
            onCompiling: { [weak self] in
                guard let self, self.watcher === started else { return }
                self.isCompiling = true
            },
            onResult: { [weak self] result in
                guard let self, self.watcher === started else { return }
                self.isCompiling = false
                self.apply(result, mode: mode)
            }
        )
        started = watcher
        self.watcher = watcher
        watcher.start()
    }

    private func stopWatcher() {
        guard let watcher else { return }
        watcher.stop()
        self.watcher = nil
        isCompiling = false
    }

    private func apply(_ result: CompileResult, mode: RenderMode) {
        diagnostics = result.diagnostics
        defer { updateSolvengDiagnostics() }
        // A failed compile keeps the last report; external compilers have none, `checkSolveng` fills in.
        if let report = result.solveng, report != solvengReport {
            solvengReport = report
            solvengRevision += 1
        }
        // Missing fonts are looked up on Google Fonts; fetch the list before anyone hovers them.
        if diagnostics.contains(where: { QuickFixes.missingFont(in: $0.message) != nil }) {
            Task { await FontLibrary.shared.loadCatalog() }
        }
        lastDuration = result.duration
        failureLog = result.output == nil && result.diagnostics.isEmpty && !result.log.isEmpty ? result.log : nil
        guard let data = result.output else { return }
        switch mode {
        case .pdf, .svg:
            if let pages = result.previewPages {
                preview.showPages(pages)
                document = preview.view.document
            } else if let doc = PDFDocument(data: data) { document = doc }
        case .html:
            html = String(decoding: data, as: UTF8.self)
        }
    }

    /// Writes a PDF of the main file, compiling one if the preview isn't a PDF.
    func exportPDF(to url: URL) async -> String? {
        if renderMode == .pdf, CompilerManager.shared.active != .builtin, let document,
           !isCompiling, !diagnostics.contains(where: { $0.severity == .error }) {
            return document.write(to: url) ? nil : "Could not write \(url.lastPathComponent)."
        }
        guard let previewFile, let compiler = CompilerManager.shared.active else { return "No compiler available." }
        let result: CompileResult
        switch compiler {
        case .builtin:
            guard let rel = relative(previewFile) else { return "The file is outside the project." }
            result = await builtin.compile(main: rel, buffers: relativeBuffers(), format: .pdf)
            if let data = result.output {
                do { try data.write(to: url) } catch { return error.localizedDescription }
                return nil
            }
        case .binary(let binary):
            flushSaves()
            result = await exportRunner.compile(binary: binary, main: previewFile, root: root, output: url,
                                                fontPaths: fontDirs)
            if result.output != nil { return nil }
        }
        let errors = result.diagnostics.filter { $0.severity == .error }
        return errors.isEmpty ? result.log : errors.map { "\($0.path):\($0.line): \($0.message)" }.joined(separator: "\n")
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Self.open.removeAll { $0.value == nil || $0.value === self }
        flushSaves()
        persistTask?.cancel()
        persist()
        compileTask?.cancel()
        solvengCheckTask?.cancel()
        stopWatcher()
        exportRunner.cancel()
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let packageObserver { NotificationCenter.default.removeObserver(packageObserver) }
        syncObservers.forEach(NotificationCenter.default.removeObserver)
        live.stop()
        language?.stop()
        language = nil
    }

    // MARK: - Helpers

    /// The space folder for a folder or a file inside it.
    nonisolated static func root(of url: URL) -> URL {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue ? url : url.deletingLastPathComponent()
    }

    private func defaultMain() -> URL? {
        let main = root.appendingPathComponent("main.typ")
        if FileManager.default.fileExists(atPath: main.path) { return main }
        return Self.flatten(tree).first { $0.isTypst }?.url
    }

    private func relative(_ url: URL) -> String? {
        spaceRelativePath(path: url.standardizedFileURL.path, root: root.path)
    }

    /// Open buffers keyed by path relative to the root; they win over the disk contents.
    private func relativeBuffers() -> [String: String] {
        Dictionary(buffers.compactMap { url, text in relative(url).map { ($0, text) } }) { a, _ in a }
    }

    private static func read(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
    }

    static func flatten(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    private static func scan(_ dir: URL, depth: Int) -> [FileNode] {
        guard depth < 8 else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .map { url -> FileNode in
                let isDir = (try? url.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
                let url = url.standardizedFileURL
                return isDir
                    ? FileNode(url: url, kind: .folder, children: scan(url, depth: depth + 1))
                    : FileNode(url: url, kind: FileKind(url: url), children: nil)
            }
            .sorted { a, b in
                if (a.children == nil) != (b.children == nil) { return a.children != nil }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}
