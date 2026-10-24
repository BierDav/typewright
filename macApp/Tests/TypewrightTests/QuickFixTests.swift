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

    func testUndeclaredNamesInMathOfferQuoting() throws {
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
        XCTAssertTrue(fixes.contains { $0.id == "solveng.quote" })
        XCTAssertFalse(fixes.contains { $0.id == "solveng.operator" })
        fixes.first { $0.id == "solveng.quote" }?.run?()
        XCTAssertEqual(editor.string, "#graph($ \"tri\"(x) $)")
    }

    func testAddingLetmeoutImportsItAboveTheDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main.typ")
        try "= Hello".write(to: main, atomically: true, encoding: .utf8)
        let workspace = Workspace(url: main)
        defer { workspace.close() }
        XCTAssertEqual(workspace.previewFile?.standardizedFileURL, main.standardizedFileURL)
        // Shown in the editor: one undoable edit.
        var applied: [TextEdit] = []
        workspace.find.applyEdits = { edits, _ in applied = edits }
        workspace.addLetmeout("@preview/letmeout:0.2.0")
        XCTAssertEqual(applied, [TextEdit(range: NSRange(location: 0, length: 0),
                                          newText: "#import \"@preview/letmeout:0.2.0\": *\n#show: letmeout\n\n")])
        // Without an editor the buffer changes.
        workspace.find.applyEdits = nil
        workspace.addLetmeout("@local/letmeout:0.1.0")
        XCTAssertEqual(workspace.text, "#import \"@local/letmeout:0.1.0\": *\n#show: letmeout\n\n= Hello")
        // An existing import keeps its version and gets the show rule below it.
        workspace.updateBuffer(main, text: "#import \"@letmeout/letmeout:0.1.0\": *\n#import extras: *\n= Hello")
        XCTAssertTrue(workspace.previewImportsLetmeout)
        workspace.addLetmeout("")
        XCTAssertEqual(workspace.text, "#import \"@letmeout/letmeout:0.1.0\": *\n#show: letmeout\n#import extras: *\n= Hello")
    }

    func testDocsCommandLinksReplaceThePackageVersion() throws {
        let text = "#import \"@solveng/solveng:0.2.0\": *\n"
        let link = try XCTUnwrap(URL(string: "command:tinymist.replaceText?%7B%22range%22%3A%7B%22end%22%3A%7B%22character%22%3A32%2C%22line%22%3A0%7D%2C%22start%22%3A%7B%22character%22%3A8%2C%22line%22%3A0%7D%7D%2C%22replace%22%3A%22%5C%22%40solveng%2Fsolveng%3A1%2E0%2E0%5C%22%22%7D"))
        let edit = try XCTUnwrap(LanguageCommand.replaceText(in: link, text: text))
        XCTAssertEqual((text as NSString).substring(with: edit.range), "\"@solveng/solveng:0.2.0\"")
        XCTAssertEqual(edit.text, "\"@solveng/solveng:1.0.0\"")
        XCTAssertNil(LanguageCommand.replaceText(in: try XCTUnwrap(URL(string: "https://typst.app")), text: text))
    }

    func testMissingPackagesOfferVersionsHereAndInOtherNamespaces() throws {
        let library = PackageLibrary.shared
        let here = "twfix\(Int.random(in: 1000...9999))"
        let other = "twother\(Int.random(in: 1000...9999))"
        let name = "twdemo\(Int.random(in: 1000...9999))"
        defer {
            for namespace in [here, other] {
                try? FileManager.default.removeItem(at: library.dataDirectory.appending(path: namespace))
            }
            library.refresh()
        }
        for (namespace, version) in [(here, "1.0.0"), (other, "0.3.0")] {
            let folder = library.dataDirectory.appending(path: "\(namespace)/\(name)/\(version)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "[package]\nname = \"\(name)\"\nversion = \"\(version)\"\n"
                .write(to: folder.appendingPathComponent("typst.toml"), atomically: true, encoding: .utf8)
        }
        library.refresh()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = "#import \"@\(here)/\(name):0.2.0\": *\n"
        let main = root.appendingPathComponent("main.typ")
        try document.write(to: main, atomically: true, encoding: .utf8)
        let workspace = Workspace(url: main)
        defer { workspace.close() }
        let editor = TypstTextView(frame: .zero)
        editor.string = document
        workspace.find.textView = editor
        let diagnostic = Diagnostic(path: "main.typ", line: 1, column: 10, severity: .error,
                                    message: "package not found (searched for @\(here)/\(name):0.2.0)")
        let fixes = workspace.quickFixes(for: diagnostic)
        XCTAssertEqual(fixes.map(\.id), ["package.missing.@\(here)/\(name):1.0.0",
                                        "package.missing.@\(other)/\(name):0.3.0"])
        fixes.first?.run?()
        XCTAssertEqual(editor.string, "#import \"@\(here)/\(name):1.0.0\": *\n")
    }

}
