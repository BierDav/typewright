import Foundation
import TypewrightCore

/// Keeps `typst watch` running for an external compiler; it recompiles whenever the saved files change.
@MainActor
final class TypstWatcher {
    let binary: URL
    let main: URL
    let format: RenderMode
    let fontPaths: [URL]

    private let process = Process()
    private let output: URL
    private let onCompiling: () -> Void
    private let onResult: (CompileResult) -> Void
    private var partial = ""
    /// The `[time] compiled …` line of the block being read, followed by its diagnostics.
    private var status: String?
    private var block: [String] = []
    private var finishTask: Task<Void, Never>?
    private var stopped = false
    private let images = PreviewImages()

    init(binary: URL, main: URL, root: URL, format: RenderMode, fontPaths: [URL],
         onCompiling: @escaping () -> Void, onResult: @escaping (CompileResult) -> Void) {
        self.binary = binary
        self.main = main
        self.format = format
        self.fontPaths = fontPaths
        self.onCompiling = onCompiling
        self.onResult = onResult
        // typst can only write its output to a file.
        output = FileManager.default.temporaryDirectory
            .appendingPathComponent("Typewright-\(UUID().uuidString).\(format.rawValue)")

        process.executableURL = binary
        process.arguments = ["watch", main.path, output.path, "--root", root.path, "--diagnostic-format", "short"]
        if format == .html { process.arguments! += ["--format", "html", "--features", "html"] }
        process.currentDirectoryURL = root
        process.environment = TypstRunner.environment(fontPaths: fontPaths)
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        // Main-queue hops keep the chunks in order.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited() } }
        }
    }

    func start() {
        onCompiling()
        do { try process.run() } catch {
            onResult(CompileResult(output: nil, diagnostics: [],
                                   log: "Failed to launch typst: \(error.localizedDescription)", duration: 0))
        }
    }

    func stop() {
        stopped = true
        finishTask?.cancel()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: output)
    }

    private func consume(_ data: Data) {
        guard !stopped, !data.isEmpty else { return }
        partial += String(decoding: data, as: UTF8.self)
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        for line in lines { handle(line) }
        // The last block has no header after it, so it ends once typst goes quiet.
        finishTask?.cancel()
        guard status != nil else { return }
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("watching ") || line.hasPrefix("writing to ") {
            finish()
        } else if line.hasPrefix("["), line.contains("] compiling") {
            finish()
            onCompiling()
        } else if line.hasPrefix("["), line.contains("] compiled ") {
            status = line
            block = []
        } else if status != nil, !line.isEmpty {
            block.append(line)
        }
    }

    private func finish() {
        finishTask?.cancel()
        guard let status else { return }
        self.status = nil
        let log = block.joined(separator: "\n")
        let ok = !status.contains("with errors")
        let data = ok ? try? Data(contentsOf: output) : nil
        onResult(CompileResult(
            output: format == .html ? data.map(images.rewrite) : data,
            diagnostics: Diagnostic.parse(log),
            log: log,
            duration: Self.duration(in: status) ?? 0
        ))
    }

    private func exited() {
        guard !stopped else { return }
        finish()
        let log = (partial + block.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        onResult(CompileResult(output: nil, diagnostics: Diagnostic.parse(log),
                               log: log.isEmpty ? "typst watch exited unexpectedly." : log, duration: 0))
    }

    /// Parses `compiled successfully in 15.81 ms`.
    static func duration(in status: String) -> TimeInterval? {
        compileDuration(status: status)
    }
}
