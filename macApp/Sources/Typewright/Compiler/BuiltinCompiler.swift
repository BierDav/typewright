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
    /// Main files whose HTML fails with the font spans; they compile without them from then on.
    private var unwrapped: Set<String> = []

    init(root: URL) {
        world = tw_world_new(root.path)
    }

    deinit {
        let world = world
        queue.async { tw_world_free(world) }
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
    func compile(main: String, buffers: [String: String], format: RenderMode) async -> CompileResult {
        await withCheckedContinuation { cont in
            queue.async { [self] in cont.resume(returning: run(main: main, buffers: buffers, format: format)) }
        }
    }

    /// Wraps the main file for HTML so text carries its font family, which typst's HTML export drops.
    private static let htmlWrapper = ".typewright-html.typ"
    private static let htmlPrelude = """
        #show text: it => context if target() == "html" {
          let fonts = text.font
          let fonts = if type(fonts) == array { fonts } else { (fonts,) }
          let names = fonts.map(f => if type(f) == dictionary { f.name } else { f })
          html.elem("span", attrs: (style: "font-family: " + names.map(n => "\\"" + n + "\\"").join(", ")), it)
        } else { it }

        """

    private func run(main: String, buffers: [String: String], format: RenderMode) -> CompileResult {
        let start = Date()
        let result = run(main: main, buffers: buffers, format: format, wrapped: format == .html && !unwrapped.contains(main),
                         start: start)
        // The font spans are invalid in some places, like raw text elements; plain output beats none.
        guard format == .html, result.output == nil, result.wrapperFailed else { return result.compiled }
        unwrapped.insert(main)
        return run(main: main, buffers: buffers, format: format, wrapped: false, start: start).compiled
    }

    private func run(main: String, buffers: [String: String], format: RenderMode, wrapped: Bool,
                     start: Date) -> (compiled: CompileResult, output: Data?, wrapperFailed: Bool) {
        var buffers = buffers
        var main = main
        if wrapped {
            // Included rather than edited, so diagnostics keep pointing at the user's file and lines.
            let quoted = main.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            buffers[Self.htmlWrapper] = Self.htmlPrelude + "#include \"/\(quoted)\"\n"
            main = Self.htmlWrapper
        }
        tw_world_set_main(world, main)
        for path in overlays.subtracting(buffers.keys) { tw_world_remove_overlay(world, path) }
        for (path, text) in buffers {
            var text = text
            text.withUTF8 { tw_world_set_overlay(world, path, $0.baseAddress!, $0.count) }
        }
        overlays = Set(buffers.keys)

        let twFormat: TWFormat = switch format {
        case .pdf: TWFormatPDF
        case .html: TWFormatHTML
        case .svg: TWFormatSVG
        }
        let result = tw_world_compile(world, twFormat)
        defer { tw_result_free(result) }
        let output = result.data.map { Data(bytes: $0, count: result.len) }
        let all = (try? JSONDecoder().decode([Entry].self, from: Data(String(cString: result.diagnostics).utf8))) ?? []
        // Diagnostics without a location can't be listed per file, so they become the failure log.
        let located = all.filter { !$0.path.isEmpty && $0.path != Self.htmlWrapper }
        let log = all.filter { $0.path.isEmpty || $0.path == Self.htmlWrapper }.map { "\($0.severity): \($0.message)" }.joined(separator: "\n")
        let wrapperFailed = all.contains { $0.path == Self.htmlWrapper && $0.severity == "error" }
        let compiled = CompileResult(
            output: output,
            diagnostics: located.map {
                Diagnostic(path: $0.path, line: $0.line, column: $0.column,
                           severity: Diagnostic.Severity(rawValue: $0.severity) ?? .error, message: $0.message)
            },
            log: log,
            duration: Date().timeIntervalSince(start),
            solveng: Self.solvengReport(world)
        )
        return (compiled, output, wrapperFailed)
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
        let severity: String
        let message: String
    }
}
