import AppKit
import XCTest
@testable import Typewright

@MainActor
final class QuickFixTests: XCTestCase {
    func testBuiltinCompilerReportsMissingFontsTheWayTheFixExpects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "#set text(font: \"Poppins\")\nHello".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        let result = await BuiltinCompiler(root: root).compile(main: "main.typ", buffers: [:], format: .pdf)
        let families = result.diagnostics.compactMap { QuickFixes.missingFont(in: $0.message) }
        XCTAssertEqual(families, ["poppins"])
    }

    func testOtherMessagesHaveNoFontFix() {
        XCTAssertNil(QuickFixes.missingFont(in: "unknown variable: x"))
        XCTAssertEqual(QuickFixes.missingFont(in: "unknown font family: inter"), "inter")
    }

    func testMissingFontsCanAlwaysBeSearchedOnGoogle() {
        let diagnostic = Diagnostic(path: "main.typ", line: 1, column: 1, severity: .warning, message: "unknown font family: zzz nofont")
        let fixes = QuickFixes.fixes(for: diagnostic, root: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(fixes.last?.id, "font.search")
        XCTAssertNotNil(fixes.last?.run)
    }

    func testUndeclaredOperatorsOfferAMathOpDefinition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = "#graph($ tri(x) $)"
        let main = root.appendingPathComponent("main.typ")
        try document.write(to: main, atomically: true, encoding: .utf8)
        let workspace = Workspace(url: main)
        defer { workspace.close() }
        let editor = TypstTextView(frame: .zero)
        editor.string = document
        workspace.find.textView = editor
        let diagnostic = Diagnostic(path: "main.typ", line: 1, column: 10, severity: .error, message: "unknown variable: tri")
        let fixes = workspace.quickFixes(for: diagnostic)
        XCTAssertTrue(fixes.contains { $0.id == "solveng.operator" })
        XCTAssertFalse(fixes.contains { $0.id == "solveng.quote" })
        fixes.first { $0.id == "solveng.operator" }?.run?()
        XCTAssertEqual(editor.string, "#let tri = math.op(\"tri\")\n" + document)
    }

}
