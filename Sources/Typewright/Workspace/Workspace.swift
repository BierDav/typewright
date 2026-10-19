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
}

/// One open project folder: files, buffers, autosave and compilation.
@MainActor @Observable
final class Workspace {
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
    private(set) var diagnostics: [Diagnostic] = []
    /// Compiler output when compilation failed without diagnostics.
    private(set) var failureLog: String?
    private(set) var isCompiling = false
    private(set) var lastDuration: TimeInterval?

    @ObservationIgnored let preview = PreviewController()
    @ObservationIgnored let htmlPreview = HTMLPreviewController()
    /// Shows a selected PDF file instead of the compiled document.
    @ObservationIgnored let filePreview = PreviewController()
    private var buffers: [URL: String] = [:]
    private var dirty: Set<URL> = []
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
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    init(url: URL) {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        root = isDir.boolValue ? url : url.deletingLastPathComponent()
        builtin = BuiltinCompiler(root: root)
        renderMode = UserDefaults.standard.string(forKey: "renderMode").flatMap(RenderMode.init) ?? .pdf

        let saved = ProjectStore.state(for: root)
        let state = saved ?? ProjectState()
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
        expanded = Set(state.expanded.compactMap(resolve))
        let initial = isDir.boolValue ? resolve(state.selected) ?? defaultMain() : url
        if let initial { select(initial) }
        // New projects start out previewing their main file; known ones keep their choice, even none.
        if saved == nil {
            previewFile = initial?.pathExtension == "typ" ? initial : defaultMain()
        } else {
            previewFile = resolve(state.preview)
        }
        preview.pendingRestore = previewFile.flatMap { previewStates[$0] }
    }

    /// Whether the compiled output for the current render mode is available.
    var hasOutput: Bool {
        renderMode == .pdf ? document != nil : html != nil
    }

    var name: String { root.lastPathComponent }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    // MARK: - Files

    func reloadTree() {
        tree = Self.scan(root, depth: 0)
        // New, removed or renamed files must reach the built-in compiler too.
        builtin.reset()
    }

    func select(_ url: URL) {
        guard url != selectedFile else { return }
        let kind = FileKind(url: url)
        guard kind.isOpenable else { return }
        flushSaves()
        selectedFile = url
        selectedKind = kind
        if kind.isEditable {
            text = buffers[url] ?? Self.read(url) ?? ""
            buffers[url] = text
        } else {
            text = ""
        }
        if kind == .pdf { filePreview.show(PDFDocument(url: url), keepingPosition: false) }
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
        failureLog = nil
        diagnostics = []
        lastDuration = nil
        preview.pendingRestore = url.flatMap { previewStates[$0] }
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

    private func capturePreviewState() {
        guard let main = previewFile, document != nil, preview.view.document === document,
              let state = preview.state() else { return }
        previewStates[main] = state
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
        var state = ProjectState()
        state.selected = selectedFile.flatMap(relative)
        state.preview = previewFile.flatMap(relative)
        state.split = split
        for (url, s) in editorStates { if let key = relative(url) { state.editors[key] = s } }
        for (url, s) in previewStates { if let key = relative(url) { state.previews[key] = s } }
        state.expanded = expanded.compactMap(relative).sorted()
        ProjectStore.save(state, for: root)
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
        scheduleCompile(delay: 0)
    }

    @discardableResult
    func createFile(in dir: URL? = nil) -> URL {
        let url = Self.unique(in: dir ?? root, name: "untitled", ext: "typ")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        reloadTree()
        select(url)
        return url
    }

    @discardableResult
    func createFolder(in dir: URL? = nil) -> URL {
        let url = Self.unique(in: dir ?? root, name: "New Folder", ext: nil)
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

    func textDidChange(_ newText: String) {
        guard let url = selectedFile else { return }
        text = newText
        buffers[url] = newText
        // External compilers only see the disk, so every edit is saved right away.
        if case .binary = CompilerManager.shared.active {
            try? newText.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        dirty.insert(url)
        scheduleAutosave()
        // HTML skips layout, so it can keep up with every keystroke.
        scheduleCompile(delay: renderMode == .html ? 0 : 0.25)
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
        if let watcher, watcher.binary == binary, watcher.main == main, watcher.format == mode { return }
        stopWatcher()
        var started: TypstWatcher?
        let watcher = TypstWatcher(
            binary: binary, main: main, root: root, format: mode,
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
        lastDuration = result.duration
        failureLog = result.output == nil && result.diagnostics.isEmpty && !result.log.isEmpty ? result.log : nil
        guard let data = result.output else { return }
        switch mode {
        case .pdf:
            if let doc = PDFDocument(data: data) { document = doc }
        case .html:
            html = String(decoding: data, as: UTF8.self)
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
            result = await exportRunner.compile(binary: binary, main: previewFile, root: root, output: url)
            if result.output != nil { return nil }
        }
        let errors = result.diagnostics.filter { $0.severity == .error }
        return errors.isEmpty ? result.log : errors.map { "\($0.path):\($0.line): \($0.message)" }.joined(separator: "\n")
    }

    func close() {
        flushSaves()
        persistTask?.cancel()
        persist()
        compileTask?.cancel()
        stopWatcher()
        exportRunner.cancel()
    }

    // MARK: - Helpers

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
