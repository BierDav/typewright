import AppKit
import XCTest
@testable import Typewright

@MainActor
final class ColumnSelectionTests: XCTestCase {
    private var window: NSWindow!

    private func editor(_ text: String) -> TypstTextView {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.allowsUndo = true
        window.contentView = tv
        window.makeFirstResponder(tv)
        tv.string = text
        window.undoManager?.groupsByEvent = false
        window.undoManager?.removeAllActions()
        return tv
    }

    private func carets(_ tv: TypstTextView) -> [NSRange] { tv.columnCarets.map(\.range) }

    /// One user event, which the run loop would group for undo.
    private func event(_ body: () -> Void) {
        window.undoManager?.beginUndoGrouping()
        body()
        window.undoManager?.endUndoGrouping()
    }

    func testTypesDeletesAndUndoesInEveryLine() {
        let tv = editor("ab\ncd\nef")
        tv.setColumns([.init(1), .init(4), .init(7)], primary: 2)
        XCTAssertTrue(tv.isColumnMode)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 7, length: 0), "the primary caret is the selection")
        event { tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertEqual(tv.string, "aXb\ncXd\neXf")
        XCTAssertEqual(carets(tv), [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0), NSRange(location: 10, length: 0)])
        for _ in 0..<3 { event { tv.doCommand(by: #selector(NSResponder.deleteBackward(_:))) } }
        XCTAssertEqual(tv.string, "b\nd\nf", "deleting stops at the line start")
        tv.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
        event { tv.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertEqual(tv.string, "b!\nd!\nf!")
        for _ in 0..<5 { window.undoManager?.undo() }
        XCTAssertEqual(tv.string, "ab\ncd\nef")
        XCTAssertFalse(tv.isColumnMode, "undo selects natively, which ends the columns")
    }

    func testSelectsColumnsAndCopiesThemAsLines() {
        let tv = editor("alpha\nb\ngamma")
        tv.setColumns([.init(1)], primary: 0)
        tv.addCaret(up: false)
        tv.addCaret(up: false)
        XCTAssertEqual(carets(tv), [NSRange(location: 1, length: 0), NSRange(location: 7, length: 0), NSRange(location: 9, length: 0)],
                       "the short line gets its end")
        tv.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        tv.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        XCTAssertEqual(carets(tv), [NSRange(location: 1, length: 2), NSRange(location: 7, length: 2), NSRange(location: 9, length: 2)])
        tv.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "lp\n\ng\nam")
        tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(tv.isColumnMode)
    }

    func testPastesALineIntoEachCaret() {
        let tv = editor("a\nb")
        tv.setColumns([.init(1), .init(3)], primary: 1)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("1\n2", forType: .string)
        event { tv.paste(nil) }
        XCTAssertEqual(tv.string, "a1\nb2")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(tv.isColumnMode, "a click or any other selection ends the columns")
    }

    func testDraggingSpansTheLinesBetween() {
        let tv = editor("abcd\nb\nefgh")
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let lm = tv.layoutManager!
        func point(_ index: Int) -> NSPoint {
            let box = lm.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: tv.textContainer!)
            return NSPoint(x: box.minX + tv.textContainerOrigin.x, y: box.midY + tv.textContainerOrigin.y)
        }
        let found = tv.columnCarets(from: point(1), to: point(10))
        XCTAssertEqual(found.carets.map(\.range), [NSRange(location: 1, length: 2), NSRange(location: 6, length: 0),
                                                   NSRange(location: 8, length: 2)], "the short line gets a caret at its end")
        XCTAssertEqual(found.primary, 2)
    }

    func testExtendsAndShrinksTheColumn() {
        let tv = editor("ab\ncd\nef")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.columnSelectionMode = true
        tv.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        tv.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        XCTAssertEqual(carets(tv).map(\.location), [1, 4, 7])
        tv.doCommand(by: #selector(NSResponder.moveUpAndModifySelection(_:)))
        XCTAssertEqual(carets(tv).map(\.location), [1, 4])
    }
}
