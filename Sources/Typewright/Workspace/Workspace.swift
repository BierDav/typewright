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
    var mainFile: URL? { didSet { scheduleCompile(delay: 0) } }
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

    init(url: URL) {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        root = isDir.boolValue ? url : url.deletingLastPathComponent()
        outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Typewright-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        reloadTree()
        let initial = isDir.boolValue ? defaultMain() : url
        mainFile = initial
        if let initial { select(initial) }
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
    }

    func reveal(_ diagnostic: Diagnostic) {
        guard !diagnostic.isFromPackage else { return }
        select(root.appendingPathComponent(diagnostic.path).standardizedFileURL)
        reveal = RevealRequest(line: diagnostic.line, column: diagnostic.column)
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

    func createFile() {
        var url = root.appendingPathComponent("untitled.typ")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("untitled-\(i).typ")
            i += 1
        }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        reloadTree()
        select(url)
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
        guard let main = mainFile, let binary = CompilerManager.shared.activeBinary else { return }
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
