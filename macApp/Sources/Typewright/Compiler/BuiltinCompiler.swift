import Foundation
import TypstBridge

/// In-process typst that keeps its world between compiles, so edits only redo the work they affect.
final class BuiltinCompiler: @unchecked Sendable {
    static let version = String(cString: tw_version())

    /// Loads fonts in the background so the first preview doesn't wait for the scan.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { tw_warm_up() }
    }

    // The world is only touched on this queue.
    private let queue = DispatchQueue(label: "dev.bierdav.Typewright.typst", qos: .userInitiated)
    private let root: URL
    private var loadedWorld: OpaquePointer?
    private var world: OpaquePointer {
        if let loadedWorld { return loadedWorld }
        let world = tw_world_new(root.path)
        loadedWorld = world
        return world
    }
    private var overlays: Set<String> = []
    private struct PreviewPageID: Hashable {
        let high: UInt64
        let low: UInt64
    }
    private var previewCache: [PreviewPageID: CompiledPage] = [:]

    init(root: URL) {
        self.root = root
    }

    deinit {
        if let world = loadedWorld { queue.async { tw_world_free(world) } }
    }

    /// Rescans the folders searched for fonts; `onChange` runs on the main queue if the fonts differ.
    func setFontPaths(_ dirs: [URL], onChange: @escaping @MainActor () -> Void) {
        let paths = dirs.map(\.path)
        queue.async { [self] in
            let cStrings = paths.map { strdup($0)! }
            defer { cStrings.forEach { free($0) } }
            let changed = cStrings.map { UnsafePointer($0) }.withUnsafeBufferPointer {
                tw_world_set_font_paths(world, $0.baseAddress, $0.count)
            }
            if changed { DispatchQueue.main.async { MainActor.assumeIsolated(onChange) } }
        }
    }

    /// Forgets cached disk contents, e.g. after files changed outside the editor.
    func reset() {
        queue.async { [self] in tw_world_reset(world) }
    }

    /// Compiles `main` with `buffers` (paths relative to the root) replacing the files on disk.
    func compile(main: String, buffers: [String: String], format: RenderMode, incremental: Bool = false) async -> CompileResult {
        await withCheckedContinuation { cont in
            queue.async { [self] in cont.resume(returning: run(main: main, buffers: buffers, format: format, incremental: incremental)) }
        }
    }

    /// solveng's report on `main` compiled without output, or nil if it fails; for files the preview doesn't compile.
    func check(main: String, buffers: [String: String]) async -> String? {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                queue.async { [self] in
                    guard !cancellation.isCancelled else { cont.resume(returning: nil); return }
                    load(main: main, buffers: buffers)
                    let result = tw_world_compile(world, TWFormatCheck)
                    defer { tw_result_free(result) }
                    cont.resume(returning: result.data != nil ? Self.solvengReport(world) : nil)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private func load(main: String, buffers: [String: String]) {
        tw_world_set_main(world, main)
        for path in overlays.subtracting(buffers.keys) { tw_world_remove_overlay(world, path) }
        for (path, text) in buffers {
            var text = text
            text.withUTF8 { tw_world_set_overlay(world, path, $0.baseAddress!, $0.count) }
        }
        overlays = Set(buffers.keys)
    }

    private func run(main: String, buffers: [String: String], format: RenderMode, incremental: Bool) -> CompileResult {
        let start = Date()
        load(main: main, buffers: buffers)

        let twFormat: TWFormat = switch format {
        case .pdf: incremental ? TWFormatPDFPages : TWFormatPDF
        case .html: TWFormatHTML
        case .svg: TWFormatPDFPages
        }
        let result = tw_world_compile(world, twFormat)
        defer { tw_result_free(result) }
        let output = result.data.map { Data(bytes: $0, count: result.len) }
        let all = (try? JSONDecoder().decode([Entry].self, from: Data(String(cString: result.diagnostics).utf8))) ?? []
        // Diagnostics without a location can't be listed per file, so they become the failure log.
        let located = all.filter { !$0.path.isEmpty }
        let log = all.filter { $0.path.isEmpty }.map { "\($0.severity): \($0.message)" }.joined(separator: "\n")
        let previewPages = (format == .svg || incremental) && format != .html && output?.isEmpty == true ? readPreviewPages() : nil
        return CompileResult(
            output: output,
            diagnostics: located.map {
                Diagnostic(path: $0.path, line: $0.line, column: $0.column,
                           severity: Diagnostic.Severity(rawValue: $0.severity) ?? .error, message: $0.message, length: $0.length)
            },
            log: log,
            duration: Date().timeIntervalSince(start),
            // The world keeps the last report, which may be another main file's.
            solveng: output != nil ? Self.solvengReport(world) : nil,
            previewPages: previewPages
        )
    }

    private func readPreviewPages() -> [CompiledPage]? {
        var next: [PreviewPageID: CompiledPage] = [:]
        var pages: [CompiledPage] = []
        for index in 0..<tw_world_preview_page_count(world) {
            let page = tw_world_preview_page(world, index)
            let id = PreviewPageID(high: page.hash_high, low: page.hash_low)
            guard let bytes = page.data,
                  let pdf = previewCache[id] ?? next[id] ?? CompiledPage(data: Data(bytes: bytes, count: page.len)) else { return nil }
            next[id] = pdf
            pages.append(pdf)
        }
        previewCache = next
        return pages
    }

    private static func solvengReport(_ world: OpaquePointer) -> String {
        let report = tw_world_solveng(world)
        defer { tw_string_free(report) }
        return String(cString: report)
    }

    private struct Entry: Decodable {
        let path: String
        let line: Int
        let column: Int
        let length: Int?
        let severity: String
        let message: String
    }
}
