import AppKit
import XCTest
@testable import Typewright

@MainActor
final class ConcealTests: XCTestCase {
    func testConstructorDisplayStaysCollapsedWhileTypingWithAStaleReport() async throws {
        let equation = "$y := op(\"tri\")(x) + 1unit(\"km\") $"
        let prefix = "#show: worksheet\n"
        let report: [String: Any] = ["blocks": 1, "elements": [[
            "path": "main.typ", "start": prefix.utf16.count, "end": prefix.utf16.count + equation.utf16.count,
            "text": equation, "kind": "math", "active": true, "evaluate": true,
        ]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self)
        var context = SolvengSupport.context(files: [], report: json, path: "main.typ", main: true)
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = prefix + equation
        tv.solvengContext = { context }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        func check() {
            let expected = tv.string.replacingOccurrences(of: "op(\"tri\")", with: "tri")
                .replacingOccurrences(of: "unit(\"km\")", with: "km")
                .replacingOccurrences(of: "\n", with: "?")
            XCTAssertEqual(shown(tv), expected)
        }
        check()
        for addition in [" +", " 1", "(", ")"] {
            let at = (tv.string as NSString).length - 1
            tv.setSelectedRange(NSRange(location: at, length: 0))
            tv.insertText(addition, replacementRange: tv.selectedRange())
            check()
            await Task.yield()
            check()
        }
        let name = (tv.string as NSString).range(of: "$y")
        tv.setSelectedRange(NSRange(location: name.location + 1, length: 1))
        tv.insertText("longer", replacementRange: tv.selectedRange())
        check()
        await Task.yield()
        check()
        let boxes = tv.collapsedSegmentBoxes(in: tv.bounds).map(\.box)
        context = SolvengSupport.context(files: [], report: "{\"blocks\":1,\"elements\":[]}", path: "main.typ", main: true)
        tv.refreshConceals()
        check()
        XCTAssertEqual(tv.collapsedSegmentBoxes(in: tv.bounds).map(\.box), boxes)
        let constructor = (tv.string as NSString).range(of: "op(\"tri\")")
        tv.setSelectedRange(NSRange(location: constructor.location + 5, length: 0))
        XCTAssertTrue(shown(tv).contains("op(\"tri\")"))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        check()
    }

    func testUnsupportedReplacementHasNoCollapsedSourceMarker() throws {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.font = font
        tv.string = "$ triangle + Omega + arrow.r.double + integral.cont $"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        let unsupported = try XCTUnwrap(tv.conceals.first { conceal in
            guard conceal.replacement != 0 else { return false }
            var character = conceal.replacement
            var glyph: CGGlyph = 0
            return !CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) || glyph == 0
        })
        let boxes = tv.collapsedSegmentBoxes(in: tv.bounds)
        XCTAssertFalse(boxes.contains { NSIntersectionRange($0.range, unsupported.range).length > 0 })
        let spelling = (tv.string as NSString).substring(with: unsupported.range)
        XCTAssertTrue(shown(tv).contains(spelling))
    }

    func testSingleCharacterReplacementHasCollapsedSourceMarker() throws {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$ a - b $"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        let minus = (tv.string as NSString).range(of: "-")
        XCTAssertTrue(tv.collapsedSegmentBoxes(in: tv.bounds).contains { $0.range == minus })
        tv.setSelectedRange(NSRange(location: minus.location, length: 0))
        XCTAssertFalse(tv.collapsedSegmentBoxes(in: tv.bounds).contains { $0.range == minus })
    }

    func testUnchangedFunctionAliasHasNoCollapsedSourceMarker() throws {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = NSFont(name: "JetBrainsMono-Regular", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "#let triangle = math.op(\"tri\")\n$t := triangle(x) $"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        let alias = (tv.string as NSString).range(of: "triangle(x)")
        XCTAssertTrue(shown(tv).contains("triangle(x)"))
        XCTAssertFalse(tv.collapsedSegmentBoxes(in: tv.bounds).contains { NSIntersectionRange($0.range, alias).length > 0 })
        let box = try XCTUnwrap(tv.highlightBoxes(for: NSRange(location: alias.location, length: 8)).first)
        XCTAssertNil(tv.collapsedSegment(at: NSPoint(x: box.midX, y: box.midY)))
    }

    func testBindingHashCollapsesIntoItsName() throws {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "#import units: cm\n#let inch = unit($2.54 #cm$)\n#show: worksheet\n$1#inch =$"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        let source = tv.string as NSString
        let reference = source.range(of: "#inch", options: .backwards)
        let segment = try XCTUnwrap(tv.collapsedSegmentBoxes(in: tv.bounds).first { $0.range == reference })
        // The marker spans the shown name, not just the hidden `#`.
        let name = try XCTUnwrap(tv.highlightBoxes(for: NSRange(location: reference.location + 1, length: 4)).first)
        XCTAssertEqual(segment.box.width, name.width, accuracy: 0.5)
        XCTAssertGreaterThan(segment.box.width, 0)
        tv.setSelectedRange(NSRange(location: NSMaxRange(reference) - 1, length: 0))
        XCTAssertFalse(tv.collapsedSegments.contains(reference))
    }

    func testCollapsedIndicatorsFollowVisiblePieces() throws {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$ Omega + \"km\" $"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        let source = tv.string as NSString
        let omega = source.range(of: "Omega")
        let quoted = source.range(of: "\"km\"")
        XCTAssertEqual(tv.collapsedSegments, [omega, quoted])
        let boxes = tv.collapsedSegmentBoxes(in: tv.bounds)
        XCTAssertEqual(boxes.map(\.range), [omega, quoted])
        let box = try XCTUnwrap(boxes.first?.box)
        let point = NSPoint(x: box.midX, y: box.midY)
        XCTAssertEqual(tv.collapsedSegment(at: point), omega)
        XCTAssertNil(tv.collapsedSegment(at: NSPoint(x: 500, y: point.y)))
        XCTAssertTrue(tv.collapsedSourceTooltip(for: quoted).contains("\"km\""))
        XCTAssertFalse(tv.collapsedSourceTooltip(for: quoted).contains("Option"))
        tv.setSelectedRange(NSRange(location: omega.location + 1, length: 0))
        XCTAssertEqual(tv.collapsedSegments, [quoted])
        XCTAssertNil(tv.collapsedSegment(at: point))
        tv.concealsMath = false
        XCTAssertTrue(tv.collapsedSegmentBoxes(in: tv.bounds).isEmpty)
    }

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

    func testHighlightBoxesFollowVisibleGlyphsAndRevealedNames() throws {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        tv.string = "$ \"pytagoras\"(a) + Omega $"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        let source = tv.string as NSString
        let quoted = source.range(of: "\"pytagoras\"")
        let letters = source.range(of: "pytagoras")
        let omega = source.range(of: "Omega")
        let lm = tv.layoutManager!, container = tv.textContainer!
        lm.ensureLayout(for: container)
        XCTAssertEqual(tv.highlightBoxes(for: quoted), tv.highlightBoxes(for: letters))
        let collapsed = try XCTUnwrap(tv.highlightBoxes(for: omega).first)
        let symbol = lm.boundingRect(forGlyphRange: lm.glyphRange(
            forCharacterRange: NSRange(location: omega.location, length: 1), actualCharacterRange: nil), in: container)
        XCTAssertEqual(collapsed.width, symbol.width, accuracy: 0.01)
        tv.setSelectedRange(NSRange(location: quoted.location + 2, length: 0))
        tv.updateRevealedEquation()
        lm.ensureLayout(for: container)
        let revealed = try XCTUnwrap(tv.highlightBoxes(for: quoted).first)
        let inner = try XCTUnwrap(tv.highlightBoxes(for: letters).first)
        XCTAssertGreaterThan(revealed.width, inner.width)
        tv.setSelectedRange(NSRange(location: omega.location + 2, length: 0))
        tv.updateRevealedEquation()
        lm.ensureLayout(for: container)
        XCTAssertGreaterThan(try XCTUnwrap(tv.highlightBoxes(for: omega).first).width, collapsed.width)
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

    func testInlineConstructorsRevealAsAWhole() {
        for constructor in ["unit(\"km\")", "unit(\"Omega\")", "op(\"tri\")"] {
            let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
            tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            tv.string = "#show: worksheet\n$y := 1" + constructor + "$"
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.concealsMath = true
            let range = (tv.string as NSString).range(of: constructor)
            let collapsed = shown(tv)
            XCTAssertFalse(collapsed.contains("unit("))
            XCTAssertFalse(collapsed.contains("op("))
            for offset in range.location...NSMaxRange(range) {
                tv.setSelectedRange(NSRange(location: offset, length: 0))
                XCTAssertTrue(shown(tv).contains(constructor), "\(constructor) at \(offset)")
            }
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            XCTAssertEqual(shown(tv), collapsed)
        }
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

    func testSelectionRevealsThePieceItTouches() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a Omega b$"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        XCTAssertEqual(shown(tv), "$a ? b$")
        // Dragging into Omega keeps the endpoints where they are and uncollapses it.
        tv.setSelectedRange(NSRange(location: 1, length: 4))
        tv.updateRevealedEquation()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 1, length: 4), "the selection isn't snapped to the piece")
        XCTAssertEqual(shown(tv), "$a Omega b$")
        // Leaving it again collapses it.
        tv.setSelectedRange(NSRange(location: 1, length: 1))
        tv.updateRevealedEquation()
        XCTAssertEqual(shown(tv), "$a ? b$")
        // Inside the uncollapsed piece every character selects.
        tv.setSelectedRange(NSRange(location: 4, length: 3))
        tv.updateRevealedEquation()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 3))
        XCTAssertEqual(shown(tv), "$a Omega b$")
    }

    func testShrinkingADragCollapsesPiecesBeforeMouseUp() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a Omega b$"
        tv.concealsMath = true
        tv.setSelectedRanges([NSValue(range: NSRange(location: 1, length: 4))],
                             affinity: .downstream, stillSelecting: true)
        XCTAssertEqual(shown(tv), "$a Omega b$")
        for end in 4...7 {
            let proposed = NSRange(location: 1, length: end - 1)
            XCTAssertEqual(tv.selectionRange(forProposedRange: proposed, granularity: .selectByCharacter), proposed)
            tv.setSelectedRanges([NSValue(range: proposed)], affinity: .downstream, stillSelecting: true)
            XCTAssertEqual(tv.selectedRange(), proposed)
        }
        tv.setSelectedRanges([NSValue(range: NSRange(location: 1, length: 1))],
                             affinity: .downstream, stillSelecting: true)
        XCTAssertEqual(shown(tv), "$a ? b$", "leaving the piece collapses it before mouse-up")
        XCTAssertEqual(shown(tv), "$a ? b$")
    }

    func testShrinkingADragKeepsOnlyTheSymbolsItStillTouches() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a Omega Gamma b$"
        tv.concealsMath = true
        func select(_ location: Int, _ length: Int) {
            tv.setSelectedRanges([NSValue(range: NSRange(location: location, length: length))],
                                 affinity: .downstream, stillSelecting: true)
        }
        select(1, 13)
        XCTAssertEqual(shown(tv), "$a Omega Gamma b$")
        select(1, 7)
        XCTAssertEqual(shown(tv), "$a Omega ? b$")
        select(4, 11)
        XCTAssertEqual(shown(tv), "$a Omega Gamma b$")
        select(10, 5)
        XCTAssertEqual(shown(tv), "$a ? Gamma b$", "shrinking from the other side collapses Omega")
        select(14, 1)
        XCTAssertEqual(shown(tv), "$a ? ? b$")
    }

    func testMouseDragCanEndInsideAnExpandedSymbol() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = tv
        // Without a window on screen its number is 0 and the tracker never sees the posted drags.
        window.makeKeyAndOrderFront(nil)
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a Omega b$"
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.concealsMath = true
        let lm = tv.layoutManager!, container = tv.textContainer!
        func point(_ index: Int) -> NSPoint {
            lm.ensureLayout(for: container)
            let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                                                  actualCharacterRange: nil), in: container)
            return tv.convert(NSPoint(x: rect.minX + tv.textContainerOrigin.x,
                                      y: rect.midY + tv.textContainerOrigin.y), to: nil)
        }
        let start = point(1), collapsedEnd = point(8)
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        let middle = point(5)
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        func event(_ type: NSEvent.EventType, at location: NSPoint, number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: number, clickCount: 1, pressure: 1)!
        }
        // One event per tracking-loop tick; a slow runner may not have consumed a whole queue by mouse-up.
        var ticks = 0
        let timer = Timer(timeInterval: 0.025, repeats: true) { timer in
            MainActor.assumeIsolated {
                ticks += 1
                switch ticks {
                case 1: NSApp.postEvent(event(.leftMouseDragged, at: collapsedEnd, number: 2), atStart: false)
                case 2: NSApp.postEvent(event(.leftMouseDragged, at: middle, number: 3), atStart: false)
                default:
                    NSApp.postEvent(event(.leftMouseUp, at: middle, number: 4), atStart: false)
                    timer.invalidate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        tv.mouseDown(with: event(.leftMouseDown, at: start, number: 1))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 1, length: 4))
    }

    func testShrinkingAColumnDragCollapsesNamesBeforeMouseUp() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a Omega b$\n$c Omega d$"
        tv.concealsMath = true
        tv.setColumns([.init(anchor: 1, head: 4), .init(anchor: 12, head: 16)], primary: 1)
        XCTAssertEqual(tv.selectedRange(), tv.columnCarets[1].range)
        for _ in 0..<4 {
            tv.setColumns([.init(anchor: 1, head: 2), .init(anchor: 12, head: 13)], primary: 0)
            XCTAssertEqual(shown(tv), "$a ? b$?$c ? d$")
            tv.setColumns([.init(anchor: 1, head: 4), .init(anchor: 12, head: 16)], primary: 1)
            XCTAssertEqual(shown(tv), "$a Omega b$?$c Omega d$")
        }
        tv.setColumns([.init(anchor: 1, head: 2), .init(anchor: 12, head: 13)], primary: 0)
        XCTAssertEqual(shown(tv), "$a ? b$?$c ? d$", "both collapse while the mouse is still down")
        XCTAssertEqual(shown(tv), "$a ? b$?$c ? d$")
    }

    func testCaretEntersPiecesAtTheHiddenQuote() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a \"abc\" b$"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.concealsMath = true
        tv.moveRight(nil)
        XCTAssertEqual(tv.selectedRange().location, 3, "in front of the invisible opening quote")
        tv.updateRevealedEquation()
        tv.moveRight(nil)
        XCTAssertEqual(tv.selectedRange().location, 4, "shown as typed, one character at a time")
        // A click where the piece starts lands where it lands, not snapped in front of the hidden quote.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.updateRevealedEquation()
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 4)
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
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
                       Highlighter.operatorFont(size: 13), "the start keeps the ligature")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
                       Highlighter.operatorFont(size: 13), "so does the end")
        tv.setSelectedRange(NSRange(location: 3, length: 2))
        tv.updateRevealedEquation()
        XCTAssertEqual(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
                       Highlighter.operatorFont(size: 13), "a selection over it doesn't break it")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.updateRevealedEquation()
        XCTAssertEqual(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
                       Highlighter.operatorFont(size: 13))
        XCTAssertTrue(tv.conceals.isEmpty)
    }

    func testColumnSelectionBreaksOperatorsOnlyBetweenTheirCharacters() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = "$x -> y$\n$x -> y$"
        let storage = tv.textStorage!
        Highlighter.apply(to: storage, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        func font() -> NSFont? { storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont }
        tv.setColumns([.init(anchor: 3, head: 5), .init(anchor: 12, head: 14)], primary: 0)
        XCTAssertEqual(font(), Highlighter.operatorFont(size: 13), "endpoints at the edges keep it")
        tv.setColumns([.init(anchor: 3, head: 4), .init(anchor: 12, head: 13)], primary: 0)
        XCTAssertEqual(font(), Highlighter.operatorFont(size: 13, ligatures: false),
                       "an endpoint between the characters breaks it")
    }

    func testDraggingExpandsOperatorsOnlyWhileAnEndpointIsInside() {
        let cases: [(NSRange, Bool)] = [
            (NSRange(location: 0, length: 4), true),
            (NSRange(location: 0, length: 7), false),
            (NSRange(location: 4, length: 3), true),
            (NSRange(location: 3, length: 2), false),
            (NSRange(location: 4, length: 0), true),
            (NSRange(location: 3, length: 0), false),
            (NSRange(location: 5, length: 0), false),
        ]
        for op in ["->", ":="] {
            let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            tv.string = "$x \(op) y$\n$x \(op) y$"
            let storage = tv.textStorage!
            Highlighter.apply(to: storage, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            for (range, expanded) in cases {
                tv.setSelectedRanges([NSValue(range: range)], affinity: .downstream, stillSelecting: true)
                XCTAssertEqual(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
                               Highlighter.operatorFont(size: 13, ligatures: !expanded), "\(op): \(range)")
            }
            for (range, expanded) in cases {
                tv.setColumns([.init(anchor: range.location, head: NSMaxRange(range)),
                               .init(anchor: range.location + 9, head: NSMaxRange(range) + 9)], primary: 1)
                for index in [3, 12] {
                    XCTAssertEqual(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont,
                                   Highlighter.operatorFont(size: 13, ligatures: !expanded), "\(op): \(range)")
                }
            }
        }
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

    func testColumnDragExpandsTheMathItTouches() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a Omega b$\n$c Omega d$"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        let lm = tv.layoutManager!, container = tv.textContainer!
        lm.ensureLayout(for: container)
        func box(_ range: NSRange) -> NSRect {
            lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        }
        let origin = tv.textContainerOrigin
        let start = NSPoint(x: box(NSRange(location: 1, length: 1)).minX + origin.x,
                            y: box(NSRange(location: 1, length: 1)).midY + origin.y)
        // Inside the collapsed Omega on the second line.
        let omega = box(NSRange(location: 15, length: 5))
        let end = NSPoint(x: omega.minX + omega.width * 0.75 + origin.x, y: omega.midY + origin.y)
        var previous: [NSRange] = []
        for i in 0..<4 {
            let found = tv.columnCarets(from: start, to: end)
            tv.setColumns(found.carets, primary: found.primary)
            XCTAssertEqual(shown(tv), "$a Omega b$?$c Omega d$",
                           "the columns uncollapse what they touch while dragging")
            XCTAssertEqual(tv.selectedRange(), tv.columnCarets[tv.primaryColumn].range)
            // The first pass reveals them; after that the layout is settled.
            if i >= 2 { XCTAssertEqual(tv.columnCarets.map(\.range), previous) }
            previous = tv.columnCarets.map(\.range)
        }
    }

    func testColumnHitTestingStaysStableNearHiddenOpeningQuotes() {
        for (step, delta) in (-40...80).flatMap({ step in [-0.4, -0.2, 0, 0.2, 0.4].map { (step, $0) } }) {
            let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
            tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            tv.string = "#worksheet(\n  $ \"pytagoras\"(a, b) $\n  $ \"circle\"(x, r) $\n  $ r := 3 $\n)"
            Highlighter.apply(to: tv.textStorage!, font: tv.font!)
            tv.concealsMath = true
            let lm = tv.layoutManager!, container = tv.textContainer!
            lm.ensureLayout(for: container)
            let source = tv.string as NSString
            func box(_ text: String) -> NSRect {
                lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: source.range(of: text),
                                                           actualCharacterRange: nil), in: container)
            }
            let letter = box("p"), top = box("#"), bottom = box("r :=")
            let width = ("M" as NSString).size(withAttributes: [.font: tv.font!]).width
            let x = letter.minX + CGFloat(step) * width / 40 + tv.textContainerOrigin.x
            let start = NSPoint(x: x, y: top.midY + tv.textContainerOrigin.y)
            let end = NSPoint(x: x + CGFloat(delta) * width, y: bottom.midY + tv.textContainerOrigin.y)
            var history: [[NSRange]] = []
            for _ in 0..<6 {
                let found = tv.columnCarets(from: start, to: end)
                tv.setColumns(found.carets, primary: found.primary)
                history.append(tv.columnCarets.map(\.range))
            }
            XCTAssertEqual(history[4], history[5], "step \(step), delta \(delta): \(history)")
        }
    }

    func testColumnDragRevealsQuotesOnlyAfterCrossingTheirMidpoint() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$ \"p\" $\n$ \"p\" $"
        Highlighter.apply(to: tv.textStorage!, font: tv.font!)
        tv.concealsMath = true
        let lm = tv.layoutManager!, container = tv.textContainer!
        lm.ensureLayout(for: container)
        func box(_ index: Int) -> NSRect {
            lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                                       actualCharacterRange: nil), in: container)
        }
        let first = box(3), last = box(11), origin = tv.textContainerOrigin
        let width = ("M" as NSString).size(withAttributes: [.font: tv.font!]).width
        let start = NSPoint(x: first.minX - width + origin.x, y: first.midY + origin.y)
        for fraction in [0.25, 0.75, 0.25, 0.75] {
            let end = NSPoint(x: first.minX + fraction * width + origin.x, y: last.midY + origin.y)
            for _ in 0..<4 {
                let found = tv.columnCarets(from: start, to: end)
                tv.setColumns(found.carets, primary: found.primary)
                XCTAssertEqual(shown(tv).contains("\""), fraction > 0.5,
                               "the quotes must stay stable on either side of the midpoint")
            }
        }
    }

    func testRegularMouseDragCanStopBeforeAnOpeningQuote() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        window.contentView = tv
        window.makeKeyAndOrderFront(nil)
        tv.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        tv.string = "$ \"pytagoras\"(a, b) $"
        Highlighter.apply(to: tv.textStorage!, font: tv.font!)
        tv.concealsMath = true
        let lm = tv.layoutManager!, container = tv.textContainer!
        lm.ensureLayout(for: container)
        func point(_ index: Int) -> NSPoint {
            let box = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                                                 actualCharacterRange: nil), in: container)
            return NSPoint(x: box.minX + tv.textContainerOrigin.x, y: box.midY + tv.textContainerOrigin.y)
        }
        let start = point(0), letter = point(3)
        let width = ("M" as NSString).size(withAttributes: [.font: tv.font!]).width
        let end = NSPoint(x: letter.x + width / 4, y: letter.y)
        func event(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: tv.convert(point, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        var history: [NSRange] = []
        var ticks = 0
        let timer = Timer(timeInterval: 0.025, repeats: true) { timer in
            MainActor.assumeIsolated {
                history.append(tv.selectedRange())
                window.displayIfNeeded()
                ticks += 1
                if ticks < 9 {
                    NSApp.postEvent(event(.leftMouseDragged, point: end), atStart: false)
                } else {
                    NSApp.postEvent(event(.leftMouseUp, point: end), atStart: false)
                    timer.invalidate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        tv.mouseDown(with: event(.leftMouseDown, point: start))
        XCTAssertEqual(history.count, 9)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 2))
        XCTAssertFalse(shown(tv).contains("\""))
        XCTAssertTrue(history.suffix(3).allSatisfy { $0 == NSRange(location: 0, length: 2) }, "\(history)")
    }

    func testRegularDragHitTestingStaysStableAtHiddenQuotes() {
        for fraction in [-0.25, 0, 0.25, 0.49, 0.51, 0.75] {
            let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
            tv.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            tv.string = "$ \"pytagoras\"(a, b) $"
            Highlighter.apply(to: tv.textStorage!, font: tv.font!)
            tv.concealsMath = true
            let lm = tv.layoutManager!, container = tv.textContainer!
            lm.ensureLayout(for: container)
            let letter = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: 3, length: 1),
                                                                    actualCharacterRange: nil), in: container)
            let width = ("M" as NSString).size(withAttributes: [.font: tv.font!]).width
            let point = NSPoint(x: letter.minX + fraction * width + tv.textContainerOrigin.x,
                                y: letter.midY + tv.textContainerOrigin.y)
            var history: [NSRange] = []
            for _ in 0..<8 {
                let head = tv.characterIndexForInsertion(at: point)
                let proposed = NSRange(location: 0, length: head)
                let range = tv.selectionRange(forProposedRange: proposed, granularity: .selectByCharacter)
                tv.setSelectedRanges([NSValue(range: range)], affinity: .downstream, stillSelecting: true)
                lm.ensureLayout(for: container)
                history.append(tv.selectedRange())
            }
            XCTAssertEqual(history[6], history[7], "fraction \(fraction): \(history)")
        }
    }

    func testColumnDragExpandsSolvengNames() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "```solveng\nDelta_T := 2\nDelta_T := 3\n```"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        let lm = tv.layoutManager!, container = tv.textContainer!
        lm.ensureLayout(for: container)
        // `shown` draws line breaks as `?` too.
        let drawn = "```solveng??_T := 2??_T := 3?```"
        XCTAssertEqual(shown(tv), drawn)
        func box(_ index: Int) -> NSRect {
            lm.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container)
        }
        // From the start of Delta on the first line to after it on the second.
        let start = NSPoint(x: box(11).minX + tv.textContainerOrigin.x, y: box(11).midY + tv.textContainerOrigin.y)
        let end = NSPoint(x: box(29).minX + tv.textContainerOrigin.x, y: box(29).midY + tv.textContainerOrigin.y)
        let found = tv.columnCarets(from: start, to: end)
        tv.setColumns(found.carets, primary: found.primary)
        XCTAssertEqual(tv.columnCarets.map(\.range), [NSRange(location: 11, length: 5), NSRange(location: 24, length: 5)],
                       "the drag covers both names")
        XCTAssertEqual(shown(tv), "```solveng?Delta_T := 2?Delta_T := 3?```",
                       "the names uncollapse while the drag is still going")
    }

    func testColumnSelectsIntoAPieceAndUncollapsesIt() {
        let tv = TypstTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = "$a Omega b$\n$c Omega d$"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.concealsMath = true
        XCTAssertEqual(shown(tv), "$a ? b$?$c ? d$")
        // The endpoints stay inside the collapsed names instead of snapping to them whole.
        tv.setColumns([.init(anchor: 1, head: 4), .init(anchor: 12, head: 16)], primary: 0)
        XCTAssertEqual(tv.columnCarets.map(\.range), [NSRange(location: 1, length: 3), NSRange(location: 12, length: 4)])
        XCTAssertEqual(shown(tv), "$a Omega b$?$c Omega d$", "touching them uncollapses them")
        // Moving off them collapses them again.
        tv.setColumns([.init(anchor: 1, head: 2), .init(anchor: 12, head: 13)], primary: 0)
        XCTAssertEqual(shown(tv), "$a ? b$?$c ? d$")
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

    func testClosingMathDoesNotInsertAnotherDollar() {
        for source in ["$rect(t)", "$x + ", "$ x + 1 ", "$\n  x + 1\n", "😀 $rect(t)", "$x$ and $rect(t)"] {
            let tv = editor(source, caret: (source as NSString).length)
            type(tv, "$")
            XCTAssertEqual(tv.string, source + "$", source)
            XCTAssertEqual(tv.selectedRange().location, (source as NSString).length + 1)
        }
        let closed = editor("$rect(t)$", caret: 8)
        type(closed, "$")
        XCTAssertEqual(closed.string, "$rect(t)$")
        XCTAssertEqual(closed.selectedRange().location, 9)
    }

    func testOpeningMathIgnoresDollarsInCommentsRawTextAndStrings() {
        for source in ["", "$x$ ", "\\$ ", "// $\n", "`$` ", "#let x = \"$\"\n"] {
            let tv = editor(source, caret: (source as NSString).length)
            type(tv, "$")
            XCTAssertEqual(tv.string, source + "$$", source)
        }
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
