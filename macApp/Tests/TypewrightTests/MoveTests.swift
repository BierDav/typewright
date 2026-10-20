import XCTest
@testable import Typewright

@MainActor
final class MoveTests: XCTestCase {
    func testMovingAFileUpdatesPathsToItAndFromIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-move-\(UUID().uuidString)")
        let chapters = root.appendingPathComponent("chapters")
        let parts = root.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main.typ")
        let intro = chapters.appendingPathComponent("intro.typ")
        try "#include \"chapters/intro.typ\"".write(to: main, atomically: true, encoding: .utf8)
        try "#image(\"../logo.png\")".write(to: intro, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: root.appendingPathComponent("logo.png").path, contents: Data())

        let ws = Workspace(url: root)
        defer { ws.close() }
        ws.move(intro, into: parts)
        let moved = parts.appendingPathComponent("intro.typ")
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "#include \"parts/intro.typ\"")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "#image(\"../logo.png\")", "same depth, same path")

        ws.rename(moved, to: "start.typ")
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "#include \"parts/start.typ\"")
        ws.move(parts.appendingPathComponent("start.typ"), into: root)
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "#include \"start.typ\"")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("start.typ"), encoding: .utf8), "#image(\"logo.png\")")
    }
}
