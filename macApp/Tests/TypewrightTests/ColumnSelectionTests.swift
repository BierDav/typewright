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
        let storage = NSTextStorage(), layout = EditorLayoutManager()
        storage.addLayoutManager(layout)
        let container = EditorTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
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

    func testCopyWithoutSelectionSelectsAndCopiesWholeRowsOnce() {
        let tv = editor("abc\ndef\nlast")
        tv.setColumns([.init(1), .init(2), .init(10)], primary: 2)
        tv.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "abc\nlast\n")
        XCTAssertEqual(carets(tv), [NSRange(location: 0, length: 4), NSRange(location: 8, length: 4)])
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "def\n")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 4))
        XCTAssertTrue(tv.validateMenuItem(NSMenuItem(title: "Copy", action: #selector(NSTextView.copy(_:)), keyEquivalent: "c")))
    }

    func testCutWithoutSelectionRemovesRowsAndUndoesAsOneEdit() {
        let tv = editor("abc\nx\ndef\nz")
        tv.setColumns([.init(1), .init(2), .init(8)], primary: 2)
        event { tv.cut(nil) }
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "abc\ndef\n")
        XCTAssertEqual(tv.string, "x\nz")
        XCTAssertEqual(carets(tv).map(\.location), [1, 3])
        window.undoManager?.undo()
        XCTAssertEqual(tv.string, "abc\nx\ndef\nz")
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        event { tv.cut(nil) }
        XCTAssertEqual(tv.string, "abc\nx\ndef")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "z\n")
    }

    func testMovesAllCursorRowsTogetherAndPreservesSelections() {
        let tv = editor("a\nbb\nccc\nd\ne")
        tv.setColumns([.init(3), .init(anchor: 7, head: 5), .init(12)], primary: 1)
        let original = tv.columnCarets
        event { tv.moveLines(up: true) }
        XCTAssertEqual(tv.string, "bb\nccc\na\ne\nd")
        XCTAssertEqual(tv.columnCarets, [.init(1), .init(anchor: 5, head: 3), .init(10)])
        XCTAssertEqual(tv.primaryColumn, 1)
        event { tv.moveLines(up: false) }
        XCTAssertEqual(tv.string, "a\nbb\nccc\nd\ne")
        XCTAssertEqual(tv.columnCarets, original)
        window.undoManager?.undo()
        XCTAssertEqual(tv.string, "bb\nccc\na\ne\nd")
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

    func testDraggingLeftAndUpIncludesShortLinesInsideRectangle() {
        let tv = editor("ab\na\nabcdef")
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let x = tv.textContainerOrigin.x + tv.textContainer!.lineFragmentPadding
        let start = point(tv, at: 8, x: x + 4 * tv.columnWidth)
        let end = point(tv, at: 0, x: x + tv.columnWidth)
        let found = tv.columnCarets(from: start, to: end)
        XCTAssertEqual(found.carets, [.init(anchor: 2, head: 1), .init(anchor: 9, head: 6)])
        XCTAssertEqual(found.primary, 0)
        let reverse = tv.columnCarets(from: end, to: start)
        XCTAssertEqual(reverse.carets, [.init(anchor: 1, head: 2), .init(anchor: 6, head: 9)])
        XCTAssertEqual(reverse.primary, 1)
    }

    func testDraggingFromFirstSliceSkipsSoftWraps() {
        let text = String(repeating: "a", count: 55) + "\n" + String(repeating: "b", count: 55) + "\nshort"
        let tv = editor(text)
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.wrapColumn = 20
        let x = tv.textContainerOrigin.x + tv.textContainer!.lineFragmentPadding
        let start = point(tv, at: 1, x: x + tv.columnWidth)
        let end = point(tv, at: 113, x: x + 3 * tv.columnWidth)
        let found = tv.columnCarets(from: start, to: end)
        XCTAssertEqual(found.carets, [.init(anchor: 1, head: 3), .init(anchor: 57, head: 59), .init(anchor: 113, head: 115)])
        XCTAssertEqual(found.primary, 2)
        let reverse = tv.columnCarets(from: end, to: start)
        XCTAssertEqual(reverse.carets, [.init(anchor: 3, head: 1), .init(anchor: 59, head: 57), .init(anchor: 115, head: 113)])
        XCTAssertEqual(reverse.primary, 0)
        let continuation = point(tv, at: 30, x: end.x)
        let withinLine = tv.columnCarets(from: start, to: continuation)
        XCTAssertEqual(withinLine.carets, [.init(anchor: 1, head: 3)])
    }

    func testDraggingFromSoftWrapKeepsStartingColumnAndSelectsLeft() {
        let text = String(repeating: "a", count: 55) + "\n" + String(repeating: "b", count: 55) + "\nshort"
        let tv = editor(text)
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.wrapColumn = 20
        let x = tv.textContainerOrigin.x + tv.textContainer!.lineFragmentPadding
        let start = insertionPoint(tv, at: 30)
        let end = point(tv, at: 113, x: x + 3 * tv.columnWidth)
        XCTAssertEqual(tv.columnCarets(from: start, to: start).carets, [.init(30)])
        let found = tv.columnCarets(from: start, to: end)
        XCTAssertEqual(found.carets, [.init(anchor: 30, head: 3), .init(anchor: 86, head: 59), .init(anchor: 117, head: 115)])
        XCTAssertEqual(found.primary, 2)
        let reverse = tv.columnCarets(from: insertionPoint(tv, at: 86), to: point(tv, at: 30, x: end.x))
        XCTAssertEqual(reverse.carets, [.init(anchor: 30, head: 3), .init(anchor: 86, head: 59)])
        XCTAssertEqual(reverse.primary, 0)
        let withinLine = tv.columnCarets(from: start, to: point(tv, at: 50, x: end.x))
        XCTAssertEqual(withinLine.carets, [.init(anchor: 30, head: 3)])
        let rightward = tv.columnCarets(from: start, to: point(tv, at: 85, x: start.x + 2 * tv.columnWidth))
        XCTAssertTrue(rightward.carets.allSatisfy { $0.head <= $0.anchor })
        XCTAssertEqual(rightward.carets.map(\.anchor), [30, 86])
    }

    func testWrappedDragSkipsEmptyAndShortLinesWhenRectangleFindsText() {
        let tv = editor("\nabc\nabcdefghij\n" + String(repeating: "x", count: 55))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.wrapColumn = 20
        let start = insertionPoint(tv, at: 46)
        let x = tv.textContainerOrigin.x + tv.textContainer!.lineFragmentPadding
        let end = point(tv, at: 0, x: x + 6 * tv.columnWidth)
        let found = tv.columnCarets(from: start, to: end)
        XCTAssertEqual(found.carets, [.init(anchor: 15, head: 11), .init(anchor: 46, head: 22)])
        XCTAssertEqual(found.primary, 0)
    }

    func testPastEndDragSkipsEmptyLinesWhenOtherRowsHavePositions() {
        let tv = editor("\nabcdefghij\nabc")
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let x = tv.textContainerOrigin.x + tv.textContainer!.lineFragmentPadding
        let start = point(tv, at: 13, x: x + 8 * tv.columnWidth)
        let found = tv.columnCarets(from: start, to: point(tv, at: 0, x: x + 6 * tv.columnWidth))
        XCTAssertEqual(found.carets, [.init(anchor: 9, head: 7)])
        XCTAssertEqual(found.primary, 0)
        let missed = tv.columnCarets(from: point(tv, at: 13, x: x + 12 * tv.columnWidth),
                                     to: point(tv, at: 0, x: x + 14 * tv.columnWidth))
        XCTAssertEqual(missed.carets, [.init(0), .init(11), .init(15)])
    }

    private func insertionPoint(_ tv: TypstTextView, at index: Int) -> NSPoint {
        let layout = tv.layoutManager!, container = tv.textContainer!
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: index)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSPoint(x: tv.textContainerOrigin.x + line.minX + layout.location(forGlyphAt: glyph).x,
                       y: tv.textContainerOrigin.y + line.midY)
    }

    /// One gesture: the tracker reads the drags the run loop posts while the mouse button is down.
    private func mouse(_ tv: TypstTextView, from start: NSPoint, to end: NSPoint,
                       modifiers: NSEvent.ModifierFlags = []) {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: tv.convert(point, to: nil), modifierFlags: modifiers,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        // Without a window on screen its number is 0 and the tracker never sees the posted drags.
        window.makeKeyAndOrderFront(nil)
        // A click carries no drag; one event per tracking-loop tick, as a slow runner may not have
        // consumed a whole queue by mouse-up.
        let drags = start != end
        var ticks = 0
        let timer = Timer(timeInterval: 0.025, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard modifiers != [.option, .shift] else { return timer.invalidate() }
                ticks += 1
                if ticks == 1, drags {
                    NSApp.postEvent(event(.leftMouseDragged, end), atStart: false)
                    return
                }
                NSApp.postEvent(event(.leftMouseUp, end), atStart: false)
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        tv.mouseDown(with: event(.leftMouseDown, start))
        // Drop what the tracker didn't take, so it can't leak into the next gesture.
        while NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) != nil {}
    }

    private func point(_ tv: TypstTextView, at index: Int, x: CGFloat) -> NSPoint {
        let lm = tv.layoutManager!, container = tv.textContainer!
        lm.ensureLayout(for: container)
        let glyph = lm.glyphIndexForCharacter(at: index)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSPoint(x: x, y: line.midY + tv.textContainerOrigin.y)
    }

    func testOptionShiftClickTogglesIndividualCarets() {
        let tv = editor("abc\ndef\nghi")
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        for index in [4, 8] {
            let p = point(tv, at: index, x: tv.textContainerOrigin.x + tv.textContainer!.lineFragmentPadding)
            mouse(tv, from: p, to: p, modifiers: [.option, .shift])
        }
        XCTAssertEqual(carets(tv).map(\.location), [0, 4, 8])
        let p = point(tv, at: 4, x: tv.textContainerOrigin.x + tv.textContainer!.lineFragmentPadding)
        mouse(tv, from: p, to: p, modifiers: [.option, .shift])
        XCTAssertEqual(carets(tv).map(\.location), [0, 8])
        let last = point(tv, at: 8, x: tv.textContainerOrigin.x + tv.textContainer!.lineFragmentPadding)
        mouse(tv, from: last, to: last, modifiers: [.option, .shift])
        XCTAssertFalse(tv.isColumnMode)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testMouseInteractionsBeyondWrapGuide() {
        _ = editor("")
        let storage = NSTextStorage(), layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = TypstTextView(frame: .zero, textContainer: container)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 6, height: 10)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = tv
        window.contentView = scroll
        tv.string = "ab\nabcdefgh\na\nabc"
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.wrapColumn = 20
        let start = point(tv, at: 0, x: 350)
        let end = point(tv, at: 14, x: 350)
        XCTAssertGreaterThan(start.x, tv.textContainerOrigin.x + tv.textContainer!.size.width)
        XCTAssertTrue(scroll.hitTest(scroll.convert(start, from: tv)) === tv)
        mouse(tv, from: start, to: start)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 0))
        mouse(tv, from: start, to: end)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 15))
        mouse(tv, from: start, to: end, modifiers: .option)
        XCTAssertEqual(carets(tv).map(\.location), [2, 11, 13, 17])
        mouse(tv, from: start, to: start, modifiers: [.option, .shift])
        XCTAssertEqual(carets(tv).map(\.location), [11, 13, 17])
        XCTAssertNil(scroll.hitTest(scroll.convert(NSPoint(x: 450, y: start.y), from: tv)))
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

    func testNormalAndColumnSelectionsDrawTheirOwnBackground() {
        let tv = editor("ab\ncd")
        tv.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertEqual(tv.selectedTextAttributes[.backgroundColor] as? NSColor, .clear)
        tv.setColumns([.init(anchor: 0, head: 1), .init(anchor: 3, head: 4)], primary: 1)
        XCTAssertEqual(tv.selectedTextAttributes[.backgroundColor] as? NSColor, .clear)
        tv.endColumns()
        XCTAssertEqual(tv.selectedTextAttributes[.backgroundColor] as? NSColor, .clear)
    }

    func testFullLineSelectionsStopAtTextAndKeepEmptyLinesVisible() {
        let tv = editor("abc\nabcdefgh\n\nx")
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.wrapColumn = 20
        let boxes = tv.selectionBoxes(for: NSRange(location: 0, length: 14))
        XCTAssertEqual(boxes.count, 3)
        XCTAssertLessThan(boxes[0].maxX, boxes[1].maxX)
        XCTAssertLessThan(boxes[1].maxX, tv.textContainer!.size.width / 2)
        XCTAssertEqual(boxes[2].width, tv.columnWidth, accuracy: 0.01)
        let partial = tv.selectionBoxes(for: NSRange(location: 0, length: 3))
        XCTAssertEqual(boxes[0].maxX, partial[0].maxX, accuracy: 0.01)
    }

    func testWrappedSelectionStaysJoinedAfterCollapsedSymbols() throws {
        for prefix in ["$Omega$ ", "$ a := b $ $Omega$ ", "$\"pytagoras\"(a)$ "] {
            let tv = editor(prefix + String(repeating: "abcdefgh ", count: 6))
            tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            tv.wrapColumn = 20
            Highlighter.apply(to: tv.textStorage!, font: tv.font!)
            tv.textStorage!.addAttribute(.font, value: NSFont.systemFont(ofSize: 20), range: NSRange(location: 0, length: prefix.utf16.count))
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.concealsMath = true
            let range = NSRange(location: prefix.utf16.count, length: (tv.string as NSString).length - prefix.utf16.count - 4)
            tv.setSelectedRange(range)
            let boxes = tv.selectionBoxes(for: range)
            XCTAssertGreaterThan(boxes.count, 1)
            for pair in zip(boxes, boxes.dropFirst()) {
                XCTAssertEqual(pair.0.maxY, pair.1.minY, accuracy: 0.01)
            }
            let path = tv.selectionPath(for: boxes)
            let outlines = (0..<path.elementCount).filter { path.element(at: $0) == .closePath }
            XCTAssertEqual(outlines.count, 1, "A selection across soft wraps must have one continuous outline: \(prefix) \(boxes)")
            window.close()
        }
    }

    func testInactiveSelectionDoesNotDrawAnAppKitBackground() throws {
        let tv = editor("abc\n\nx")
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = .white
        tv.setSelectedRange(NSRange(location: 0, length: 6))
        window.makeFirstResponder(nil)
        let bitmap = try XCTUnwrap(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
        tv.cacheDisplay(in: tv.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / tv.bounds.width
        for box in tv.selectionBoxes(for: tv.selectedRange()) {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(300 * scale), y: Int(box.midY * scale))?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, 1, accuracy: 0.01, "inactive selection must stop at the text")
            XCTAssertEqual(color.greenComponent, 1, accuracy: 0.01)
            XCTAssertEqual(color.blueComponent, 1, accuracy: 0.01)
        }
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
