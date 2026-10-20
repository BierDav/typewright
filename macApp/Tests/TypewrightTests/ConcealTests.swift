import AppKit
import XCTest
@testable import Typewright

@MainActor
final class ConcealTests: XCTestCase {
    /// The text as drawn: hidden glyphs left out, replaced ones as their character.
    private func shown(_ tv: TypstTextView) -> String {
        let lm = tv.layoutManager!
        let s = tv.string as NSString
        var result = ""
        for g in 0..<lm.numberOfGlyphs {
            guard lm.propertyForGlyph(at: g) != .null else { continue }
            let index = lm.characterIndexForGlyph(at: g)
            let original = lm.glyph(at: g) == (lm.textStorage!.attribute(.font, at: index, effectiveRange: nil) as! NSFont)
                .glyph(for: s.character(at: index))
            result += original ? s.substring(with: NSRange(location: index, length: 1)) : "?"
        }
        return result
    }

    func testMathShowsRenderedUntilTheCaretTouchesIt() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "R = $12\"k\"Omega$ ok"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        XCTAssertEqual(shown(tv), "R = $12k?$ ok")
        // Only the piece at the caret reveals: the string, then the symbol.
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(shown(tv), "R = $12\"k\"?$ ok")
        tv.setSelectedRange(NSRange(location: 15, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(shown(tv), "R = $12kOmega$ ok")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(shown(tv), "R = $12k?$ ok", "elsewhere in the equation")
        tv.setSelectedRange(NSRange(location: 18, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(shown(tv), "R = $12k?$ ok")
    }

    func testEscapesShowTheirCharacter() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "1\\. Übung \\#"
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.concealsMath = true
        XCTAssertEqual(shown(tv), "1? Übung ?")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(shown(tv), "1\\. Übung ?", "the escape at the caret shows its source")
    }

    func testHiddenQuotesTakeNoSpace() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$\"V\", x$"
        tv.concealsMath = true
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        let lm = tv.layoutManager!, container = tv.textContainer!
        lm.ensureLayout(for: container)
        func x(_ index: Int) -> CGFloat {
            lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil),
                            in: container).minX
        }
        let width = ("M" as NSString).size(withAttributes: [.font: tv.font!]).width
        XCTAssertEqual(x(4) - x(2), width, accuracy: 0.5, "the comma follows the V directly")
    }

    func testEditingOneEquationKeepsTheOthersRight() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$240 \"V\" Omeg$ and $9 \"V\", 228 \"A\"$"
        tv.concealsMath = true
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        tv.updateRevealedEquation()
        _ = shown(tv)
        // Typing in the first equation shifts every later conceal.
        tv.insertText("a", replacementRange: NSRange(location: 13, length: 0))
        tv.layoutManager?.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(shown(tv), "$240 V Omega$ and $9 V, 228 A$")
    }
}

private extension NSFont {
    func glyph(for character: unichar) -> CGGlyph {
        var c = character, g: CGGlyph = 0
        CTFontGetGlyphsForCharacters(self, &c, &g, 1)
        return g
    }
}

@MainActor
final class AutoCloseTests: XCTestCase {
    private func editor(_ text: String, caret: Int, length: Int = 0) -> TypstTextView {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.autoPairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "$": "$"]
        tv.string = text
        tv.setSelectedRange(NSRange(location: caret, length: length))
        return tv
    }

    private func type(_ tv: TypstTextView, _ text: String) {
        for c in text { tv.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    func testClosesStepsOverAndDeletesPairs() {
        let tv = editor("#f", caret: 2)
        type(tv, "(\"a")
        XCTAssertEqual(tv.string, "#f(\"a\")")
        type(tv, "\")")
        XCTAssertEqual(tv.string, "#f(\"a\")", "closers step over")
        XCTAssertEqual(tv.selectedRange().location, 7)
        type(tv, " $")
        XCTAssertEqual(tv.string, "#f(\"a\") $$")
        tv.deleteBackward(nil)
        XCTAssertEqual(tv.string, "#f(\"a\") ", "backspace takes the empty pair")
    }

    func testWrapsSelectionsAndLeavesWordsAlone() {
        let tv = editor("x word", caret: 2, length: 4)
        type(tv, "[")
        XCTAssertEqual(tv.string, "x [word]")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 4))
        let before = editor("word", caret: 0)
        type(before, "(")
        XCTAssertEqual(before.string, "(word", "no stray closer in front of a word")
        let after = editor("don", caret: 3)
        type(after, "\"")
        XCTAssertEqual(after.string, "don\"", "no pair for a quote right after a letter")
    }
}
