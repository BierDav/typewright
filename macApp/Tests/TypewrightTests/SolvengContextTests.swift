import XCTest
@testable import Typewright

@MainActor
final class SolvengContextTests: XCTestCase {
    func testChapterSeesTheMainFileAndItsDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-solveng-\(UUID().uuidString)")
        let chapters = root.appendingPathComponent("chapters")
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main.typ")
        let chapter = chapters.appendingPathComponent("one.typ")
        try "#import \"defaults.typ\": *\n#show: setup\n#show: solve-block\n#include \"chapters/one.typ\""
            .write(to: main, atomically: true, encoding: .utf8)
        try "#let setup = solve-config.with(integration: \"full\")\n#def(\"U = 5 V\")"
            .write(to: root.appendingPathComponent("defaults.typ"), atomically: true, encoding: .utf8)
        try "#import \"../loop.typ\"\nText `P = U`".write(to: chapter, atomically: true, encoding: .utf8)
        try "#import \"chapters/one.typ\"".write(to: root.appendingPathComponent("loop.typ"), atomically: true, encoding: .utf8)

        let ws = Workspace(url: main)
        defer { ws.close() }
        ws.select(chapter)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ws.solvengContext().utf8)) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, "chapters/one.typ")
        XCTAssertEqual(json["main"] as? Bool, false)
        let files = try XCTUnwrap(json["files"] as? [[String: String]])
        XCTAssertEqual(files.first?["path"], "main.typ")
        let context = files.compactMap { $0["text"] }.joined(separator: "\n")
        XCTAssertTrue(context.contains("#show: solve-block"), "the main file")
        XCTAssertTrue(context.contains("integration: \"full\""), "its defaults")
        XCTAssertTrue(context.contains("#import \"chapters/one.typ\""), "the chapter's own import")
        XCTAssertFalse(context.contains("Text `P = U`"), "not the chapter itself, despite the loop")
    }
}
