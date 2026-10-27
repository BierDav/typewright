import AppKit
import XCTest
@testable import Typewright

/// Every edit the editor makes must be one step back with ⌘Z.
@MainActor
final class UndoTests: XCTestCase {
    private var window: NSWindow!
    private var coordinator: CodeEditor.Coordinator!
    /// The text's own, apart from the window's (file tree changes).
    private var undo: UndoManager { coordinator.textUndo }

    private func setUp(_ text: String) -> (TypstTextView, CodeEditor.Coordinator) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.allowsUndo = true
        window.contentView = tv
        window.makeFirstResponder(tv)
        tv.string = text
        let c = CodeEditor.Coordinator()
        coordinator = c
        c.textView = tv
        tv.delegate = c
        XCTAssert(tv.undoManager === c.textUndo)
        XCTAssert(window.undoManager !== c.textUndo)
        undo.groupsByEvent = false
        undo.removeAllActions()
        return (tv, c)
    }

    /// One user event: the undo manager groups what it registers, and like the run loop it can't close the
    /// group while registration is off.
    private func event(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    private func select(_ tv: NSTextView, _ needle: String) {
        tv.setSelectedRange((tv.string as NSString).range(of: needle))
    }

    /// ⌘Z; simulated events leave empty groups behind, which the run loop never makes, so those are skipped.
    private func stepBack(_ tv: NSTextView) {
        let before = tv.string
        repeat { undo.undo() } while tv.string == before && undo.canUndo
    }

    func testExtractVariableThenRenameUndoesStepByStep() {
        let text = "#box(width: 15mm)"
        let (tv, c) = setUp(text)
        select(tv, "15mm")
        event { c.extractVariable() }
        XCTAssertEqual(tv.string, "#let width = 15mm\n#box(width: width)")
        event { tv.insertText("w", replacementRange: tv.selectedRange()) }
        event { _ = c.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))) }
        XCTAssertEqual(tv.string, "#let w = 15mm\n#box(width: w)")
        stepBack(tv)
        XCTAssertEqual(tv.string, "#let width = 15mm\n#box(width: width)")
        stepBack(tv)
        XCTAssertEqual(tv.string, text)
        undo.redo()
        XCTAssertEqual(tv.string, "#let width = 15mm\n#box(width: width)")
    }

    func testExtractKeptAsIsUndoesInOneStep() {
        let text = "#box(width: 15mm)"
        let (tv, c) = setUp(text)
        select(tv, "15mm")
        event { c.extractVariable() }
        event { _ = c.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))) }
        stepBack(tv)
        XCTAssertEqual(tv.string, text)
    }

    func testInlineVariableUndoes() {
        let text = "#let w = 15mm\n#box(width: w)"
        let (tv, c) = setUp(text)
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        event { c.inlineVariable() }
        XCTAssertEqual(tv.string, "#box(width: 15mm)")
        stepBack(tv)
        XCTAssertEqual(tv.string, text)
    }

    func testLineCommandsUndoSeparately() {
        let (tv, _) = setUp("a\nb")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        event { tv.duplicateLine() }
        event { tv.deleteLine() }
        XCTAssertEqual(tv.string, "a\nb")
        stepBack(tv)
        XCTAssertEqual(tv.string, "a\na\nb")
        stepBack(tv)
        XCTAssertEqual(tv.string, "a\nb")
    }

    func testTypingBeforeExtractStaysSeparate() {
        let text = "#box(width: 15mm)"
        let (tv, c) = setUp(text)
        tv.setSelectedRange(NSRange(location: 17, length: 0))
        event { tv.insertText(" x", replacementRange: tv.selectedRange()) }
        select(tv, "15mm")
        event { c.extractVariable() }
        event { _ = c.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))) }
        stepBack(tv)
        XCTAssertEqual(tv.string, text + " x")
    }
    func testExtractFunctionUndoes() {
        let text = "#let n = 2\n#box(width: n * 1cm)"
        let (tv, c) = setUp(text)
        select(tv, "n * 1cm")
        event { c.extractFunction(toScope: false) }
        XCTAssertEqual(tv.string, "#let n = 2\n#let extracted() = n * 1cm\n#box(width: extracted())")
        event { tv.insertText("size", replacementRange: tv.selectedRange()) }
        event { _ = c.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))) }
        XCTAssertEqual(tv.string, "#let n = 2\n#let size() = n * 1cm\n#box(width: size())")
        stepBack(tv)
        stepBack(tv)
        XCTAssertEqual(tv.string, text)
    }
    func testEditorCommandsRedoRepeatedly() {
        let cases: [(String, (TypstTextView, CodeEditor.Coordinator) -> Void)] = [
            ("a\nb", { tv, _ in tv.duplicateLine() }),
            ("a\nb", { tv, _ in tv.deleteLine() }),
            ("#let w = 15mm\n#box(width: w)", { tv, c in
                tv.setSelectedRange(NSRange(location: 6, length: 0))
                c.inlineVariable()
            })
        ]
        for (original, edit) in cases {
            let (tv, c) = setUp(original)
            event { edit(tv, c) }
            let changed = tv.string
            XCTAssertNotEqual(changed, original)
            for _ in 0..<3 {
                stepBack(tv)
                XCTAssertEqual(tv.string, original)
                XCTAssertTrue(undo.canRedo)
                undo.redo()
                XCTAssertEqual(tv.string, changed)
            }
        }
    }

    func testJournalTracksNativeTextUndoAndRedo() {
        let (tv, c) = setUp("a\nb")
        event { tv.duplicateLine() }
        XCTAssertEqual(c.textUndo.journal.undo.count, 1)
        XCTAssertEqual(c.textUndo.journal.undo.last?.before, "a\nb")
        XCTAssertEqual(c.textUndo.journal.undo.last?.after, "a\nb\nb")
        stepBack(tv)
        XCTAssertEqual(c.textUndo.journal.redo.count, 1)
        undo.redo()
        XCTAssertEqual(c.textUndo.journal.undo.count, 1)
        XCTAssertTrue(c.textUndo.journal.redo.isEmpty)
    }

    func testNewEditAfterUndoClearsRedoJournal() {
        let (tv, c) = setUp("a\nb")
        event { tv.duplicateLine() }
        stepBack(tv)
        event { tv.insertText("x", replacementRange: NSRange(location: 0, length: 0)) }
        XCTAssertFalse(undo.canRedo)
        XCTAssertTrue(c.textUndo.journal.redo.isEmpty)
    }

    func testCommittedRenameRedoesEveryStep() {
        let (tv, c) = setUp("#box(width: 15mm)")
        select(tv, "15mm")
        event { c.extractVariable() }
        let extracted = tv.string
        event { tv.insertText("w", replacementRange: tv.selectedRange()) }
        c.textUndo.checkpoint()
        event { _ = c.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))) }
        let renamed = tv.string
        stepBack(tv)
        stepBack(tv)
        undo.redo()
        XCTAssertEqual(tv.string, extracted)
        undo.redo()
        XCTAssertEqual(tv.string, renamed)
    }

    func testTypingJournalMatchesNativeUndo() {
        let (tv, c) = setUp("")
        undo.groupsByEvent = true
        tv.insertText("a", replacementRange: tv.selectedRange())
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        tv.insertText("b", replacementRange: tv.selectedRange())
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        c.textUndo.checkpoint()
        let preview = c.textUndo.journal.undo.last?.before
        stepBack(tv)
        XCTAssertEqual(tv.string, preview)
        XCTAssertEqual(c.textUndo.journal.redo.last?.after, "ab")
        XCTAssertEqual(c.textUndo.journal.undo.isEmpty, !undo.canUndo)
        undo.redo()
        XCTAssertEqual(tv.string, "ab")
    }

}
