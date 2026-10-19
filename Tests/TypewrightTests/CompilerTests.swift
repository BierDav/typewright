import XCTest
@testable import Typewright

final class CompilerTests: XCTestCase {
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
