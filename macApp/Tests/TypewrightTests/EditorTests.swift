import AppKit
import Carbon.HIToolbox
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
    func testFindsHexWithoutHash() {
        let text = "#set page(fill: rgb(\"DDD3C4\"))"
        let found = ColorLiteral.find(in: text)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].format, .hex(uppercase: true, alpha: false, hash: false))
        let color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        XCTAssertEqual(ColorLiteral.source(for: color, format: found[0].format), "rgb(\"FF8000\")")
    }

    func testHighlightsParametersNumbersAndUnits() {
        let text = "#set page(margin: (top: 15mm, right: right-m), columns: 2)"
        let runs = Highlighter.runs(in: text)
        func tag(of token: String) -> Highlighter.Tag? {
            let r = (text as NSString).range(of: token)
            return runs.first { NSLocationInRange(r.location, $0.range) }?.tag
        }
        XCTAssertEqual(tag(of: "set"), .keyword)
        XCTAssertEqual(tag(of: "page"), .function)
        XCTAssertEqual(tag(of: "margin"), .param)
        XCTAssertEqual(tag(of: "top"), .param)
        XCTAssertEqual(tag(of: "15"), .number)
        XCTAssertEqual(tag(of: "mm"), .unit)
        XCTAssertNil(tag(of: "right-m"))
        XCTAssertEqual(tag(of: "2"), .number)
        let code = Highlighter.runs(in: "let x = \"a\" // c", code: true)
        XCTAssertEqual(code.map(\.tag), [.keyword, .operator, .string, .comment])
    }

    func testHighlightsMarkup() {
        let text = "= Title <intro>\nSee @intro and *bold* $x^2$"
        let runs = Highlighter.runs(in: text)
        func run(at token: String) -> Highlighter.Run? {
            let r = (text as NSString).range(of: token)
            return runs.first { NSLocationInRange(r.location, $0.range) }
        }
        XCTAssertEqual(run(at: "Title")?.tag, .heading)
        XCTAssertEqual(run(at: "<intro>")?.tag, .label)
        XCTAssertEqual(run(at: "@intro")?.tag, .ref)
        XCTAssertEqual(run(at: "bold")?.bold, true)
        XCTAssertEqual(run(at: "x^")?.math, true)
        XCTAssertNil(run(at: "See"))
    }

    func testLayoutsRebindShortcuts() {
        XCTAssertEqual(BuiltinLayout.standard.shortcuts.commentLine.display, "⌘/")
        XCTAssertEqual(BuiltinLayout.standard.shortcuts.commentBlock.display, "⌥⌘/")
        XCTAssertEqual(BuiltinLayout.standard.shortcuts.replace.display, "⌥⌘F")
        XCTAssertEqual(BuiltinLayout.standard.shortcuts.back.display, "⌃⌘←")
        let intellij = BuiltinLayout.intellij.shortcuts
        XCTAssertEqual(intellij.commentLine.display, "⌘7")
        XCTAssertEqual(intellij.commentBlock.display, "⇧⌘7")
        XCTAssertEqual(intellij.replace.display, "⌘R")
        XCTAssertEqual(intellij.palette.display, "⇧⌘A")
        XCTAssertEqual(intellij.moveFile.display, "F6")
        XCTAssertEqual(intellij.back.display, "⌥⌘←")
        XCTAssertEqual(intellij.togglePreview.display, "⌘-")
        XCTAssertEqual(intellij.previewCurrentFile.display, "⇧⌘-")
    }

    func testShortcutsMatchPhysically() throws {
        // On a German keyboard the minus key types ß; the layout still has to find it.
        let minus = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "ß", charactersIgnoringModifiers: "ß", isARepeat: false, keyCode: UInt16(kVK_ANSI_Minus)))
        XCTAssertTrue(BuiltinLayout.intellij.shortcuts.togglePreview.matches(minus))
        let comment = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "*", charactersIgnoringModifiers: "*", isARepeat: false, keyCode: UInt16(kVK_ANSI_7)))
        XCTAssertTrue(BuiltinLayout.intellij.shortcuts.commentBlock.matches(comment))
        XCTAssertFalse(BuiltinLayout.standard.shortcuts.commentBlock.matches(comment))
    }

    func testIntellijPaletteOpensWithBothKeys() throws {
        let palette = BuiltinLayout.intellij.shortcuts.palette
        XCTAssertEqual(palette.display, "⇧⌘A")
        XCTAssertEqual(palette.allDisplay, "⇧⌘A / ⌘K")
        let commandK = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)))
        XCTAssertTrue(palette.matches(commandK))
        let commandShiftA = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
        XCTAssertTrue(palette.matches(commandShiftA))
    }

    func testForksPatchOnlyChangedShortcuts() {
        let fork = KeyLayout(id: "fork", name: "My Keys", base: .intellij,
                             overrides: [.commentLine: Shortcut(key: .character("9"), modifiers: .command)])
        let base = BuiltinLayout.intellij.shortcuts
        XCTAssertEqual(fork.shortcuts.commentLine.display, "⌘9")
        // Everything else, alternates included, keeps following the built-in layout.
        XCTAssertEqual(fork.shortcuts.commentBlock, base.commentBlock)
        XCTAssertEqual(fork.shortcuts.palette, base.palette)
        XCTAssertEqual(fork.shortcuts.palette.allDisplay, "⇧⌘A / ⌘K")
        XCTAssertEqual(fork.overrides.count, 1)
        XCTAssertEqual(fork.summary, "A fork of IntelliJ IDEA with 1 changed shortcut.")
        let unchanged = KeyLayout(id: "same", name: "Same", base: .intellij, overrides: [:])
        XCTAssertEqual(unchanged.shortcuts, base)
    }

    func testShortcutsRoundTripThroughJSON() throws {
        let shortcut = Shortcut(key: .function(6), modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(shortcut)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), shortcut)
        let minus = Shortcut(key: .character("-"), modifiers: .command)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(minus)), minus)
    }

    func testTogglesLineComments() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.comments = .typst
        tv.string = "a\n  b\n"
        tv.setSelectedRange(NSRange(location: 0, length: 6))
        tv.toggleLineComment()
        XCTAssertEqual(tv.string, "// a\n  // b\n")
        tv.toggleLineComment()
        XCTAssertEqual(tv.string, "a\n  b\n")

        // Blank lines stay as they are, the caret keeps its line.
        tv.string = "a\n\nb"
        tv.setSelectedRange(NSRange(location: 3, length: 1))
        tv.toggleLineComment()
        XCTAssertEqual(tv.string, "a\n\n// b")
        tv.toggleLineComment()
        XCTAssertEqual(tv.string, "a\n\nb")

        // Markdown has no line comments, so the HTML ones wrap each line.
        tv.comments = .markdown
        tv.string = "text\n"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.toggleLineComment()
        XCTAssertEqual(tv.string, "<!-- text -->\n")
        tv.toggleLineComment()
        XCTAssertEqual(tv.string, "text\n")
    }

    func testTogglesBlockComment() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.comments = .typst
        tv.string = "a\nbc\nd"
        tv.setSelectedRange(NSRange(location: 2, length: 2))
        tv.toggleBlockComment()
        XCTAssertEqual(tv.string, "a\n/*bc*/\nd")
        tv.toggleBlockComment()
        XCTAssertEqual(tv.string, "a\nbc\nd")

        // A caret wraps its line's text between the indentation and the break.
        tv.string = "a\n  bc\nd"
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.toggleBlockComment()
        XCTAssertEqual(tv.string, "a\n  /*bc*/\nd")
        XCTAssertEqual(tv.selectedRange().location, 6)
        tv.toggleBlockComment()
        XCTAssertEqual(tv.string, "a\n  bc\nd")
    }

    func testDuplicatesAndDeletesLines() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = "a\nbc\nd"
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.duplicateLine()
        XCTAssertEqual(tv.string, "a\nbc\nbc\nd")
        XCTAssertEqual(tv.selectedRange().location, 6)
        tv.deleteLine()
        XCTAssertEqual(tv.string, "a\nbc\nd")
        XCTAssertEqual(tv.selectedRange().location, 6)
        tv.deleteLine()
        XCTAssertEqual(tv.string, "a\nbc")
        XCTAssertEqual(tv.selectedRange().location, 3)
        tv.setSelectedRange(NSRange(location: 0, length: 1))
        tv.duplicateLine()
        XCTAssertEqual(tv.string, "aa\nbc")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 1, length: 1))
    }
    func testExtractsAndInlinesVariables() {
        let text = "#set page(margin: (top: 15mm, bottom: 15mm))"
        let caret = NSRange(location: (text as NSString).range(of: "15mm").location + 1, length: 0)
        let candidate = Refactor.candidates(in: text, selection: caret).candidates[0]
        XCTAssertEqual(candidate.text, "15mm")
        let extracted = Refactor.extract(in: text, range: candidate.range, all: true)
        XCTAssertEqual(extracted.count, 2)
        let out = TextEdit.apply(extracted.textEdits, to: text)
        XCTAssertEqual(out, "#let margin-top = 15mm\n#set page(margin: (top: margin-top, bottom: margin-top))")
        XCTAssertEqual(extracted.nameRanges.map { (out as NSString).substring(with: $0) }, Array(repeating: "margin-top", count: 3))
        let inlined = Refactor.inline(in: out, at: 6)
        XCTAssertEqual(TextEdit.apply(inlined.textEdits, to: out), text)
        XCTAssertNotNil(Refactor.inline(in: "plain text", at: 2).error)
    }
    func testMovesLines() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = "a\nbc\nd"
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.moveLines(up: false)
        XCTAssertEqual(tv.string, "a\nd\nbc")
        XCTAssertEqual(tv.selectedRange().location, 5)
        tv.moveLines(up: true)
        tv.moveLines(up: true)
        XCTAssertEqual(tv.string, "bc\na\nd")
        XCTAssertEqual(tv.selectedRange().location, 1)
        tv.string = "x\ny\nz\n"
        tv.setSelectedRange(NSRange(location: 0, length: 4))
        tv.moveLines(up: false)
        XCTAssertEqual(tv.string, "z\nx\ny\n")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 4))
        // After a final break the empty last line moves like any other.
        tv.string = "a\nb\n"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.moveLines(up: false)
        XCTAssertEqual(tv.string, "a\n\nb")
        XCTAssertEqual(tv.selectedRange().location, 3)
        tv.string = "a\nb\n"
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.moveLines(up: true)
        XCTAssertEqual(tv.string, "a\n\nb")
        XCTAssertEqual(tv.selectedRange().location, 2)
    }
    func testHighlightsMarkdown() {
        let text = "# Title\n\nSome **bold** and `code` with [link](https://x.y).\n\n```typ\n#let a = 1\n```\n- item\n"
        let storage = NSTextStorage(string: text)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        MarkdownHighlighter.apply(to: storage, font: font)
        func color(_ needle: String, offset: Int = 0) -> NSColor? {
            storage.attribute(.foregroundColor, at: (text as NSString).range(of: needle).location + offset, effectiveRange: nil) as? NSColor
        }
        func isBold(_ needle: String) -> Bool {
            let f = storage.attribute(.font, at: (text as NSString).range(of: needle).location, effectiveRange: nil) as? NSFont
            return f?.fontDescriptor.symbolicTraits.contains(.bold) == true
        }
        XCTAssertEqual(color("Title"), Highlighter.keywordColor)
        XCTAssertTrue(isBold("bold"))
        XCTAssertEqual(color("`code`"), Highlighter.stringColor)
        XCTAssertEqual(color("link"), .linkColor)
        XCTAssertEqual(color("let"), Highlighter.keywordColor)
        XCTAssertEqual(color("1\n```"), Highlighter.numberColor)
        XCTAssertEqual(color("- item"), Highlighter.keywordColor)
        XCTAssertEqual(color("Some"), .textColor)
    }

    func testHighlightsInjectedLanguages() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        func color(_ storage: NSTextStorage, _ needle: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: needle).location, effectiveRange: nil) as? NSColor
        }
        let typst = NSTextStorage(string: "Text\n```sql\nSELECT name FROM t -- c\n```\n```md\n# Head\n```\n```cobol\nMOVE\n```\n")
        Highlighter.apply(to: typst, font: font)
        XCTAssertEqual(color(typst, "SELECT"), Highlighter.keywordColor)
        XCTAssertEqual(color(typst, "name"), .textColor)
        XCTAssertEqual(color(typst, "-- c"), Highlighter.commentColor)
        XCTAssertEqual(color(typst, "Head"), Highlighter.keywordColor)
        XCTAssertEqual(color(typst, "MOVE"), Highlighter.stringColor)

        let markdown = NSTextStorage(string: "```py\ndef f(): return 1\n```\n\n````typ\n```js\nlet x\n```\n````\n")
        MarkdownHighlighter.apply(to: markdown, font: font)
        XCTAssertEqual(color(markdown, "def"), Highlighter.keywordColor)
        XCTAssertEqual(color(markdown, "f()"), Highlighter.functionColor)
        XCTAssertEqual(color(markdown, "1\n"), Highlighter.numberColor)
        XCTAssertEqual(color(markdown, "let"), Highlighter.keywordColor)
    }

    func testHighlightsSolvengCode() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        func color(_ storage: NSTextStorage, _ needle: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: needle).location, effectiveRange: nil) as? NSColor
        }
        let tagged = NSTextStorage(string: "```solveng\nI := 30 mA // load\n```\nPlain `U = 5 V`\n")
        Highlighter.apply(to: tagged, font: font)
        XCTAssertEqual(color(tagged, "30"), Highlighter.numberColor)
        XCTAssertEqual(color(tagged, "mA"), Highlighter.unitColor)
        XCTAssertEqual(color(tagged, "// load"), Highlighter.commentColor)
        // Inline code is never solveng.
        XCTAssertEqual(color(tagged, "5 V"), Highlighter.stringColor)

        // By default math in a worksheet is coloured like solveng code.
        let math = NSTextStorage(string: "#show: worksheet\n$I := 30 mA$\n")
        Highlighter.apply(to: math, font: font)
        XCTAssertEqual(color(math, "30"), Highlighter.numberColor)
        XCTAssertEqual(color(math, "mA"), Highlighter.unitColor)
        XCTAssertEqual(color(math, "I :="), Highlighter.paramColor)

        // The strings of solveng's calls are calculations too.
        let call = NSTextStorage(string: "#worksheet(\"t := Q0 / I = [h]\")\n")
        Highlighter.apply(to: call, font: font)
        XCTAssertEqual(color(call, "Q0"), Highlighter.paramColor)
        XCTAssertEqual(color(call, "h]"), Highlighter.unitColor)
    }

    func testSolvengResultsAreBold() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // The = and -> that show a result stand out as in Mathcad; = in a definition or a step doesn't.
        let storage = NSTextStorage(string: "#show: worksheet\n$t := Q_0/I = 1 h$ $V := 2 A = 2000 mA$ $x^2 = 4 -> solve(x)$\n")
        Highlighter.apply(to: storage, font: font)
        let s = storage.string as NSString
        func isBold(_ needle: String, from: String) -> Bool {
            let at = s.range(of: from).location + (from as NSString).range(of: needle).location
            let font = storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont
            return font?.fontDescriptor.symbolicTraits.contains(.bold) == true
        }
        XCTAssertTrue(isBold("= 1 h", from: "= 1 h$"))
        XCTAssertTrue(isBold("->", from: "-> solve"))
        XCTAssertFalse(isBold("=", from: "= 2000"))
        XCTAssertTrue(isBold(":=", from: ":= Q_0"))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: s.range(of: "solve(").location, effectiveRange: nil) as? NSColor,
                       Highlighter.keywordColor)
    }

    func testSolvengCompilerReportWins() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // The text says math is calculated, the compiler saw it with integration "none" in this file.
        let report = #"{"blocks":1,"elements":[{"path":"main.typ","start":17,"end":28,"text":"$I := 30 mA$","kind":"math","active":false,"integration":"none"}],"defined":[],"units":[]}"#
        let storage = NSTextStorage(string: "#show: worksheet\n$I := 30 mA$\n")
        Highlighter.apply(to: storage, font: font,
                          solvengContext: SolvengSupport.context(files: [], report: report, path: "main.typ", main: true))
        let s = storage.string as NSString
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: s.range(of: "30").location, effectiveRange: nil) as? NSColor,
                          Highlighter.numberColor)
    }

    func testSolvengSettingsFromTheFilesAround() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // A chapter of a main file whose worksheet calculates math.
        let chapter = NSTextStorage(string: "Plain $U := 5 V$\n")
        Highlighter.apply(to: chapter, font: font, solvengContext: "#show: worksheet\n#include \"chapter.typ\"")
        let s = chapter.string as NSString
        XCTAssertEqual(chapter.attribute(.foregroundColor, at: s.range(of: "5").location, effectiveRange: nil) as? NSColor,
                       Highlighter.numberColor)
    }

    func testConcealsSolvengCode() {
        // DeltaT is a name of its own; Delta_T is the letter with an index
        // A prefix goes with Omega glued, k""Omega, whose empty string hides
        let text = "```solveng\nDelta_T := 2 k\"\"Omega -> mA\nDeltaT := 1\n```\n$Omega$"
        let shown = Highlighter.conceals(in: text)
        let s = text as NSString
        XCTAssertEqual(shown.map { s.substring(with: $0.range) }, ["Delta", "\"", "\"", "Omega", "Omega"])
        XCTAssertEqual(shown.map { Character(UnicodeScalar($0.replacement)!) }, ["Δ", "\0", "\0", "Ω", "Ω"])
    }
}
