import AppKit
import XCTest
@testable import Typewright

final class EditorTests: XCTestCase {
    func testFindsColorLiterals() {
        let text = "#set text(fill: rgb(\"#FF4136\")); #box(fill: rgb(10, 20, 30, 50%)) luma(40%) and red text, stroke: blue"
        let found = ColorLiteral.find(in: text)
        XCTAssertEqual(found.map { (text as NSString).substring(with: $0.range) },
                       ["rgb(\"#FF4136\")", "rgb(10, 20, 30, 50%)", "luma(40%)", "blue"])
        XCTAssertEqual(found[0].format, .hex(uppercase: true, alpha: false))
        XCTAssertEqual(found[1].color.alphaComponent, 0.5, accuracy: 0.001)
    }

    func testWritesColorsInTheOriginalFormat() {
        let color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        XCTAssertEqual(ColorLiteral.source(for: color, format: .hex(uppercase: false, alpha: false)), "rgb(\"#ff8000\")")
        XCTAssertEqual(ColorLiteral.source(for: color, format: .components(percent: false, alpha: false)), "rgb(255, 128, 0)")
        XCTAssertEqual(ColorLiteral.source(for: color, format: .components(percent: true, alpha: false)), "rgb(100%, 50%, 0%)")
        XCTAssertEqual(ColorLiteral.source(for: color, format: .named), "rgb(\"#ff8000\")")
        let gray = NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)
        XCTAssertEqual(ColorLiteral.source(for: gray, format: .luma(percent: true)), "rgb(\"#666666\")")
        let orange = NSColor(srgbRed: 1, green: 0x88 / 255.0, blue: 0, alpha: 1)
        XCTAssertEqual(ColorLiteral.source(for: orange, format: .hex(uppercase: false, alpha: false, short: true)), "rgb(\"#f80\")")
        XCTAssertEqual(ColorLiteral.source(for: color, format: .hex(uppercase: false, alpha: false, short: true)), "rgb(\"#ff8000\")")
        let translucent = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
        XCTAssertEqual(ColorLiteral.source(for: translucent, format: .hex(uppercase: true, alpha: false)), "rgb(\"#FF000080\")")
    }

    func testExpandsSnippets() {
        XCTAssertEqual(CompletionController.expand("decimal(${1:})").0, "decimal()")
        XCTAssertEqual(CompletionController.expand("decimal(${1:})").1, NSRange(location: 8, length: 0))
        let loop = CompletionController.expand("for (${1:key}, ${2:value}) in ${3:x} {$0}")
        XCTAssertEqual(loop.0, "for (key, value) in x {}")
        XCTAssertEqual(loop.1, NSRange(location: 5, length: 3))
        XCTAssertEqual(CompletionController.expand("figure").1, NSRange(location: 6, length: 0))
        XCTAssertEqual(CompletionController.expand("${1:alignment}").1, NSRange(location: 0, length: 9))
    }

    func testConvertsPositions() {
        let text = "ab\nçd\n€x" as NSString
        XCTAssertEqual(LanguageClient.lineAndCharacter(of: 4, in: text).0, 1)
        XCTAssertEqual(LanguageClient.lineAndCharacter(of: 4, in: text).1, 1)
        XCTAssertEqual(LanguageClient.offset(line: 2, character: 1, in: text), 7)
    }

    @MainActor func testFindAndReplace() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.string = "#let a1 = 1\n#let b22 = 2\nalabama"
        let find = FindModel()
        find.textView = tv
        find.applyEdits = { edits, _ in tv.string = TextEdit.apply(edits, to: tv.string) }
        find.show(replace: true)

        find.query = "a"
        XCTAssertEqual(find.matches.count, 5)
        find.wholeWord = true
        XCTAssertEqual(find.matches.count, 0)
        find.wholeWord = false

        find.regex = true
        find.query = #"let (\w)(\d+)"#
        XCTAssertEqual(find.matches.count, 2)
        find.replacement = "let $2$1"
        find.replaceAll()
        XCTAssertEqual(tv.string, "#let 1a = 1\n#let 22b = 2\nalabama")

        find.regex = false
        find.query = "1a"
        find.replacement = "$x"
        find.replaceAll()
        XCTAssertTrue(tv.string.hasPrefix("#let $x = 1"))

        find.regex = true
        find.query = "("
        XCTAssertNotNil(find.error)
    }

    func testSearchFindsLinesAndColumns() throws {
        let regex = try NSRegularExpression(pattern: "greet", options: [.caseInsensitive])
        let text = "#let greet = 1\nnothing\n  #Greet and #greet"
        let hits = SpaceSearchEngine.lines(matching: regex, in: text, file: URL(fileURLWithPath: "/x.typ"), firstID: 0)
        XCTAssertEqual(hits.map(\.line), [0, 2, 2])
        XCTAssertEqual(hits.map(\.column), [5, 3, 14])
        XCTAssertEqual(hits[1].text, "  #Greet and #greet")
    }

    func testPaletteScoring() {
        XCTAssertEqual(CommandPalette.score("new", "new file in sub"), 0)
        XCTAssertEqual(CommandPalette.score("file", "new file in sub"), 1)
        XCTAssertEqual(CommandPalette.score("nfs", "new file in sub"), 4)
        XCTAssertNil(CommandPalette.score("xyz", "new file"))
    }
}
