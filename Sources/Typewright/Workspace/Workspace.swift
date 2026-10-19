import AppKit
import Observation
import PDFKit

struct FileNode: Identifiable, Hashable {
    let url: URL
    let children: [FileNode]?
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isTypst: Bool { url.pathExtension == "typ" }
    var isEditable: Bool { children == nil && Workspace.textExtensions.contains(url.pathExtension.lowercased()) }
}

struct RevealRequest: Equatable {
    let id = UUID()
    let line: Int
    let column: Int
}

/// One open project folder: files, buffers, autosave and compilation.
@MainActor @Observable
final class Workspace {
    nonisolated static let textExtensions: Set<String> = ["typ", "bib", "yml", "yaml", "toml", "txt", "csv", "json", "xml", "md", "svg"]

    let root: URL
    private(set) var tree: [FileNode] = []
    private(set) var selectedFile: URL?
    private(set) var text = ""
    private(set) var revision = 0
    /// The file compiled for the preview; nil hides the preview.
    private(set) var previewFile: URL?
    var split: Double { didSet { schedulePersist() } }
    /// Folders open in the sidebar; everything else starts collapsed.
    var expanded: Set<URL> = [] { didSet { schedulePersist() } }
    var reveal: RevealRequest?

    private(set) var document: PDFDocument?
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var isCompiling = false
    private(set) var lastDuration: TimeInterval?

    @ObservationIgnored let preview = PreviewController()
    private var buffers: [URL: String] = [:]
    private var dirty: Set<URL> = []
    private var compileTask: Task<Void, Never>?
    private var generation = 0
    private let runner = TypstRunner()
    private let outputDir: URL
    @ObservationIgnored private var editorStates: [URL: EditorState] = [:]
    @ObservationIgnored private var previewStates: [URL: PreviewState] = [:]
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    init(url: URL) {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        root = isDir.boolValue ? url : url.deletingLastPathComponent()
        outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Typewright-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

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

    var name: String { root.lastPathComponent }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    // MARK: - Files

    func reloadTree() {
        tree = Self.scan(root, depth: 0)
    }

    func select(_ url: URL) {
        guard url != selectedFile else { return }
        flushSaves()
        selectedFile = url
        text = buffers[url] ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        buffers[url] = text
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
        diagnostics = []
        lastDuration = nil
        preview.pendingRestore = url.flatMap { previewStates[$0] }
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
        let prefix = root.path + "/"
        func relative(_ url: URL) -> String? {
            url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : nil
        }
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
        if let selected = selectedFile, !dirty.contains(selected),
           let disk = try? String(contentsOf: selected, encoding: .utf8), disk != text {
            text = disk
            buffers[selected] = disk
            revision += 1
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
        dirty.insert(url)
        scheduleCompile(delay: 0.25)
    }

    func flushSaves() {
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

    private func compile() async {
        flushSaves()
        guard let main = previewFile, let binary = CompilerManager.shared.activeBinary else { return }
        generation += 1
        let current = generation
        let output = outputDir.appendingPathComponent("preview-\(current).pdf")

        runner.cancel()
        isCompiling = true
        let result = await runner.compile(binary: binary, main: main, root: root, output: output)
        try? FileManager.default.removeItem(at: output)
        guard current == generation else { return }

        isCompiling = false
        diagnostics = result.diagnostics
        lastDuration = result.duration
        if let pdf = result.pdf, let doc = PDFDocument(data: pdf) {
            document = doc
        }
    }

    func close() {
        flushSaves()
        persistTask?.cancel()
        persist()
        compileTask?.cancel()
        runner.cancel()
        try? FileManager.default.removeItem(at: outputDir)
    }

    // MARK: - Helpers

    private func defaultMain() -> URL? {
        let main = root.appendingPathComponent("main.typ")
        if FileManager.default.fileExists(atPath: main.path) { return main }
        return Self.flatten(tree).first { $0.isTypst }?.url
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
                return FileNode(url: url.standardizedFileURL, children: isDir ? scan(url, depth: depth + 1) : nil)
            }
            .sorted { a, b in
                if (a.children == nil) != (b.children == nil) { return a.children != nil }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}
