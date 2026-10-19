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
    private let world: OpaquePointer
    private var overlays: Set<String> = []

    init(root: URL) {
        world = tw_world_new(root.path)
    }

    deinit {
        let world = world
        queue.async { tw_world_free(world) }
    }

    /// Forgets cached disk contents, e.g. after files changed outside the editor.
    func reset() {
        queue.async { [self] in tw_world_reset(world) }
    }

    /// Compiles `main` with `buffers` (paths relative to the root) replacing the files on disk.
    func compile(main: String, buffers: [String: String], format: RenderMode) async -> CompileResult {
        await withCheckedContinuation { cont in
            queue.async { [self] in cont.resume(returning: run(main: main, buffers: buffers, format: format)) }
        }
    }

    private func run(main: String, buffers: [String: String], format: RenderMode) -> CompileResult {
        let start = Date()
        tw_world_set_main(world, main)
        for path in overlays.subtracting(buffers.keys) { tw_world_remove_overlay(world, path) }
        for (path, text) in buffers {
            var text = text
            text.withUTF8 { tw_world_set_overlay(world, path, $0.baseAddress!, $0.count) }
        }
        overlays = Set(buffers.keys)

        let result = tw_world_compile(world, format == .pdf ? TWFormatPDF : TWFormatHTML)
        defer { tw_result_free(result) }
        let output = result.data.map { Data(bytes: $0, count: result.len) }
        let all = (try? JSONDecoder().decode([Entry].self, from: Data(String(cString: result.diagnostics).utf8))) ?? []
        // Diagnostics without a location can't be listed per file, so they become the failure log.
        let located = all.filter { !$0.path.isEmpty }
        let log = all.filter(\.path.isEmpty).map { "\($0.severity): \($0.message)" }.joined(separator: "\n")
        return CompileResult(
            output: output,
            diagnostics: located.map {
                Diagnostic(path: $0.path, line: $0.line, column: $0.column,
                           severity: Diagnostic.Severity(rawValue: $0.severity) ?? .error, message: $0.message)
            },
            log: log,
            duration: Date().timeIntervalSince(start)
        )
    }

    private struct Entry: Decodable {
        let path: String
        let line: Int
        let column: Int
        let severity: String
        let message: String
    }
}
