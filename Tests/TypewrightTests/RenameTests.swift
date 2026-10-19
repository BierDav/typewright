import AppKit
import XCTest
@testable import Typewright

@MainActor
private final class FakeLanguage: EditorLanguage {
    var renamedTo: String?
    func completions(at offset: Int) async -> [CompletionItem] { [] }
    func goToDefinition(at offset: Int) async -> [SymbolUsage] { [] }
    func open(_ location: SourceLocation) {}
    func hover(at offset: Int) async -> (markdown: String, range: NSRange?)? { nil }
    func occurrences(at offset: Int) async -> [NSRange] {
        [NSRange(location: 5, length: 5), NSRange(location: 16, length: 5), NSRange(location: 27, length: 5)]
    }
    func formattingEdits() async -> [TextEdit] { [] }
    func renameTarget(at offset: Int) async -> (range: NSRange, name: String)? { (NSRange(location: 16, length: 5), "greet") }
    func rename(at offset: Int, to name: String) async -> [TextEdit] {
        renamedTo = name
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
}
