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
        XCTAssertEqual(found.carets.map(\.range), [NSRange(location: 1, length: 2), NSRange(location: 8, length: 2)],
                       "the line too short for the column's start gets no caret")
        XCTAssertEqual(found.primary, 1)
    }

    func testDraggingFromPastTheLineEndPutsCaretsAtLineEnds() {
        let tv = editor("ab\nabcdefgh\na\nabc")
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let lm = tv.layoutManager!
        func point(_ index: Int, dx: CGFloat = 0) -> NSPoint {
            let box = lm.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: tv.textContainer!)
            return NSPoint(x: box.minX + tv.textContainerOrigin.x + dx, y: box.midY + tv.textContainerOrigin.y)
        }
        let start = NSPoint(x: point(1).x + 200, y: point(1).y)
        let end = NSPoint(x: start.x, y: point(14).y)
        let found = tv.columnCarets(from: start, to: end)
        XCTAssertEqual(found.carets.map(\.range), [NSRange(location: 2, length: 0), NSRange(location: 11, length: 0),
                                                   NSRange(location: 13, length: 0), NSRange(location: 17, length: 0)])
        let inside = tv.columnCarets(from: point(5), to: NSPoint(x: point(5).x, y: point(14).y))
        XCTAssertEqual(inside.carets.map(\.range), [NSRange(location: 5, length: 0), NSRange(location: 16, length: 0)],
                       "a column inside the text still skips short lines")
    }

    func testHomeAndEndMoveEveryCaret() {
        let tv = editor("ab\ncd")
        tv.setColumns([.init(1), .init(4)], primary: 1)
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(.function), timestamp: 0, windowNumber: 0,
                             context: nil, characters: String(UnicodeScalar(code)!), charactersIgnoringModifiers: String(UnicodeScalar(code)!),
                             isARepeat: false, keyCode: 0)!
        }
        tv.keyDown(with: key(NSEndFunctionKey))
        XCTAssertEqual(carets(tv).map(\.location), [2, 5])
        tv.keyDown(with: key(NSHomeFunctionKey, .shift))
        XCTAssertEqual(carets(tv), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        tv.keyDown(with: key(NSEndFunctionKey, .command))
        XCTAssertFalse(tv.isColumnMode)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 0))
        tv.keyDown(with: key(NSHomeFunctionKey))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testColumnsDrawTheirOwnBackground() {
        let tv = editor("ab\ncd")
        tv.setColumns([.init(anchor: 0, head: 1), .init(anchor: 3, head: 4)], primary: 1)
        XCTAssertEqual(tv.selectedTextAttributes[.backgroundColor] as? NSColor, .clear)
        tv.endColumns()
        XCTAssertEqual(tv.selectedTextAttributes[.backgroundColor] as? NSColor, tv.selectionColor)
    }

    func testColumnBackgroundRoundsOnlyItsOuterCorners() {
        let tv = editor("ab\ncd")
        let path = tv.selectionPath(for: [NSRect(x: 10, y: 10, width: 20, height: 15),
                                          NSRect(x: 10, y: 25, width: 20, height: 15)])
        XCTAssertTrue(path.contains(NSPoint(x: 20, y: 20)))
        XCTAssertTrue(path.contains(NSPoint(x: 10.5, y: 25)), "the lines join without a notch")
        XCTAssertFalse(path.contains(NSPoint(x: 10.5, y: 10.5)), "the outer corner is rounded")
        XCTAssertFalse(path.contains(NSPoint(x: 10.5, y: 11.5)), "the corner radius is wide")
    }

    func testColumnBackgroundRoundsInwardCornersOnEitherSide() {
        let tv = editor("ab\ncd")
        for boxes in [
            [NSRect(x: 10, y: 10, width: 40, height: 15), NSRect(x: 20, y: 25, width: 20, height: 15)],
            [NSRect(x: 20, y: 10, width: 20, height: 15), NSRect(x: 10, y: 25, width: 40, height: 15)],
        ] {
            let path = tv.selectionPath(for: boxes)
            let narrowBelow = boxes[1].width < boxes[0].width
            let y: CGFloat = narrowBelow ? 25.5 : 24.5
            XCTAssertTrue(path.contains(NSPoint(x: 19.5, y: y)), "the inward left corner curves outward")
            XCTAssertTrue(path.contains(NSPoint(x: 40.5, y: y)), "the inward right corner curves outward")
            XCTAssertFalse(path.contains(NSPoint(x: 15, y: narrowBelow ? 30 : 20)))
            XCTAssertTrue(path.contains(NSPoint(x: 30, y: 25)), "the join stays filled")
        }
    }

    func testColumnBackgroundKeepsSeparateSelectionsApart() {
        let tv = editor("ab\ncd")
        let path = tv.selectionPath(for: [NSRect(x: 10, y: 10, width: 20, height: 15),
                                          NSRect(x: 40, y: 25, width: 20, height: 15)])
        XCTAssertTrue(path.contains(NSPoint(x: 20, y: 20)))
        XCTAssertTrue(path.contains(NSPoint(x: 50, y: 30)))
        XCTAssertFalse(path.contains(NSPoint(x: 35, y: 25)))
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
