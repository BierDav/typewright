import XCTest
@testable import Typewright

@MainActor
final class SolvengContextTests: XCTestCase {
    func testWorksheetNamesWorkBeforeCompilation() throws {
        let document = """
        #import "@solveng/solveng:1.0.0": *
        #worksheet(evaluate: true)[
          $ "pytagoras"(a, b, c) := a^2 + b^2 = c^2 $
          $ "circle"(x, r) := "pytagoras"(x,b,r) -> solve(b) $
          $ x´ := 3 $
          $ r` := 3 $
          $ z := x´ + r` $
        ]
        """
        let source = document as NSString
        let context = SolvengSupport.context(files: [], report: "", path: "main.typ", main: true)
        let call = source.range(of: "pytagoras", options: .backwards).location
        let definition = try XCTUnwrap(SolvengSupport.definition(document, context: context, offset: call))
        XCTAssertEqual(definition.start, source.range(of: "\"pytagoras\"").location)
        XCTAssertEqual(SolvengSupport.usages(document, context: context, offset: call).count, 2)
        XCTAssertEqual(SolvengSupport.rename(document, context: context, offset: call, to: "hypotenuse").count, 2)
        let tokens = try XCTUnwrap(SolvengSupport.highlight(document, context: context)).tokens
        for name in ["x´", "r`"] {
            let at = source.range(of: name, options: .backwards).location
            XCTAssertEqual(SolvengSupport.renameTarget(document, context: context, offset: at + 1)?.name, name)
            XCTAssertEqual(SolvengSupport.usages(document, context: context, offset: at).count, 2)
            XCTAssertEqual(SolvengSupport.rename(document, context: context, offset: at, to: "q").count, 2)
            XCTAssertTrue(stride(from: 0, to: tokens.count, by: 3).contains {
                tokens[$0] == at && tokens[$0 + 1] == 2 && tokens[$0 + 2] == 6
            })
        }
    }

    func testChapterSeesTheMainFileAndItsDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-solveng-\(UUID().uuidString)")
        let chapters = root.appendingPathComponent("chapters")
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main.typ")
        let chapter = chapters.appendingPathComponent("one.typ")
        try "#import \"defaults.typ\": *\n#show: setup\n#show: worksheet\n#include \"chapters/one.typ\""
            .write(to: main, atomically: true, encoding: .utf8)
        try "#let setup = worksheet-config.with(integration: \"none\")\n#worksheet(\"U := 5 V\")"
            .write(to: root.appendingPathComponent("defaults.typ"), atomically: true, encoding: .utf8)
        try "#import \"../loop.typ\"\nText $P := U$".write(to: chapter, atomically: true, encoding: .utf8)
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
        XCTAssertTrue(context.contains("#show: worksheet"), "the main file")
        XCTAssertTrue(context.contains("integration: \"none\""), "its defaults")
        XCTAssertTrue(context.contains("#import \"chapters/one.typ\""), "the chapter's own import")
        XCTAssertFalse(context.contains("Text $P := U$"), "not the chapter itself, despite the loop")
    }

}
