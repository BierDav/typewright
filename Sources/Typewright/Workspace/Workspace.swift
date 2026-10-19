import AppKit
import Observation
import PDFKit

struct FileNode: Identifiable, Hashable {
    let url: URL
    let kind: FileKind
    let children: [FileNode]?
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isTypst: Bool { kind == .typst }
}

struct RevealRequest: Equatable {
    let id = UUID()
    let line: Int
    let column: Int
    /// Characters selected from the column on, e.g. a search match.
    var length = 0
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
    var split: Double { didSet { schedulePersist() } }
    /// Folders open in the sidebar; everything else starts collapsed.
    var expanded: Set<URL> = [] { didSet { schedulePersist() } }
    var reveal: RevealRequest?

    var renderMode: RenderMode {
        didSet {
            UserDefaults.standard.set(renderMode.rawValue, forKey: "renderMode")
            invalidateCompile()
            scheduleCompile(delay: 0)
        }
    }
    private(set) var document: PDFDocument?
    private(set) var html: String?
    private(set) var svgPages: [String]?
    private(set) var diagnostics: [Diagnostic] = []
    /// Compiler output when compilation failed without diagnostics.
    private(set) var failureLog: String?
    private(set) var isCompiling = false
    private(set) var lastDuration: TimeInterval?

    /// Find and replace in the editor.
    @ObservationIgnored let find = FindModel()
    @ObservationIgnored let preview = PreviewController()
    @ObservationIgnored let htmlPreview = HTMLPreviewController()
    @ObservationIgnored let svgPreview = SVGPreviewController()
    /// Shows a selected PDF file instead of the compiled document.
    @ObservationIgnored let filePreview = PreviewController()
    private var buffers: [URL: String] = [:]
    private var dirty: Set<URL> = []

    /// Edits not yet on disk, for searches that read files.
    var unsavedBuffers: [URL: String] { buffers.filter { dirty.contains($0.key) || $0.key == selectedFile } }
    private var compileTask: Task<Void, Never>?
    /// Bumped when the previewed file or format changes, so in-flight results are dropped.
    private var generation = 0
    private var compileRunning = false
    private var compileQueued = false
    private let exportRunner = TypstRunner()
    @ObservationIgnored private let builtin: BuiltinCompiler
    @ObservationIgnored private var watcher: TypstWatcher?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var editorStates: [URL: EditorState] = [:]
    @ObservationIgnored private var previewStates: [URL: PreviewState] = [:]
    /// HTML and SVG preview positions per previewed file.
    @ObservationIgnored private var htmlStates: [URL: WebPreviewState] = [:]
    @ObservationIgnored private var svgStates: [URL: WebPreviewState] = [:]
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    /// Font folders passed to every compiler, see `FontLibrary`.
    @ObservationIgnored private var fontDirs: [URL] = []
    @ObservationIgnored private var fontObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var language: LanguageClient?
    @ObservationIgnored private var languageObserver: (any NSObjectProtocol)?

    init(url: URL) {
        let url = url.standardizedFileURL
        root = Self.root(of: url)
        let isDir = root == url
        builtin = BuiltinCompiler(root: root)
        renderMode = UserDefaults.standard.string(forKey: "renderMode").flatMap(RenderMode.init) ?? .pdf

        let saved = SpaceStore.state(for: root)
        let state = saved ?? SpaceState()
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
        htmlStates = Dictionary(state.htmlPreviews.compactMap { k, v in resolve(k).map { ($0, v) } }) { a, _ in a }
        svgStates = Dictionary(state.svgPreviews.compactMap { k, v in resolve(k).map { ($0, v) } }) { a, _ in a }
        expanded = Set(state.expanded.compactMap(resolve))
        let initial = isDir ? resolve(state.selected) ?? defaultMain() : url
        if let initial { select(initial) }
        // New spaces start out previewing their main file; known ones keep their choice, even none.
        if saved == nil {
            previewFile = initial?.pathExtension == "typ" ? initial : defaultMain()
        } else {
            previewFile = resolve(state.preview)
        }
        preview.pendingRestore = previewFile.flatMap { previewStates[$0] }
        restoreWebPreviews(for: previewFile)
        fontObserver = NotificationCenter.default.addObserver(forName: FontLibrary.didChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateFonts()
                self?.restartWatcher()
                self?.restartLanguageServer()
            }
        }
        languageObserver = NotificationCenter.default.addObserver(forName: LanguageServerManager.didChange, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartLanguageServer() }
        }
    }

    /// Whether the compiled output for the current render mode is available.
    var hasOutput: Bool {
        switch renderMode {
        case .pdf: document != nil
        case .html: html != nil
        case .svg: svgPages != nil
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

    // MARK: - Files

    func reloadTree() {
        tree = Self.scan(root, depth: 0)
        // New, removed or renamed files must reach the built-in compiler too.
        builtin.reset()
        // Fonts may have been added to the space's font folders.
        updateFonts()
    }

    private func updateFonts() {
        fontDirs = FontLibrary.shared.directories(for: root)
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
        captureFileState()
        flushSaves()
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
        if kind == .typst { languageClient()?.open(url, text: text) }
        revision += 1
        schedulePersist()
    }

    func reveal(_ diagnostic: Diagnostic) {
        guard !diagnostic.isFromPackage else { return }
        select(root.appendingPathComponent(diagnostic.path).standardizedFileURL)
        reveal = RevealRequest(line: diagnostic.line, column: diagnostic.column)
    }

    func togglePreview(_ url: URL) {
        setPreview(previewFile == url ? nil : url)
    }

    func setPreview(_ url: URL?) {
        guard url != previewFile else { return }
        capturePreviewState()
        previewFile = url
        document = nil
        html = nil
        svgPages = nil
        failureLog = nil
        diagnostics = []
        lastDuration = nil
        preview.pendingRestore = url.flatMap { previewStates[$0] }
        restoreWebPreviews(for: url)
        invalidateCompile()
        scheduleCompile(delay: 0)
        schedulePersist()
    }

    // MARK: - View state

    func editorState(for url: URL?) -> EditorState? {
        url.flatMap { editorStates[$0] }
    }

    func editorStateDidChange(_ state: EditorState) {
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

    private func capturePreviewState() {
        guard let main = previewFile else { return }
        // Only formats that show this file's output; the others still hold another file's or nothing.
        if html != nil, htmlPreview.pendingRestore == nil { htmlStates[main] = htmlPreview.state() }
        if svgPages != nil, svgPreview.pendingRestore == nil { svgStates[main] = svgPreview.state() }
        guard document != nil, preview.view.document === document, let state = preview.state() else { return }
        previewStates[main] = state
    }

    /// The HTML and SVG previews jump to where `url` was left once its output arrives; new files start at the top.
    private func restoreWebPreviews(for url: URL?) {
        guard let url else { return }
        htmlPreview.pendingRestore = htmlStates[url] ?? WebPreviewState(zoom: 1)
        svgPreview.pendingRestore = svgStates[url] ?? WebPreviewState()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    func persist() {
        capturePreviewState()
        captureFileState()
        var state = SpaceState()
        state.selected = selectedFile.flatMap(relative)
        state.preview = previewFile.flatMap(relative)
        state.split = split
        for (url, s) in editorStates { if let key = relative(url) { state.editors[key] = s } }
        for (url, s) in previewStates { if let key = relative(url) { state.previews[key] = s } }
        for (url, s) in htmlStates { if let key = relative(url) { state.htmlPreviews[key] = s } }
        for (url, s) in svgStates { if let key = relative(url) { state.svgPreviews[key] = s } }
        state.expanded = expanded.compactMap(relative).sorted()
        SpaceStore.save(state, for: root)
    }

    /// Picks up edits made by other apps for files without pending changes.
    func refreshFromDisk() {
        reloadTree()
        for url in buffers.keys where !dirty.contains(url) {
            buffers[url] = nil
        }
        if let selected = selectedFile, selectedKind?.isEditable == true, !dirty.contains(selected),
           let disk = Self.read(selected), disk != text {
            text = disk
            buffers[selected] = disk
            revision += 1
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
        return url
    }

    @discardableResult
    func createFolder(in dir: URL? = nil, named name: String? = nil) -> URL {
        let typed = name?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-") ?? ""
        let url = Self.unique(in: dir ?? root, name: typed.isEmpty ? "New Folder" : typed, ext: nil)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        reloadTree()
        return url
    }

    /// Renames a file or folder and moves buffers, selection, preview and saved state along.
    func rename(_ url: URL, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != url.lastPathComponent else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        // Case-only renames hit the same file on case-insensitive volumes.
        let caseOnly = target.path.lowercased() == url.path.lowercased()
        guard caseOnly || !FileManager.default.fileExists(atPath: target.path) else { return }
        relocate(url, to: target)
    }

    /// Whether `url` can be moved into the folder `dir`.
    func canMove(_ url: URL, into dir: URL) -> Bool {
        dir.path != url.deletingLastPathComponent().path && dir.path != url.path && !dir.path.hasPrefix(url.path + "/")
            && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(url.lastPathComponent).path)
    }

    /// Moves a file or folder into `dir`, keeping its name.
    func move(_ url: URL, into dir: URL) {
        guard canMove(url, into: dir) else { return NSSound.beep() }
        relocate(url, to: dir.appendingPathComponent(url.lastPathComponent).standardizedFileURL)
        if dir.path != root.path { expanded.insert(dir.standardizedFileURL) }
    }

    /// Moves (or copies) files dropped from other apps into `dir`; name clashes get a number, like Finder.
    func importItems(_ urls: [URL], into dir: URL, copy: Bool) {
        let fm = FileManager.default
        var imported: [(url: URL, isDir: Bool)] = []
        for url in urls.map(\.standardizedFileURL) {
            // Items already in the space move like tree drags.
            if url.path.hasPrefix(root.path + "/") {
                if canMove(url, into: dir) { move(url, into: dir) }
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
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        guard !imported.isEmpty else { return }
        if dir.path != root.path { expanded.insert(dir.standardizedFileURL) }
        reloadTree()
        if imported.count == 1, let file = imported.first, !file.isDir { select(file.url) }
        schedulePersist()
    }

    /// Moves a file or folder to the Trash and drops everything that pointed into it.
    func delete(_ url: URL) {
        flushSaves()
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        func gone(_ u: URL) -> Bool { u == url || u.path.hasPrefix(url.path + "/") }
        buffers = buffers.filter { !gone($0.key) }
        dirty = dirty.filter { !gone($0) }
        editorStates = editorStates.filter { !gone($0.key) }
        previewStates = previewStates.filter { !gone($0.key) }
        htmlStates = htmlStates.filter { !gone($0.key) }
        svgStates = svgStates.filter { !gone($0.key) }
        expanded = expanded.filter { !gone($0) }
        reloadTree()
        if let file = previewFile, gone(file) { setPreview(nil) }
        if let file = selectedFile, gone(file) {
            selectedFile = nil
            selectedKind = nil
            text = ""
            revision += 1
            if let main = defaultMain() { select(main) }
        }
        schedulePersist()
    }

    private func relocate(_ url: URL, to target: URL) {
        flushSaves()
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
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
        htmlStates = remap(htmlStates)
        svgStates = remap(svgStates)
        selectedFile = selectedFile.map(moved)
        expanded = Set(expanded.map(moved))
        if let file = previewFile, moved(file) != file {
            previewFile = moved(file)
            scheduleCompile(delay: 0)
        }
        reloadTree()
        schedulePersist()
    }

    private static func unique(in dir: URL, name: String, ext: String?) -> URL {
        func make(_ n: String) -> URL {
            let base = dir.appendingPathComponent(n)
            return (ext.map { base.appendingPathExtension($0) } ?? base).standardizedFileURL
        }
        var url = make(name)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = make(ext == nil ? "\(name) \(i)" : "\(name)-\(i)")
            i += 1
        }
        return url
    }

    // MARK: - Editing

    /// `live` edits (color wheel drags) compile at once so the preview keeps up.
    func textDidChange(_ newText: String, live: Bool) {
        guard let url = selectedFile else { return }
        text = newText
        buffers[url] = newText
        if selectedKind == .typst { languageClient()?.change(url, text: newText) }
        // External compilers only see the disk, so every edit is saved right away.
        if case .binary = CompilerManager.shared.active {
            try? newText.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        dirty.insert(url)
        scheduleAutosave()
        // HTML skips layout and SVG only swaps changed pages, so both keep up with every keystroke.
        scheduleCompile(delay: renderMode == .pdf && !live ? 0.25 : 0)
    }

    /// Edits only reach disk every 30 s and on file, window or app switches; the built-in compiler reads the buffers.
    private func scheduleAutosave() {
        guard autosaveTask == nil else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
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
        if url == selectedFile {
            text = new
            editorNeedsReload = true
        }
        if FileKind(url: url) == .typst { languageClient()?.change(url, text: new) }
        if case .binary = CompilerManager.shared.active {
            try? new.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        dirty.insert(url)
        scheduleAutosave()
        scheduleCompile(delay: renderMode == .pdf && !live ? 0.25 : 0)
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

    func completions(at offset: Int) async -> [CompletionItem] {
        guard let file = selectedFile, selectedKind == .typst, let client = languageClient() else { return [] }
        return await client.completions(in: file, text: text as NSString, at: offset)
    }

    func hover(at offset: Int) async -> (markdown: String, range: NSRange?)? {
        guard let file = selectedFile, selectedKind == .typst, let client = languageClient() else { return nil }
        return await client.hover(in: file, text: text as NSString, at: offset)
    }

    func occurrences(at offset: Int) async -> [NSRange] {
        guard let file = selectedFile, selectedKind == .typst, let client = languageClient() else { return [] }
        return await client.occurrences(in: file, text: text as NSString, at: offset)
    }

    /// Formats the shown file through its editor, so it's one undo step there.
    func formatSelected() {
        find.textView?.onFormat?()
    }

    func quickFixes(for diagnostic: Diagnostic) -> [QuickFix] {
        QuickFixes.fixes(for: diagnostic, root: root)
    }

    func formattingEdits() async -> [TextEdit] {
        guard let file = selectedFile, selectedKind == .typst, let client = languageClient() else { return [] }
        return await client.format(file, text: text as NSString)
    }

    func renameTarget(at offset: Int) async -> (range: NSRange, name: String)? {
        guard let file = selectedFile, selectedKind == .typst, let client = languageClient() else { return nil }
        return await client.renameTarget(in: file, text: text as NSString, at: offset)
    }

    /// Renames the symbol everywhere: other files are rewritten here, the shown file's edits are returned for the editor.
    func rename(at offset: Int, to name: String) async -> [TextEdit] {
        guard let file = selectedFile, selectedKind == .typst, let client = languageClient() else { return [] }
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

    /// Jumps to the definition at `offset`; on the definition itself it returns the usages to pick from instead.
    func goToDefinition(at offset: Int) async -> [SymbolUsage] {
        guard let file = selectedFile, selectedKind == .typst else { return [] }
        let source = text as NSString
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
        reveal = RevealRequest(line: location.line + 1, column: location.character + 1)
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
        let start = LanguageClient.offset(line: line, character: 0, in: text)
        var r = text.lineRange(for: NSRange(location: start, length: 0))
        if r.length > 0, text.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        return text.substring(with: r)
    }

    /// Contents of the string literal around `offset` on its line.
    private static func stringLiteral(at offset: Int, in text: NSString) -> String? {
        let line = text.lineRange(for: NSRange(location: min(offset, text.length), length: 0))
        var start: Int?
        var index = line.location
        while index < NSMaxRange(line) {
            let c = text.character(at: index)
            if c == 92 { index += 2; continue } // backslash escapes
            if c == 34 {
                if let s = start {
                    if offset >= s, offset <= index { return text.substring(with: NSRange(location: s, length: index - s)) }
                    start = nil
                } else {
                    start = index + 1
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Compilation

    func scheduleCompile(delay: TimeInterval) {
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
                failureLog = "The SVG preview needs the built-in compiler. Choose it in Settings, or render as PDF."
                return
            }
            startWatcher(binary: binary, main: previewFile)
        }
    }

    private func compileBuiltin(main: URL) async {
        guard let rel = relative(main) else { return }
        let current = generation
        let mode = renderMode
        isCompiling = true
        let result = await builtin.compile(main: rel, buffers: relativeBuffers(), format: mode)
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
        // Missing fonts are looked up on Google Fonts; fetch the list before anyone hovers them.
        if diagnostics.contains(where: { QuickFixes.missingFont(in: $0.message) != nil }) {
            Task { await FontLibrary.shared.loadCatalog() }
        }
        lastDuration = result.duration
        failureLog = result.output == nil && result.diagnostics.isEmpty && !result.log.isEmpty ? result.log : nil
        guard let data = result.output else { return }
        switch mode {
        case .pdf:
            if let doc = PDFDocument(data: data) { document = doc }
        case .html:
            html = String(decoding: data, as: UTF8.self)
        case .svg:
            svgPages = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// Writes a PDF of the main file, compiling one if the preview isn't a PDF.
    func exportPDF(to url: URL) async -> String? {
        if renderMode == .pdf, let document, !isCompiling, !diagnostics.contains(where: { $0.severity == .error }) {
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
        flushSaves()
        persistTask?.cancel()
        persist()
        compileTask?.cancel()
        stopWatcher()
        exportRunner.cancel()
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
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
        let prefix = root.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
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
