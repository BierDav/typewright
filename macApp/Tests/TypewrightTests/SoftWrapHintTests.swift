import AppKit
import XCTest
@testable import Typewright

@MainActor
final class SoftWrapHintTests: XCTestCase {
    private func editor() -> TypstTextView {
        let storage = NSTextStorage(), layout = EditorLayoutManager()
        storage.addLayoutManager(layout)
        let container = EditorTextContainer(size: NSSize(width: 220, height: 2000))
        layout.addTextContainer(container)
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600), textContainer: container)
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.wrapColumn = 20
        tv.string = String(repeating: "a", count: 55) + "\nplain\n" + String(repeating: "b", count: 55)
        return tv
    }

    func testMarkersFollowCaretsWithoutChangingLayout() throws {
        let tv = editor(), layout = tv.layoutManager!, container = tv.textContainer!
        func fragments() -> [NSRect] {
            layout.ensureLayout(for: container)
            var rects: [NSRect] = []
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, _, _ in
                rects.append(rect)
            }
            return rects
        }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let before = fragments()
        let first = tv.softWrapHints(in: tv.bounds)
        XCTAssertEqual(first.map(\.continues), [false, true, false, true])
        tv.setSelectedRange(NSRange(location: 30, length: 0))
        XCTAssertEqual(tv.softWrapHints(in: tv.bounds).map(\.rect), first.map(\.rect))
        tv.setSelectedRange(NSRange(location: 56, length: 0))
        XCTAssertTrue(tv.softWrapHints(in: tv.bounds).isEmpty)
        XCTAssertEqual(fragments(), before)
        tv.setColumns([.init(1), .init(63)], primary: 1)
        XCTAssertEqual(tv.softWrapHints(in: tv.bounds).count, 8)
        XCTAssertEqual(fragments(), before)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        XCTAssertEqual(tv.softWrapHints(in: tv.bounds).count, 4)
    }

    func testMarkerSlotsStayClearOfTextAndScaleWithFont() throws {
        let tv = editor(), layout = tv.layoutManager!, container = tv.textContainer as! EditorTextContainer
        for fontSize in [13.0, 24.0] {
            tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            layout.ensureLayout(for: container)
            let hints = tv.softWrapHints(in: tv.bounds)
            XCTAssertFalse(hints.isEmpty)
            for hint in hints {
                XCTAssertEqual(hint.rect.width, tv.columnWidth, accuracy: 0.01)
                let glyphs = layout.glyphRange(forBoundingRect: NSRect(x: 0, y: hint.rect.midY - tv.textContainerOrigin.y,
                                                                      width: container.size.width, height: 1), in: container)
                let text = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: tv.textContainerOrigin.x,
                                                                                           dy: tv.textContainerOrigin.y)
                if hint.continues {
                    XCTAssertLessThanOrEqual(hint.rect.maxX, text.minX + 0.01)
                } else {
                    XCTAssertGreaterThanOrEqual(hint.rect.minX, text.maxX - 0.01)
                    XCTAssertLessThanOrEqual(hint.rect.maxX, tv.textContainerOrigin.x + container.size.width)
                }
            }
        }
    }

    func testRemovingWrapRemovesMarkers() {
        let tv = editor()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(tv.softWrapHints(in: tv.bounds).isEmpty)
        tv.string = "short\nplain"
        XCTAssertTrue(tv.softWrapHints(in: tv.bounds).isEmpty)
    }
}
