import AppKit
import XCTest
@testable import Typewright

@MainActor
private final class FakeLanguage: EditorLanguage {
    var renamedTo: String?
    var source: (() -> String)?
    func completions(at offset: Int) async -> [CompletionItem] { [] }
    func goToDefinition(at offset: Int) async -> [SymbolUsage] { [] }
    func open(_ location: SourceLocation) {}
    func hover(at offset: Int) async -> (markdown: String, range: NSRange?)? { nil }
    func occurrences(at offset: Int) async -> [NSRange] {
        if let text = source?() {
            return SolvengSupport.usages(text, context: "", offset: offset).filter { $0.path == nil }
                .map { NSRange(location: $0.start, length: $0.end - $0.start) }
        }
        return [NSRange(location: 5, length: 5), NSRange(location: 16, length: 5), NSRange(location: 27, length: 5)]
    }
    func formattingEdits() async -> [TextEdit] { [] }
    func renameTarget(at offset: Int) async -> (range: NSRange, name: String)? {
        if let text = source?() {
            guard let target = SolvengSupport.renameTarget(text, context: "", offset: offset) else { return nil }
            return (NSRange(location: target.start, length: target.end - target.start), target.name)
        }
        return (NSRange(location: 16, length: 5), "greet")
    }
    func rename(at offset: Int, to name: String) async -> [TextEdit] {
        renamedTo = name
        if let text = source?() {
            return SolvengSupport.rename(text, context: "", offset: offset, to: name).filter { $0.path == nil }
                .map { TextEdit(range: NSRange(location: $0.start, length: $0.end - $0.start), newText: $0.text) }
        }
        return [5, 16, 27].map { TextEdit(range: NSRange(location: $0, length: 5), newText: name) }
    }
}

@MainActor
final class RenameTests: XCTestCase {
    private func setUp(_ text: String) -> (TypstTextView, CodeEditor.Coordinator, FakeLanguage) {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.allowsUndo = true
        tv.string = text
        let c = CodeEditor.Coordinator()
        c.textView = tv
        tv.delegate = c
        let language = FakeLanguage()
        c.language = language
        return (tv, c, language)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    func testTypingMirrorsAndEnterRenames() async {
        let (tv, c, language) = setUp("#let greet = 1\n#greet and #greet")
        tv.setSelectedRange(NSRange(location: 18, length: 0))
        c.startRename()
        await settle()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 16, length: 5))
        tv.insertText("hello", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "#let hello = 1\n#hello and #hello")
        _ = c.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        await settle()
        XCTAssertEqual(language.renamedTo, "hello")
        XCTAssertEqual(tv.string, "#let hello = 1\n#hello and #hello")
    }

    func testEscapeRestores() async {
        let (tv, c, language) = setUp("#let greet = 1\n#greet and #greet")
        tv.setSelectedRange(NSRange(location: 18, length: 0))
        c.startRename()
        await settle()
        tv.insertText("x", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "#let x = 1\n#x and #x")
        _ = c.textView(tv, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(tv.string, "#let greet = 1\n#greet and #greet")
        XCTAssertNil(language.renamedTo)
    }

    func testUndoStepsBackThroughTheRename() async {
        let (tv, c, language) = setUp("#let greet = 1\n#greet and #greet")
        tv.setSelectedRange(NSRange(location: 18, length: 0))
        c.startRename()
        await settle()
        tv.insertText("h", replacementRange: tv.selectedRange())
        tv.insertText("i", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "#let hi = 1\n#hi and #hi")
        XCTAssertTrue(c.undoRename())
        XCTAssertEqual(tv.string, "#let h = 1\n#h and #h")
        XCTAssertTrue(c.redoRename())
        XCTAssertEqual(tv.string, "#let hi = 1\n#hi and #hi")
        XCTAssertTrue(c.undoRename())
        XCTAssertTrue(c.undoRename())
        XCTAssertEqual(tv.string, "#let greet = 1\n#greet and #greet")
        // Undoing past the start cancels the rename.
        XCTAssertTrue(c.undoRename())
        XCTAssertFalse(c.undoRename())
        XCTAssertNil(language.renamedTo)
    }

    func testSolvengPreviewFormatsEverySpellingAndCancelRestoresThem() async {
        let original = "#show: worksheet\n$\"Delta2tau\" := 3$\n#graph($\"Delta2tau\" x$)"
        let (tv, c, language) = setUp(original)
        language.source = { [weak tv] in tv?.string ?? "" }
        var published: [String] = []
        c.onChange = { text, _ in published.append(text) }
        tv.setSelectedRange(NSRange(location: (original as NSString).range(of: "Delta2tau").location, length: 0))
        c.startRename()
        await settle()
        tv.insertText("2x", replacementRange: tv.selectedRange())
        let expected = "#show: worksheet\n$2\"\"x := 3$\n#graph($2\"\"x x$)"
        XCTAssertEqual(tv.string, expected)
        XCTAssertEqual(published, [expected], "publish the fully formatted preview once")
        tv.insertText("y", replacementRange: tv.selectedRange())
        XCTAssertTrue(tv.string.contains("$2\"\"\"xy\" :="), "typing continues after the join")
        c.cancelRename()
        XCTAssertEqual(tv.string, original)
        XCTAssertEqual(published.last, original)
    }

    func testSolvengPreviewSupportsUndoRedoAndCommit() async {
        let original = "#show: worksheet\n$\"foo\" := 3$\n#graph($\"foo\" x$)"
        let (tv, c, language) = setUp(original)
        language.source = { [weak tv] in tv?.string ?? "" }
        tv.setSelectedRange(NSRange(location: (original as NSString).range(of: "foo\" x").location, length: 0))
        c.startRename()
        await settle()
        tv.insertText("2x", replacementRange: tv.selectedRange())
        let expected = "#show: worksheet\n$2\"\"x := 3$\n#graph($2\"\"x x$)"
        XCTAssertEqual(tv.string, expected)
        XCTAssertTrue(c.undoRename())
        XCTAssertEqual(tv.string, original)
        XCTAssertTrue(c.redoRename())
        XCTAssertEqual(tv.string, expected)
        tv.insertText("y", replacementRange: tv.selectedRange())
        let continued = "#show: worksheet\n$2\"\"\"xy\" := 3$\n#graph($2\"\"\"xy\" x$)"
        XCTAssertEqual(tv.string, continued)
        c.commitRename()
        await settle()
        XCTAssertEqual(tv.string, continued)
    }

    func testInvalidSolvengRenameFailsWithoutChangingTheDocument() async {
        let original = "#show: worksheet\n$\"foo\" := 3$\n#graph($\"foo\" x$)"
        for invalid in ["^", "a+b", "2 bad-name", "a\\b"] {
            let (tv, c, language) = setUp(original)
            language.source = { [weak tv] in tv?.string ?? "" }
            tv.setSelectedRange(NSRange(location: (original as NSString).range(of: "foo\" x").location, length: 0))
            c.startRename()
            await settle()
            tv.insertText(invalid, replacementRange: tv.selectedRange())
            c.commitRename()
            await settle()
            XCTAssertEqual(tv.string, original, invalid)
        }
    }

    /// Renames the name at `needle` (its `occurrence`th match) to `name` and returns the shown text before committing.
    private func renameImported(_ original: String, at needle: String, occurrence: Int = 0, to name: String,
                                commit: Bool = true) async -> (live: String, done: String) {
        let (tv, c, language) = setUp(original)
        language.source = { [weak tv] in tv?.string ?? "" }
        var range = NSRange(location: 0, length: 0)
        for _ in 0...occurrence {
            let from = NSMaxRange(range)
            range = (original as NSString).range(of: needle, range: NSRange(location: from, length: (original as NSString).length - from))
        }
        tv.setSelectedRange(NSRange(location: range.location, length: 0))
        c.startRename()
        await settle()
        tv.insertText(name, replacementRange: tv.selectedRange())
        let live = tv.string
        if commit { c.commitRename() } else { c.cancelRename() }
        await settle()
        return (live, tv.string)
    }

    private let header = "#import \"@preview/solveng:1.0.0\": *\n"

    func testRenamingAnImportedNameAtAUseAliasesItRightAway() async {
        let result = await renameImported(header + "#import constants: pi\n#show: worksheet\n$x := 2 pi$", at: "pi$", to: "tau")
        let expected = header + "#import constants: pi as tau\n#show: worksheet\n$x := 2 tau$"
        XCTAssertEqual(result.live, expected)
        XCTAssertEqual(result.done, expected)
    }

    func testRenamingAtTheImportWritesTheAliasWhenDone() async {
        let result = await renameImported(header + "#import constants: pi\n#show: worksheet\n$x := 2 pi$", at: "pi\n", to: "tau")
        XCTAssertEqual(result.live, header + "#import constants: tau\n#show: worksheet\n$x := 2 tau$")
        XCTAssertEqual(result.done, header + "#import constants: pi as tau\n#show: worksheet\n$x := 2 tau$")
    }

    func testRenamingBackToTheModuleNameDropsTheAlias() async {
        let original = header + "#import constants: pi as tau\n#show: worksheet\n$x := 2 tau$"
        let fromUse = await renameImported(original, at: "tau$", to: "pi")
        let expected = header + "#import constants: pi\n#show: worksheet\n$x := 2 pi$"
        XCTAssertEqual(fromUse.live, expected, "a use drops the alias right away")
        XCTAssertEqual(fromUse.done, expected)
        let atImport = await renameImported(original, at: "tau\n", to: "pi")
        XCTAssertEqual(atImport.live, header + "#import constants: pi as pi\n#show: worksheet\n$x := 2 pi$")
        XCTAssertEqual(atImport.done, expected, "the import drops it once done")
    }

    func testRenamingAWildcardImportedNameAddsAnAliasImport() async {
        let original = header + "#import constants: *\n#show: worksheet\n$x := 2 pi + pi$"
        let expected = header + "#import constants: *\n#import constants: pi as tau\n#show: worksheet\n$x := 2 tau + tau$"
        let result = await renameImported(original, at: "pi", to: "tau")
        XCTAssertEqual(result.live, expected)
        XCTAssertEqual(result.done, expected)
        let cancelled = await renameImported(original, at: "pi", to: "tau", commit: false)
        XCTAssertEqual(cancelled.done, original)
    }
}
