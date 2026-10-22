import XCTest
@testable import Typewright

final class CompilerTests: XCTestCase {
    func testDocumentCompilationPerformance() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEWRIGHT_PERF_DOCUMENT"] else {
            throw XCTSkip("Set TYPEWRIGHT_PERF_DOCUMENT to profile a local document")
        }
        let file = URL(fileURLWithPath: path)
        let source = try String(contentsOf: file, encoding: .utf8)
        let compiler = BuiltinCompiler(root: file.deletingLastPathComponent())
        for mode in [RenderMode.html, .pdf, .svg] {
            for revision in 0..<3 {
                let result = await compiler.compile(main: file.lastPathComponent,
                    buffers: [file.lastPathComponent: source + "\nPerformance revision \(revision)"], format: mode)
                let bytes = result.previewPages?.reduce(0) { $0 + $1.byteCount } ?? result.output?.count ?? 0
                print("Document \(mode), revision \(revision): \(result.duration) s, \(bytes) bytes")
                XCTAssertNotNil(result.output, result.log)
                XCTAssertFalse(result.diagnostics.contains { $0.severity == .error })
            }
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "#import \"lib.typ\": greeting\n#greeting".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        try "#let greeting = [Hello]".write(to: root.appendingPathComponent("lib.typ"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCompilesFromDisk() async {
        let result = await BuiltinCompiler(root: root).compile(main: "main.typ", buffers: [:], format: .html)
        XCTAssertTrue(String(decoding: result.output ?? Data(), as: UTF8.self).contains("Hello"))
    }

    func testBuffersOverrideDiskAndCanBeDropped() async {
        let compiler = BuiltinCompiler(root: root)
        let edited = await compiler.compile(main: "main.typ", buffers: ["lib.typ": "#let greeting = [Unsaved]"], format: .html)
        XCTAssertTrue(String(decoding: edited.output ?? Data(), as: UTF8.self).contains("Unsaved"))
        let reverted = await compiler.compile(main: "main.typ", buffers: [:], format: .html)
        XCTAssertTrue(String(decoding: reverted.output ?? Data(), as: UTF8.self).contains("Hello"))
    }

    func testReportsDiagnosticsWithUTF16Columns() async {
        let result = await BuiltinCompiler(root: root).compile(main: "main.typ", buffers: ["main.typ": "ä\n😀 #nope"], format: .pdf)
        XCTAssertNil(result.output)
        let error = result.diagnostics.first
        XCTAssertEqual(error?.path, "main.typ")
        XCTAssertEqual(error?.line, 2)
        XCTAssertEqual(error?.column, 5)
        XCTAssertEqual(error?.severity, .error)
    }

    func testHTMLKeepsFontFamiliesAndUserLines() async {
        let main = "#set text(font: \"Georgia\")\nHi\n\n#nope"
        let failed = await BuiltinCompiler(root: root).compile(main: "main.typ", buffers: ["main.typ": main], format: .html)
        XCTAssertEqual(failed.diagnostics.first?.path, "main.typ")
        XCTAssertEqual(failed.diagnostics.first?.line, 4)
        let result = await BuiltinCompiler(root: root).compile(main: "main.typ", buffers: ["main.typ": "#set text(font: \"Georgia\")\nHi"],
                                                               format: .html)
        XCTAssertTrue(String(decoding: result.output ?? Data(), as: UTF8.self).contains("font-family: &quot;georgia&quot;"))
    }

    func testIncrementalPDFKeepsUnchangedPages() async {
        let compiler = BuiltinCompiler(root: root)
        func pages(_ source: String) async -> [CompiledPage] {
            let result = await compiler.compile(main: "main.typ", buffers: ["main.typ": source], format: .pdf, incremental: true)
            XCTAssertEqual(result.output, Data())
            return result.previewPages ?? []
        }
        let before = await pages("One\n#pagebreak()\nTwo")
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(before.allSatisfy { $0.document.pageCount == 1 })
        let after = await pages("One\n#pagebreak()\nTwo, edited")
        XCTAssertEqual(after.first, before.first)
        XCTAssertNotEqual(after.last, before.last)
        let reverted = await pages("One\n#pagebreak()\nTwo")
        XCTAssertEqual(reverted.map { $0.page.string }, before.map { $0.page.string })
        let removed = await pages("One")
        XCTAssertEqual(removed.count, 1)
        let restored = await pages("One\n#pagebreak()\nTwo")
        XCTAssertEqual(restored.map { $0.page.string }, before.map { $0.page.string })
        let failed = await compiler.compile(main: "main.typ", buffers: ["main.typ": "#nope"], format: .pdf, incremental: true)
        XCTAssertNil(failed.output)
        _ = await compiler.compile(main: "main.typ", buffers: ["main.typ": "Other format"], format: .pdf)
        let recovered = await pages("One\n#pagebreak()\nTwo")
        XCTAssertEqual(recovered.map { $0.page.string }, before.map { $0.page.string })
    }

    func testProducesPDF() async {
        let result = await BuiltinCompiler(root: root).compile(main: "main.typ", buffers: [:], format: .pdf)
        XCTAssertEqual(result.output?.prefix(4), Data("%PDF".utf8))
    }

    @MainActor
    func testParsesWatchDuration() {
        XCTAssertEqual(TypstWatcher.duration(in: "[11:18:33] compiled successfully in 15.81 ms")!, 0.01581, accuracy: 1e-9)
        XCTAssertEqual(TypstWatcher.duration(in: "[11:18:33] compiled with warnings in 1.5 s"), 1.5)
        XCTAssertNil(TypstWatcher.duration(in: "[11:18:35] compiled with errors"))
    }
}
