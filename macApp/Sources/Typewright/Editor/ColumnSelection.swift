import AppKit
import TypewrightCore

final class EditorLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        // AppKit ignores selectedTextAttributes for inactive selections.
        guard color != .unemphasizedSelectedTextBackgroundColor,
              color != .unemphasizedSelectedContentBackgroundColor else { return }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }
}

/// Several carets or selections edited at once: ⌥-drag selects a column, ⌥⇧-click toggles a caret, ⌃⇧↑ and ⌃⇧↓ add
/// one on the line above or below, like Xcode. In column selection mode (⇧⌘8, like IntelliJ) a plain drag selects a
/// column and ⇧↑ and ⇧↓ add lines to it. A column started past the end of its line puts carets at the end of shorter lines.
extension TypstTextView {
    /// A selection that grows from `anchor` towards `head`, where its caret is.
    struct ColumnCaret: Equatable {
        var anchor: Int
        var head: Int

        init(anchor: Int, head: Int) {
            self.anchor = anchor
            self.head = head
        }

        init(_ caret: Int) { self.init(anchor: caret, head: caret) }

        var range: NSRange { NSRange(location: min(anchor, head), length: abs(head - anchor)) }
    }

    var isColumnMode: Bool { columnCarets.count > 1 }

    /// Sets the carets, merging overlapping ones; with only one left it's the text view's own selection again.
    func setColumns(_ carets: [ColumnCaret], primary: Int) {
        guard !carets.isEmpty else { return endColumns() }
        let primaryHead = carets[min(max(primary, 0), carets.count - 1)].head
        var merged: [ColumnCaret] = []
        for caret in carets.sorted(by: { $0.range.location < $1.range.location }) {
            if let last = merged.last, caret.range.location < NSMaxRange(last.range) || caret.range == last.range {
                let range = NSUnionRange(last.range, caret.range)
                let forward = caret.head >= caret.anchor
                merged[merged.count - 1] = forward ? ColumnCaret(anchor: range.location, head: NSMaxRange(range))
                    : ColumnCaret(anchor: NSMaxRange(range), head: range.location)
            } else {
                merged.append(caret)
            }
        }
        let main = merged.firstIndex { NSLocationInRange(primaryHead, $0.range) || NSMaxRange($0.range) == primaryHead } ?? merged.count - 1
        guard merged.count > 1 else {
            columnCarets = []
            return setSelectedRange(merged[0].range)
        }
        isUpdatingColumns = true
        columnCarets = merged
        primaryColumn = main
        setSelectedRange(merged[main].range)
        isUpdatingColumns = false
        updateRevealedEquation()
        refreshCaret(animated: true)
        scrollRangeToVisible(NSRange(location: merged[main].head, length: 0))
    }

    /// Back to the text view's own selection, the primary caret's.
    func endColumns() {
        guard !columnCarets.isEmpty else { return }
        columnCarets = []
        updateRevealedEquation()
        refreshCaret()
    }

    // MARK: Mouse

    /// The carets of a column from `start` to `end`, one per line between them, and which is at `end`.
    func columnCarets(from start: NSPoint, to end: NSPoint) -> (carets: [ColumnCaret], primary: Int) {
        guard let lm = layoutManager, let container = textContainer else { return ([], 0) }
        let s = string as NSString
        let origin = textContainerOrigin
        let top = min(start.y, end.y) - origin.y, bottom = max(start.y, end.y) - origin.y
        lm.ensureLayout(for: container)
        let glyphs = lm.glyphRange(forBoundingRect: NSRect(x: 0, y: top, width: container.size.width, height: max(bottom - top, 1)),
                                   in: container)
        var lines: [(caret: ColumnCaret, end: Int, isStart: Bool)] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            guard rect.maxY > top, rect.minY <= bottom else { return }
            let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var lineEnd = NSMaxRange(chars)
            if lineEnd > chars.location, s.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
            var positions = [CGFloat](repeating: 0, count: chars.length + 1)
            var indexes = [Int](repeating: 0, count: chars.length + 1)
            let count = lm.getLineFragmentInsertionPoints(forCharacterAt: chars.location, alternatePositions: false,
                                                         inDisplayOrder: true, positions: &positions, characterIndexes: &indexes)
            // Hidden glyphs can shift or omit the insertion boundary before the next visible character.
            for i in 0..<count where indexes[i] < NSMaxRange(chars) {
                var glyph = lm.glyphIndexForCharacter(at: indexes[i])
                guard lm.propertyForGlyph(at: glyph).contains(.null) else {
                    if glyph > glyphRange.location, lm.propertyForGlyph(at: glyph - 1).contains(.null) {
                        positions[i] = lm.location(forGlyphAt: glyph).x
                    }
                    continue
                }
                while glyph < NSMaxRange(glyphRange), lm.propertyForGlyph(at: glyph).contains(.null) { glyph += 1 }
                positions[i] = glyph < NSMaxRange(glyphRange) ? lm.location(forGlyphAt: glyph).x
                    : lm.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil).maxX - rect.minX
                if let conceal = self.conceal(at: indexes[i]), conceal.replacement != 0 {
                    indexes[i] = NSMaxRange(conceal.range)
                }
            }
            func index(_ x: CGFloat) -> Int {
                let x = x - origin.x - rect.minX
                let closest = (0..<count).filter { indexes[$0] <= lineEnd }.min {
                    let a = abs(positions[$0] - x), b = abs(positions[$1] - x)
                    return a == b ? indexes[$0] < indexes[$1] : a < b
                }
                return closest.map { self.insertionIndexForConceals(indexes[$0]) } ?? lineEnd
            }
            let isStart = start.y - origin.y >= rect.minY && start.y - origin.y < rect.maxY
            lines.append((ColumnCaret(anchor: index(start.x), head: index(end.x)), lineEnd, isStart))
        }
        // Starting past the end of its line puts carets at the end of shorter lines; otherwise those get none.
        let pastEnd = lines.contains { $0.isStart && $0.caret.anchor == $0.end }
        let carets = lines.filter { pastEnd || $0.caret.anchor != $0.end }.map(\.caret)
        return (carets, end.y >= start.y ? carets.count - 1 : 0)
    }

    /// Selects the column the pointer spans until the button goes up.
    func dragColumns(from event: NSEvent) {
        window?.makeFirstResponder(self)
        let start = convert(event.locationInWindow, from: nil)
        var current = event
        defer {
            updateRevealedEquation()
            refreshCaret()
        }
        while true {
            let found = columnCarets(from: start, to: convert(current.locationInWindow, from: nil))
            setColumns(found.carets, primary: found.primary)
            autoscroll(with: current)
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type != .leftMouseUp else { break }
            current = next
        }
    }

    /// Adds a caret where a ⌥⇧-click lands, or takes away the one there.
    func toggleCaret(at index: Int) {
        var carets = isColumnMode ? columnCarets : [ColumnCaret(anchor: selectedRange().location, head: NSMaxRange(selectedRange()))]
        if let hit = carets.firstIndex(where: { $0.range.length == 0 && $0.head == index }), carets.count > 1 {
            carets.remove(at: hit)
            return setColumns(carets, primary: carets.count - 1)
        }
        carets.append(ColumnCaret(index))
        setColumns(carets, primary: carets.count - 1)
    }

    /// Adds a caret on the line above the topmost caret, or below the bottommost.
    func addCaret(up: Bool) {
        let carets = isColumnMode ? columnCarets : [ColumnCaret(anchor: selectedRange().location, head: NSMaxRange(selectedRange()))]
        guard let edge = up ? carets.first : carets.last, let target = verticalTarget(of: edge.head, up: up) else { return NSSound.beep() }
        let added = carets + [ColumnCaret(target)]
        setColumns(added, primary: up ? 0 : added.count - 1)
    }

    /// ⇧↑ and ⇧↓ in column selection mode: grows the column a line, or shrinks it when it grew the other way.
    func extendColumn(up: Bool) {
        var carets = isColumnMode ? columnCarets : [ColumnCaret(anchor: selectedRange().location, head: NSMaxRange(selectedRange()))]
        let shrinking = carets.count > 1 && (up ? primaryColumn == carets.count - 1 : primaryColumn == 0)
        if shrinking {
            carets.remove(at: primaryColumn)
            return setColumns(carets, primary: up ? carets.count - 1 : 0)
        }
        guard let edge = up ? carets.first : carets.last,
              let anchor = verticalTarget(of: edge.anchor, up: up), let head = verticalTarget(of: edge.head, up: up) else { return NSSound.beep() }
        let added = carets + [ColumnCaret(anchor: anchor, head: head)]
        setColumns(added, primary: up ? 0 : added.count - 1)
    }

    // MARK: Editing

    /// Types into every selection.
    func insertInColumns(_ text: String) {
        replaceInColumns(columnCarets.map { ($0.range, text) }, action: "Typing")
    }

    /// Replaces `edits`, one per caret in order, as one undo step, and puts each caret after its text.
    func replaceInColumns(_ edits: [(range: NSRange, text: String)], action: String) {
        guard edits.count == columnCarets.count else { return }
        let changed = edits.filter { $0.range.length > 0 || !$0.text.isEmpty }
        guard !changed.isEmpty else { return }
        guard shouldChangeText(inRanges: changed.map { NSValue(range: $0.range) }, replacementStrings: changed.map(\.text)) else { return }
        isUpdatingColumns = true
        textStorage?.beginEditing()
        for edit in changed.reversed() { replaceCharacters(in: edit.range, with: edit.text) }
        textStorage?.endEditing()
        isUpdatingColumns = false
        var delta = 0
        let carets = edits.map { edit -> ColumnCaret in
            let length = (edit.text as NSString).length
            let caret = edit.range.location + delta + length
            delta += length - edit.range.length
            return ColumnCaret(caret)
        }
        let primary = primaryColumn
        didChangeText()
        undoManager?.setActionName(action)
        setColumns(carets, primary: primary)
    }

    /// Handles the editing and moving commands for every caret; false for the rest, which end the columns.
    func performInColumns(_ selector: Selector) -> Bool {
        let s = string as NSString
        let lines = { (caret: Int) in s.lineRange(for: NSRange(location: caret, length: 0)) }
        let lineEnd = { (caret: Int) -> Int in
            let line = lines(caret)
            var end = NSMaxRange(line)
            if end > line.location, s.character(at: end - 1) == 10 { end -= 1 }
            return end
        }
        func left(_ i: Int) -> Int { i > 0 ? s.rangeOfComposedCharacterSequence(at: i - 1).location : 0 }
        func right(_ i: Int) -> Int { i < s.length ? NSMaxRange(s.rangeOfComposedCharacterSequence(at: i)) : i }
        func word(_ i: Int, forward: Bool) -> Int { textStorage?.nextWord(from: i, forward: forward) ?? i }
        // Where a command moves a caret.
        let moves: [Selector: (Int) -> Int] = [
            #selector(moveLeft(_:)): left, #selector(moveBackward(_:)): left,
            #selector(moveRight(_:)): right, #selector(moveForward(_:)): right,
            #selector(moveWordLeft(_:)): { word($0, forward: false) }, #selector(moveWordBackward(_:)): { word($0, forward: false) },
            #selector(moveWordRight(_:)): { word($0, forward: true) }, #selector(moveWordForward(_:)): { word($0, forward: true) },
            #selector(moveToLeftEndOfLine(_:)): { lines($0).location }, #selector(moveToBeginningOfLine(_:)): { lines($0).location },
            #selector(moveToBeginningOfParagraph(_:)): { lines($0).location },
            #selector(moveToRightEndOfLine(_:)): lineEnd, #selector(moveToEndOfLine(_:)): lineEnd,
            #selector(moveToEndOfParagraph(_:)): lineEnd,
            #selector(moveUp(_:)): { self.verticalTarget(of: $0, up: true) ?? $0 },
            #selector(moveDown(_:)): { self.verticalTarget(of: $0, up: false) ?? $0 },
        ]
        let extending: [Selector: Selector] = [
            #selector(moveLeftAndModifySelection(_:)): #selector(moveLeft(_:)),
            #selector(moveBackwardAndModifySelection(_:)): #selector(moveLeft(_:)),
            #selector(moveRightAndModifySelection(_:)): #selector(moveRight(_:)),
            #selector(moveForwardAndModifySelection(_:)): #selector(moveRight(_:)),
            #selector(moveWordLeftAndModifySelection(_:)): #selector(moveWordLeft(_:)),
            #selector(moveWordBackwardAndModifySelection(_:)): #selector(moveWordLeft(_:)),
            #selector(moveWordRightAndModifySelection(_:)): #selector(moveWordRight(_:)),
            #selector(moveWordForwardAndModifySelection(_:)): #selector(moveWordRight(_:)),
            #selector(moveToLeftEndOfLineAndModifySelection(_:)): #selector(moveToLeftEndOfLine(_:)),
            #selector(moveToBeginningOfLineAndModifySelection(_:)): #selector(moveToLeftEndOfLine(_:)),
            #selector(moveToBeginningOfParagraphAndModifySelection(_:)): #selector(moveToLeftEndOfLine(_:)),
            #selector(moveParagraphBackwardAndModifySelection(_:)): #selector(moveToLeftEndOfLine(_:)),
            #selector(moveToRightEndOfLineAndModifySelection(_:)): #selector(moveToRightEndOfLine(_:)),
            #selector(moveToEndOfLineAndModifySelection(_:)): #selector(moveToRightEndOfLine(_:)),
            #selector(moveToEndOfParagraphAndModifySelection(_:)): #selector(moveToRightEndOfLine(_:)),
            #selector(moveParagraphForwardAndModifySelection(_:)): #selector(moveToRightEndOfLine(_:)),
        ]
        // Deleting stops at the line's edges, so the lines stay apart.
        let deletions: [Selector: (Int) -> Int] = [
            #selector(deleteBackward(_:)): { max(left($0), lines($0).location) },
            #selector(deleteBackwardByDecomposingPreviousCharacter(_:)): { max(left($0), lines($0).location) },
            #selector(deleteForward(_:)): { min(right($0), lineEnd($0)) },
            #selector(deleteWordBackward(_:)): { max(word($0, forward: false), lines($0).location) },
            #selector(deleteWordForward(_:)): { min(word($0, forward: true), lineEnd($0)) },
            #selector(deleteToBeginningOfLine(_:)): { lines($0).location },
            #selector(deleteToBeginningOfParagraph(_:)): { lines($0).location },
            #selector(deleteToEndOfLine(_:)): lineEnd,
            #selector(deleteToEndOfParagraph(_:)): lineEnd,
        ]
        if let move = moves[selector] {
            let backward = [#selector(moveLeft(_:)), #selector(moveBackward(_:))].contains(selector)
            let forward = [#selector(moveRight(_:)), #selector(moveForward(_:))].contains(selector)
            // A selection collapses to the side the arrow points to before carets move.
            setColumns(columnCarets.map { c in
                let r = c.range
                if r.length > 0, backward { return ColumnCaret(r.location) }
                if r.length > 0, forward { return ColumnCaret(NSMaxRange(r)) }
                return ColumnCaret(move(c.head))
            }, primary: primaryColumn)
            return true
        }
        if let base = extending[selector], let move = moves[base] {
            setColumns(columnCarets.map { ColumnCaret(anchor: $0.anchor, head: move($0.head)) }, primary: primaryColumn)
            return true
        }
        if let target = deletions[selector] {
            replaceInColumns(columnCarets.map { c in
                if c.range.length > 0 { return (c.range, "") }
                let to = target(c.head)
                return (NSRange(location: min(to, c.head), length: abs(to - c.head)), "")
            }, action: "Delete")
            return true
        }
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            insertInColumns("\n")
        case #selector(insertTab(_:)):
            insertInColumns("  ")
        case #selector(cancelOperation(_:)):
            let primary = columnCarets[primaryColumn]
            endColumns()
            setSelectedRange(NSRange(location: primary.head, length: 0))
        case #selector(moveUpAndModifySelection(_:)):
            extendColumn(up: true)
        case #selector(moveDownAndModifySelection(_:)):
            extendColumn(up: false)
        default:
            return false
        }
        return true
    }

    /// The same column on the line above or below `caret`, or its end when that line is shorter.
    func verticalTarget(of caret: Int, up: Bool) -> Int? {
        let s = string as NSString
        let line = s.lineRange(for: NSRange(location: caret, length: 0))
        let column = caret - line.location
        if up {
            guard line.location > 0 else { return nil }
            let above = s.lineRange(for: NSRange(location: line.location - 1, length: 0))
            return above.location + min(column, max(line.location - 1 - above.location, 0))
        }
        let next = NSMaxRange(line)
        guard next > line.location, s.character(at: next - 1) == 10 else { return nil }
        let below = s.lineRange(for: NSRange(location: next, length: 0))
        var end = NSMaxRange(below)
        if end > below.location, s.character(at: end - 1) == 10 { end -= 1 }
        return below.location + min(column, end - below.location)
    }

    var currentCarets: [ColumnCaret] {
        isColumnMode ? columnCarets : [ColumnCaret(anchor: selectedRange().location, head: NSMaxRange(selectedRange()))]
    }

    var hasOnlyInsertionPoints: Bool { currentCarets.allSatisfy { $0.range.length == 0 } }

    func applyLineChange(_ change: LineChange, action: String) {
        let primary = isColumnMode ? primaryColumn : 0
        let edit = change.edit
        if edit.range.length > 0 || !edit.newText.isEmpty {
            let range = NSRange(location: Int(edit.range.location), length: Int(edit.range.length))
            breakUndoCoalescing()
            guard shouldChangeText(in: range, replacementString: edit.newText) else { return }
            isUpdatingColumns = true
            replaceCharacters(in: range, with: edit.newText)
            isUpdatingColumns = false
            didChangeText()
            undoManager?.setActionName(action)
        }
        setColumns(change.selections.map { ColumnCaret(anchor: Int($0.anchor), head: Int($0.head)) }, primary: primary)
    }

    func copyCurrentRows(selectRows: Bool = true) {
        let offsets = currentCarets.map { Int32($0.head) }
        let primary = selectedRange().location
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyCurrentLines(offsets: offsets, text: string), forType: .string)
        if selectRows {
            let rows = currentLineSelections(offsets: offsets, text: string).map {
                ColumnCaret(anchor: Int($0.anchor), head: Int($0.head))
            }
            let main = rows.firstIndex { NSLocationInRange(primary, $0.range) || $0.anchor == primary } ?? rows.count - 1
            setColumns(rows, primary: main)
        }
    }

    func cutCurrentRows() {
        let change = cutCurrentLines(offsets: currentCarets.map { Int32($0.head) }, text: string)
        copyCurrentRows(selectRows: false)
        applyLineChange(change, action: "Cut")
    }

    // MARK: Pasteboard

    /// Each selection's text on a line of its own.
    func copyColumns() {
        let s = string as NSString
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(columnCarets.map { s.substring(with: $0.range) }.joined(separator: "\n"), forType: .string)
    }

    /// One line for each caret when the pasted lines match them, else all of it at every caret.
    func pasteInColumns() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
        var lines = text.components(separatedBy: "\n")
        if lines.count == columnCarets.count + 1, lines.last == "" { lines.removeLast() }
        let pieces = lines.count == columnCarets.count ? lines : Array(repeating: text, count: columnCarets.count)
        replaceInColumns(zip(columnCarets, pieces).map { ($0.range, $1) }, action: "Paste")
    }

    // MARK: Drawing

    func drawSelections(in rect: NSRect) {
        let ranges = isColumnMode ? columnCarets.map(\.range) : selectedRanges.map(\.rangeValue)
        let boxes = ranges.flatMap { selectionBoxes(for: $0) }
        guard !boxes.isEmpty else { return }
        selectionColor.setFill()
        selectionPath(for: boxes).fill()
    }

    func selectionBoxes(for range: NSRange) -> [NSRect] {
        guard let lm = layoutManager, let container = textContainer, range.length > 0,
              range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else { return [] }
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var boxes: [NSRect] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, lineGlyphs, _ in
            let selected = NSIntersectionRange(glyphs, lineGlyphs)
            lm.enumerateEnclosingRects(forGlyphRange: selected, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { box, _ in
                // Newlines stop at the text; empty lines keep one character selected.
                let end = max(used.maxX - container.lineFragmentPadding, box.minX + self.columnWidth)
                let clipped = NSRect(x: box.minX, y: box.minY, width: min(box.maxX, end) - box.minX, height: box.height)
                boxes.append(clipped.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        return boxes
    }

    /// Round the joined outline, including inward corners where neighboring lines are wider.
    func selectionPath(for boxes: [NSRect]) -> NSBezierPath {
        let outline = CGMutablePath()
        for box in boxes where box.width > 0 && box.height > 0 {
            outline.addRect(box.insetBy(dx: 0, dy: -0.5))
        }
        let path = NSBezierPath()
        var points: [NSPoint] = []
        outline.normalized(using: .winding).applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint:
                points = [element.pointee.points[0]]
            case .addLineToPoint:
                points.append(element.pointee.points[0])
            case .closeSubpath:
                path.append(self.roundedOutline(points))
            default:
                break
            }
        }
        return path
    }

    private func roundedOutline(_ vertices: [NSPoint]) -> NSBezierPath {
        let points = vertices.indices.compactMap { i -> NSPoint? in
            let previous = vertices[(i + vertices.count - 1) % vertices.count]
            let point = vertices[i], next = vertices[(i + 1) % vertices.count]
            // Collinear points would needlessly limit the corner radius.
            return (previous.x == point.x && point.x == next.x)
                || (previous.y == point.y && point.y == next.y) ? nil : point
        }
        let path = NSBezierPath()
        guard points.count >= 3 else { return path }
        for i in points.indices {
            let previous = points[(i + points.count - 1) % points.count]
            let point = points[i], next = points[(i + 1) % points.count]
            let before = hypot(point.x - previous.x, point.y - previous.y)
            let after = hypot(next.x - point.x, next.y - point.y)
            let radius = min(6, before / 2, after / 2)
            let entry = NSPoint(x: point.x + (previous.x - point.x) * radius / before,
                                y: point.y + (previous.y - point.y) * radius / before)
            let exit = NSPoint(x: point.x + (next.x - point.x) * radius / after,
                               y: point.y + (next.y - point.y) * radius / after)
            if i == 0 { path.move(to: entry) } else { path.line(to: entry) }
            path.curve(to: exit,
                       controlPoint1: NSPoint(x: entry.x + (point.x - entry.x) * 0.5523,
                                              y: entry.y + (point.y - entry.y) * 0.5523),
                       controlPoint2: NSPoint(x: exit.x + (point.x - exit.x) * 0.5523,
                                              y: exit.y + (point.y - exit.y) * 0.5523))
        }
        path.close()
        return path
    }
}
