import Foundation

enum RenderMode: String, CaseIterable, Codable {
    case pdf, html, svg
    static let allCases: [RenderMode] = [.pdf, .html]
    var migrated: RenderMode { self == .svg ? .pdf : self }
}

struct CompileResult {
    /// Incremental preview output is empty on success; its PDF pages are in `previewPages`.
    let output: Data?
    let diagnostics: [Diagnostic]
    /// Raw stderr, for failures typst doesn't report as diagnostics.
    let log: String
    let duration: TimeInterval
    /// solveng's report from the built-in compiler (see `tw_world_solveng`); external compilers have none.
    var solveng: String? = nil
    /// Unchanged pages reuse their parsed PDFs by layout hash.
    var previewPages: [CompiledPage]? = nil
}

/// Runs one `typst compile` invocation and can cancel it.
final class TypstRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func compile(binary: URL, main: URL, root: URL, output: URL, format: RenderMode = .pdf,
                 fontPaths: [URL] = []) async -> CompileResult {
        let start = Date()
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "compile", main.path, output.path,
            "--root", root.path,
            "--diagnostic-format", "short",
        ]
        // HTML export is experimental and gated behind a feature flag.
        if format == .html { proc.arguments! += ["--format", "html", "--features", "html"] }
        proc.currentDirectoryURL = root
        proc.environment = TypstRunner.environment(fontPaths: fontPaths)
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        lock.withLock { process = proc }
        defer { lock.withLock { if process === proc { process = nil } } }

        try? FileManager.default.removeItem(at: output)
        do { try proc.run() } catch {
            return CompileResult(
                output: nil,
                diagnostics: [Diagnostic(path: main.lastPathComponent, line: 1, column: 1, severity: .error,
                                         message: "failed to launch typst: \(error.localizedDescription)")],
                log: "",
                duration: 0
            )
        }
        // Drain stderr off the main thread so a full pipe can't block typst.
        let stderr = await Task.detached {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value

        let ok = proc.terminationReason == .exit && proc.terminationStatus == 0
        return CompileResult(
            output: ok ? try? Data(contentsOf: output) : nil,
            diagnostics: Diagnostic.parse(stderr),
            log: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            duration: Date().timeIntervalSince(start)
        )
    }

    /// typst reads extra font folders from `TYPST_FONT_PATHS`, searched before the system's.
    static func environment(fontPaths: [URL]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TYPST_FONT_PATHS"] = fontPaths.map(\.path).joined(separator: ":")
        return env
    }

    func cancel() {
        lock.withLock { process?.terminate() }
    }
}
