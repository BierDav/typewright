import Foundation

struct CompileResult {
    let pdf: Data?
    let diagnostics: [Diagnostic]
    let duration: TimeInterval
}

/// Runs one `typst compile` invocation and can cancel it.
final class TypstRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func compile(binary: URL, main: URL, root: URL, output: URL) async -> CompileResult {
        let start = Date()
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "compile", main.path, output.path,
            "--root", root.path,
            "--diagnostic-format", "short",
        ]
        proc.currentDirectoryURL = root
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        lock.withLock { process = proc }
        defer { lock.withLock { if process === proc { process = nil } } }

        try? FileManager.default.removeItem(at: output)
        do { try proc.run() } catch {
            return CompileResult(
                pdf: nil,
                diagnostics: [Diagnostic(path: main.lastPathComponent, line: 1, column: 1, severity: .error,
                                         message: "failed to launch typst: \(error.localizedDescription)")],
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
            pdf: ok ? try? Data(contentsOf: output) : nil,
            diagnostics: Diagnostic.parse(stderr),
            duration: Date().timeIntervalSince(start)
        )
    }

    func cancel() {
        lock.withLock { process?.terminate() }
    }
}
