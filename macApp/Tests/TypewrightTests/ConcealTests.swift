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

    func testEmptyStringsGlueNeighboursAndRevealWithThem() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$Delta\"\"Gamma\"\"Omega + a\"\"b$"
        tv.setSelectedRange(NSRange(location: 21, length: 0))
        tv.concealsMath = true
        XCTAssertEqual(shown(tv), "$??? + ab$")
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(shown(tv), "$Delta\"\"Gamma\"\"Omega + ab$", "all five reveal together")
    }

    func testEmptyStringsGlueLiteralGreekLetters() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$ Sigma\"\"r $ and $ Σ\"\"r $"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        XCTAssertEqual(shown(tv), "$ ?r $ and $ Σr $")
        tv.setSelectedRange(NSRange(location: 20, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(shown(tv), "$ ?r $ and $ Σ\"\"r $")
    }

    func testSelectionTakesConcealedPiecesWhole() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a Omega b$"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        // Dragging from before into Omega takes all of it.
        tv.setSelectedRange(NSRange(location: 1, length: 4))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 1, length: 7))
        // Shrinking back into it lets go of it.
        tv.setSelectedRange(NSRange(location: 1, length: 6))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 1, length: 2))
        // From behind, the start snaps the same way.
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        tv.setSelectedRange(NSRange(location: 6, length: 4))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 7))
        // Inside it, which then shows as typed, every character selects.
        tv.setSelectedRange(NSRange(location: 4, length: 2))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 2))
    }

    func testCaretEntersPiecesBeforeTheirHiddenQuote() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a \"abc\" b$"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.concealsMath = true
        tv.moveRight(nil)
        XCTAssertEqual(tv.selectedRange().location, 3, "in front of the hidden quote, not after it")
        tv.updateRevealedEquation()
        tv.moveRight(nil)
        XCTAssertEqual(tv.selectedRange().location, 4, "shown as typed, one character at a time")
        // A click on the piece's start lands after the hidden quote.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.updateRevealedEquation()
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 3)
    }

    func testUpAndDownLandUnderTheCaretOnceThePieceShows() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "xxxxxx\n$\"abc\"$\nxxxxxx"
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.concealsMath = true
        tv.moveDown(nil)
        // Under column 3 once the quotes show: `$"a|bc"$`.
        XCTAssertEqual(tv.selectedRange().location, 10)
        tv.updateRevealedEquation()
        tv.moveDown(nil)
        XCTAssertEqual(tv.selectedRange().location, 18, "back in column 3")
        tv.updateRevealedEquation()
        tv.moveUp(nil)
        XCTAssertEqual(tv.selectedRange().location, 10)
    }

    func testOperatorsUseBoldLigaturesWithoutFolds() {
        let text = "$ x := 1 -> $"
        XCTAssertTrue(Highlighter.conceals(in: text).isEmpty)
        let storage = NSTextStorage(string: text)
        Highlighter.apply(to: storage, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        for index in [4, 9] {
            let font = storage.attribute(.font, at: index, effectiveRange: nil) as! NSFont
            XCTAssertEqual(font.fontName, "JetBrainsMono-Bold")
            XCTAssertEqual(storage.attribute(.ligature, at: index, effectiveRange: nil) as? Int, 2)
        }
        func glyphs(ligature: Int) -> [CGGlyph] {
            let arrow = NSAttributedString(string: "->", attributes: [
                .font: Highlighter.operatorFont(size: 13, ligatures: ligature != 0), .ligature: ligature,
            ])
            let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(arrow)) as! [CTRun]
            return runs.flatMap { run in
                var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                return glyphs
            }
        }
        XCTAssertNotEqual(glyphs(ligature: 2), glyphs(ligature: 0), "the arrow uses the font's ligature")
    }

    func testOperatorLigaturesRevealAtTheCaretWithoutFolds() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = "$x -> y$"
        let storage = tv.textStorage!
        Highlighter.apply(to: storage, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
                       Highlighter.operatorFont(size: 13, ligatures: false))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
                       Highlighter.operatorFont(size: 13))
        XCTAssertTrue(tv.conceals.isEmpty)
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

    func testQuotesPairAfterLettersWhereTheyGlueNames() {
        let block = "```solveng\nt\n```"
        let code = editor(block, caret: 12)
        type(code, "\"")
        XCTAssertEqual(code.string, "```solveng\nt\"\"\n```")
        type(code, "\"tau")
        XCTAssertEqual(code.string, "```solveng\nt\"\"tau\n```", "the second quote steps over")
        let math = editor("$Delta$", caret: 6)
        type(math, "\"\"")
        XCTAssertEqual(math.string, "$Delta\"\"$")
        let other = editor("```py\nt\n```", caret: 7)
        type(other, "\"")
        XCTAssertEqual(other.string, "```py\nt\"\n```")
    }
}
