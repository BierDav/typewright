import AppKit
import XCTest
@testable import Typewright

/// Vim commands on a text view; `|` marks the caret in the expected text.
@MainActor
final class VimTests: XCTestCase {
    private var window: NSWindow!
    private var tv: TypstTextView!
    private var vim: VimEngine!

    private func editor(_ text: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.allowsUndo = true
        window.contentView = tv
        window.makeFirstResponder(tv)
        let caret = (text as NSString).range(of: "|").location
        tv.string = text.replacingOccurrences(of: "|", with: "")
        tv.setSelectedRange(NSRange(location: caret == NSNotFound ? 0 : caret, length: 0))
        tv.undoManager?.groupsByEvent = false
        tv.undoManager?.removeAllActions()
        vim = VimEngine(textView: tv)
        vim.pasteboard = nil
        tv.vim = vim
    }

    /// Each call is one user event for the undo manager.
    private func keys(_ keys: String) {
        tv.undoManager?.beginUndoGrouping()
        vim.handle(keys: keys)
        tv.undoManager?.endUndoGrouping()
    }

    private func assertText(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let s = NSMutableString(string: tv.string)
        s.insert("|", at: tv.selectedRange().location)
        XCTAssertEqual(s as String, expected, file: file, line: line)
    }

    private var selected: String { (tv.string as NSString).substring(with: tv.selectedRange()) }

    func testMotions() {
        editor("|foo bar.baz\n  qux")
        keys("w"); assertText("foo |bar.baz\n  qux")
        keys("w"); assertText("foo bar|.baz\n  qux")
        keys("W"); assertText("foo bar.baz\n  |qux")
        keys("b"); assertText("foo bar.|baz\n  qux")
        keys("B"); assertText("foo |bar.baz\n  qux")
        keys("e"); assertText("foo ba|r.baz\n  qux")
        keys("$"); assertText("foo bar.ba|z\n  qux")
        keys("0"); assertText("|foo bar.baz\n  qux")
        keys("j^"); assertText("foo bar.baz\n  |qux")
        keys("gg"); assertText("|foo bar.baz\n  qux")
        keys("G"); assertText("foo bar.baz\n  |qux")
        keys("k2l"); assertText("foo |bar.baz\n  qux")
    }

    func testVerticalMovesKeepColumn() {
        editor("abcdef\nab\nabcdef")
        keys("5lj"); assertText("abcdef\na|b\nabcdef")
        keys("j"); assertText("abcdef\nab\nabcde|f")
    }

    func testFindCharAndRepeat() {
        editor("|a,b,c,d")
        keys("f,"); assertText("a|,b,c,d")
        keys(";"); assertText("a,b|,c,d")
        keys(","); assertText("a|,b,c,d")
        keys("0t,"); assertText("|a,b,c,d")
        keys("2f,"); assertText("a,b|,c,d")
        keys("F,"); assertText("a|,b,c,d")
    }

    func testParagraphAndPercent() {
        editor("|a\nb\n\nc\n")
        keys("}"); assertText("a\nb\n|\nc\n")
        keys("{"); assertText("|a\nb\n\nc\n")
        editor("f|(x, [1, 2])")
        keys("%"); assertText("f(x, [1, 2]|)")
        keys("%"); assertText("f|(x, [1, 2])")
    }

    func testDeleteWordsAndLines() {
        editor("|foo bar baz\nnext")
        keys("dw"); assertText("|bar baz\nnext")
        keys("d2w"); assertText("|\nnext")
        editor("one\n|two\nthree\nfour")
        keys("dd"); assertText("one\n|three\nfour")
        keys("2dd"); assertText("|one")
        editor("a\n|b")
        keys("dd"); assertText("|a")
    }

    func testDeleteToEndAndChars() {
        editor("foo |bar baz")
        keys("D"); assertText("foo| ")
        editor("|abc")
        keys("x"); assertText("|bc")
        keys("$X"); assertText("|c")
        editor("ab|c")
        keys("x"); assertText("a|b")
    }

    func testChangeEntersInsertAndEscMovesLeft() {
        editor("|foo bar")
        keys("cwbaz<Esc>")
        assertText("ba|z bar")
        XCTAssertEqual(vim.mode, .normal)
        keys("w.")
        assertText("baz ba|z")
        editor("  |foo\nbar")
        keys("ccx<Esc>")
        assertText("  |x\nbar")
        editor("a|bc")
        keys("Cz<Esc>")
        assertText("a|z")
    }

    func testInsertCommands() {
        editor("  fo|o")
        keys("Ix<Esc>"); assertText("  |xfoo")
        keys("Ay<Esc>"); assertText("  xfoo|y")
        keys("oz<Esc>"); assertText("  xfooy\n  |z")
        keys("Ow<Esc>"); assertText("  xfooy\n  |w\n  z")
        keys("az<Esc>"); assertText("  xfooy\n  w|z\n  z")
    }

    func testYankAndPut() {
        editor("|one\ntwo")
        keys("yyp"); assertText("one\n|one\ntwo")
        keys("jP"); assertText("one\none\n|one\ntwo")
        editor("|foo bar")
        keys("ywP"); assertText("foo| foo bar")
        keys("$p"); assertText("foo foo barfoo| ")
        editor("|one\ntwo")
        keys("ddp"); assertText("two\n|one")
    }

    func testCountsMultiply() {
        editor("|a b c d e f g")
        keys("2d2w"); assertText("|e f g")
    }

    func testTextObjects() {
        editor("let x = \"he|llo world\"")
        keys("ci\"hi<Esc>"); assertText("let x = \"h|i\"")
        editor("f(a, (b|, c))")
        keys("di("); assertText("f(a, (|))")
        editor("f(a, (b|, c))")
        keys("da("); assertText("f(a, |)")
        editor("foo ba|r baz")
        keys("daw"); assertText("foo |baz")
        editor("foo ba|r baz")
        keys("yiwP"); assertText("foo ba|rbar baz")
        editor("#f[x|y]")
        keys("ci[z<Esc>"); assertText("#f[|z]")
        editor("{\n  fo|o\n}")
        keys("di{"); assertText("{\n|\n}")
    }

    func testVisualModes() {
        editor("|foo bar baz")
        keys("vlll")
        XCTAssertEqual(vim.mode, .visual)
        XCTAssertEqual(selected, "foo ")
        keys("d"); assertText("|bar baz")
        XCTAssertEqual(vim.mode, .normal)
        editor("a\n|b\nc\nd")
        keys("Vjd"); assertText("a\n|d")
        editor("foo (ba|r) baz")
        keys("vi(")
        XCTAssertEqual(selected, "bar")
        keys("U"); assertText("foo (|BAR) baz")
        editor("|one\ntwo")
        keys("Vy")
        XCTAssertEqual(vim.mode, .normal)
        keys("jp"); assertText("one\ntwo\n|one")
    }

    func testJoinIndentReplaceAndCase() {
        editor("|foo\n   bar\nbaz")
        keys("J"); assertText("foo| bar\nbaz")
        keys("3J"); assertText("foo bar| baz")
        editor("|a\nb")
        keys(">>"); assertText("  |a\nb")
        keys(">j"); assertText("    |a\n  b")
        keys("<<"); assertText("  |a\n  b")
        editor("|abc")
        keys("rx"); assertText("|xbc")
        keys("2~"); assertText("XB|c")
    }

    func testUndoAndRedo() {
        editor("|foo bar")
        keys("dw")
        keys("dw")
        XCTAssertEqual(tv.string, "")
        // Undo closes the open group itself, so it runs outside one.
        vim.handle(keys: "u")
        XCTAssertEqual(tv.string, "bar")
        vim.handle(keys: "u")
        XCTAssertEqual(tv.string, "foo bar")
        vim.handle(keys: "<C-r>")
        XCTAssertEqual(tv.string, "bar")
    }

    func testRepeatWithCount() {
        editor("|a b c d e")
        keys("dw"); assertText("|b c d e")
        keys("2."); assertText("|d e")
    }

    func testModeReporting() {
        editor("|foo")
        var modes: [String?] = []
        vim.onModeChange = { modes.append($0) }
        keys("d2")
        XCTAssertEqual(modes.last, "NORMAL d2")
        keys("<Esc>i")
        XCTAssertEqual(modes.last, "INSERT")
        keys("<Esc>V")
        XCTAssertEqual(modes.last, "VISUAL LINE")
        XCTAssertFalse(vim.blockCaret)
        keys("<Esc>")
        XCTAssertTrue(vim.blockCaret)
    }

    func testKeyEventsPassThroughInInsertMode() {
        editor("|foo")
        func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                             keyCode: code)!
        }
        XCTAssertTrue(vim.handle(key("l", code: 37)))
        assertText("f|oo")
        XCTAssertFalse(vim.handle(key("c", code: 8, flags: .command)))
        XCTAssertTrue(vim.handle(key("i", code: 34)))
        XCTAssertFalse(vim.handle(key("x", code: 7)))
        XCTAssertTrue(vim.handle(key("\u{1b}", code: 53)))
        XCTAssertEqual(vim.mode, .normal)
    }
}
