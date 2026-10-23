import AppKit
import SwiftUI
import XCTest
@testable import Typewright

@MainActor
final class HoverPinTests: XCTestCase {
    private func shown(_ hover: HoverController) async {
        for _ in 0..<100 where !hover.isShown { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func point(at offset: Int, in tv: NSTextView) throws -> NSPoint {
        let layout = try XCTUnwrap(tv.layoutManager)
        let container = try XCTUnwrap(tv.textContainer)
        layout.ensureLayout(for: container)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: layout.glyphIndexForCharacter(at: offset), length: 1), in: container)
        return NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
    }

    func testF1DocumentsAConstantNextToItsCoefficient() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        let document = "#show: worksheet\n$1e^10$"
        tv.string = document
        let at = (document as NSString).range(of: "e^").location
        let hover = HoverController(textView: tv)
        hover.provider = { offset in
            guard let docs = SolvengSupport.hover(document, context: "", offset: offset) else { return nil }
            return (docs.markdown, NSRange(location: docs.start, length: docs.end - docs.start))
        }
        for caret in [at, at + 1] {
            tv.setSelectedRange(NSRange(location: caret, length: 0))
            hover.toggleAtCaret()
            await shown(hover)
            let content = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
            XCTAssertTrue(content.rootView.markdown?.contains("Euler") == true)
            XCTAssertTrue(content.rootView.errors.isEmpty)
            hover.hide()
        }
    }

    func testF1DocumentsOnlyTheSymbolTheCaretTouches() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        let document = "#show: worksheet\n$1e-10 + pi + e$"
        tv.string = document
        let hover = HoverController(textView: tv)
        hover.provider = { offset in
            guard let docs = SolvengSupport.hover(document, context: "", offset: offset) else { return nil }
            return (docs.markdown, NSRange(location: docs.start, length: docs.end - docs.start))
        }
        func noDocs(at caret: Int) async {
            tv.setSelectedRange(NSRange(location: caret, length: 0))
            hover.toggleAtCaret()
            for _ in 0..<100 where hover.isPinned { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(hover.isShown, "caret \(caret)")
        }
        // Between the minus and the exponent: e is across the operator.
        let minus = (document as NSString).range(of: "-").location
        await noDocs(at: minus + 1)
        // After the space: pi is across it.
        let pi = (document as NSString).range(of: "pi").location
        await noDocs(at: pi + 3)
        // At the end of pi, where the caret touches it.
        tv.setSelectedRange(NSRange(location: pi + 2, length: 0))
        hover.toggleAtCaret()
        await shown(hover)
        let content = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
        XCTAssertTrue(content.rootView.markdown?.contains("3,14159") == true)
        hover.hide()
    }

    func testHoverIgnoresASymbolThePointerIsNotOn() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        let document = "#show: worksheet\n$1e-10$"
        tv.string = document
        let hover = HoverController(textView: tv)
        hover.provider = { offset in
            guard let docs = SolvengSupport.hover(document, context: "", offset: offset) else { return nil }
            return (docs.markdown, NSRange(location: docs.start, length: docs.end - docs.start))
        }
        // On the minus sign: e is next to it, but not under the pointer.
        let minus = (document as NSString).range(of: "-").location
        hover.pointerMoved(to: try point(at: minus, in: tv))
        try? await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(hover.isShown)
        // On e, where the pointer is.
        let e = (document as NSString).range(of: "1e-").location + 1
        hover.pointerMoved(to: try point(at: e, in: tv))
        await shown(hover)
        let content = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
        XCTAssertTrue(content.rootView.markdown?.contains("Euler") == true)
        hover.hide()
    }

    func testF1ShowsOnlyDocumentationEvenWhenDiagnosticsChange() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        tv.string = "$few$"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        let hover = HoverController(textView: tv)
        let problems = [Diagnostic.Severity.error, .warning].map {
            (range: NSRange(location: 0, length: 5), diagnostic: Diagnostic(path: "main.typ", line: 1, column: 2,
                                                                        severity: $0, message: "Problem", length: 3))
        }
        hover.diagnostics = problems
        hover.provider = { _ in ("Docs", NSRange(location: 1, length: 3)) }
        hover.toggleAtCaret()
        await shown(hover)
        let content = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
        XCTAssertEqual(content.rootView.markdown, "Docs")
        XCTAssertTrue(content.rootView.errors.isEmpty)
        hover.diagnostics = Array(problems.reversed())
        XCTAssertTrue(content.rootView.errors.isEmpty)
        hover.hide()
        hover.provider = nil
        hover.toggleAtCaret()
        for _ in 0..<100 where hover.isPinned { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(hover.isShown)
        hover.hide()
    }

    func testF1PinsAndHidesTheDocs() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        tv.string = "#text(\"hi\")"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        let hover = HoverController(textView: tv)
        hover.provider = { _ in ("Docs", NSRange(location: 1, length: 4)) }

        hover.toggleAtCaret()
        XCTAssertTrue(hover.isPinned, "pinned while the docs load")
        await shown(hover)
        XCTAssertTrue(hover.isShown)
        // Moving the pointer away leaves pinned docs alone.
        hover.pointerMoved(to: NSPoint(x: 390, y: 290))
        hover.pointerExited()
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(hover.isShown)

        hover.toggleAtCaret()
        XCTAssertFalse(hover.isShown)
        XCTAssertFalse(hover.isPinned)

        // Any other key closes them, shortcuts too; Esc goes no further.
        for (key, flags, swallowed) in [("k", NSEvent.ModifierFlags.command, false), ("a", [], false), ("\u{1b}", [], true)] {
            hover.toggleAtCaret()
            await shown(hover)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                                         keyCode: key == "\u{1b}" ? 53 : 0)!
            XCTAssertEqual(hover.handle(event) == nil, swallowed, key)
            XCTAssertFalse(hover.isShown, key)
        }
    }

    func testF1HidesHoveredDocsAndAClickPinsThem() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        tv.string = "#text(\"hi\")"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        let hover = HoverController(textView: tv)
        hover.provider = { _ in ("Docs", NSRange(location: 1, length: 4)) }

        // F1 hides docs at once, whether the shortcut reaches the text view or the watcher.
        hover.toggleAtCaret()
        await shown(hover)
        let f1 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0, windowNumber: window.windowNumber,
                                  context: nil, characters: String(UnicodeScalar(NSF1FunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSF1FunctionKey)!),
                                  isARepeat: false, keyCode: 122)!
        if KeyLayout.current.shortcuts.documentation.matches(f1) {
            XCTAssertNil(hover.handle(f1))
            XCTAssertFalse(hover.isShown)
            hover.toggleAtCaret()
            await shown(hover)
        }
        hover.toggleAtCaret()
        XCTAssertFalse(hover.isShown)
    }

    func testErrorsArrivingWhileDocsLoadAreShownAndRetained() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        tv.string = "$few$"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        let hover = HoverController(textView: tv)
        var pending: CheckedContinuation<(markdown: String, range: NSRange?)?, Never>?
        hover.provider = { _ in await withCheckedContinuation { pending = $0 } }
        hover.pointerMoved(to: try point(at: 1, in: tv))
        for _ in 0..<100 where pending == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let continuation = try XCTUnwrap(pending)
        let error = Diagnostic(path: "main.typ", line: 1, column: 2, severity: .error, message: "unknown variable: few", length: 3)
        hover.diagnostics = [(NSRange(location: 0, length: 5), error)]
        XCTAssertTrue(hover.isShown)
        let early = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
        XCTAssertEqual(early.rootView.errors.map(\.message), [error.message])
        continuation.resume(returning: ("Docs", NSRange(location: 1, length: 3)))
        for _ in 0..<100 {
            if (window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)?.rootView.markdown == "Docs" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let content = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
        XCTAssertEqual(content.rootView.errors.map(\.message), [error.message])
        XCTAssertEqual(content.rootView.markdown, "Docs")
        XCTAssertFalse(hover.isPinned)
        hover.hide()
    }

    func testErrorsArrivingWhileDocsAreOpenAppearInTheSameHover() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        tv.string = "$few$"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        let hover = HoverController(textView: tv)
        hover.provider = { _ in ("Docs", NSRange(location: 1, length: 3)) }
        hover.pointerMoved(to: try point(at: 1, in: tv))
        await shown(hover)
        let panel = try XCTUnwrap(window.childWindows?.last)
        let error = Diagnostic(path: "main.typ", line: 1, column: 2, severity: .error, message: "unknown variable: few", length: 3)
        hover.diagnostics = [(NSRange(location: 0, length: 5), error)]
        let content = try XCTUnwrap(panel.contentView as? PopupHostingView<HoverContent>)
        XCTAssertEqual(content.rootView.errors.map(\.message), [error.message])
        XCTAssertEqual(content.rootView.markdown, "Docs")
        XCTAssertFalse(hover.isPinned)
        XCTAssertTrue(window.childWindows?.last === panel)
        hover.diagnostics = []
        XCTAssertTrue(content.rootView.errors.isEmpty)
        XCTAssertEqual(content.rootView.markdown, "Docs")
        hover.hide()
    }

    func testCompilerErrorsHoverInTheHostedEditor() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        let error = Diagnostic(path: "main.typ", line: 1, column: 2, severity: .error, message: "unknown variable: few", length: 3)
        let editor = CodeEditor(documentID: 1, text: "$few$\n#few()", fontSize: 14, highlights: true,
                                diagnostics: [error], reveal: nil, state: nil, topInset: 24, onChange: { _, _ in }, onStateChange: { _ in })
        window.contentView = NSHostingView(rootView: editor)
        window.contentView?.layoutSubtreeIfNeeded()
        func findTextView(_ view: NSView) -> TypstTextView? {
            if let tv = view as? TypstTextView { return tv }
            return view.subviews.lazy.compactMap(findTextView).first
        }
        var found: TypstTextView?
        for _ in 0..<100 {
            found = window.contentView.flatMap(findTextView)
            if found != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let tv = try XCTUnwrap(found)
        let layout = try XCTUnwrap(tv.layoutManager)
        let container = try XCTUnwrap(tv.textContainer)
        layout.ensureLayout(for: container)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: layout.glyphIndexForCharacter(at: 2), length: 1), in: container)
        tv.onPointerMoved?(NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y))
        for _ in 0..<100 where window.childWindows?.isEmpty != false { try? await Task.sleep(for: .milliseconds(10)) }
        let content = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
        XCTAssertEqual(content.rootView.errors.map(\.message), [error.message])
        tv.onDismissHover?()
    }

    func testErrorsAtTheTopHoverWithViewsBelowTheEditor() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let error = Diagnostic(path: "main.typ", line: 1, column: 2, severity: .error, message: "unknown variable: few", length: 3)
        let editor = CodeEditor(documentID: 1, text: "$few$\n#few()", fontSize: 14, highlights: true,
                                diagnostics: [error], reveal: nil, state: nil, topInset: 24, onChange: { _, _ in }, onStateChange: { _ in })
        // Like the status bar: the flipped hosting view mirrored the point onto it.
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) { editor; Button("Bar") {}.frame(maxWidth: .infinity, minHeight: 200) })
        window.contentView?.layoutSubtreeIfNeeded()
        func findTextView(_ view: NSView) -> TypstTextView? {
            if let tv = view as? TypstTextView { return tv }
            return view.subviews.lazy.compactMap(findTextView).first
        }
        var found: TypstTextView?
        for _ in 0..<100 {
            found = window.contentView.flatMap(findTextView)
            if found != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let tv = try XCTUnwrap(found)
        tv.onPointerMoved?(try point(at: 2, in: tv))
        for _ in 0..<100 where window.childWindows?.isEmpty != false { try? await Task.sleep(for: .milliseconds(10)) }
        let content = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
        XCTAssertEqual(content.rootView.errors.map(\.message), [error.message])
        tv.onDismissHover?()
    }

    func testErrorsWithDocsStayWhileMovingAlongTheLine() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        let text = "#text(fill: rgb(\"zz\"))[x]"
        tv.string = text
        let hover = HoverController(textView: tv)
        let call = (text as NSString).range(of: "rgb")
        hover.diagnostics = [(NSRange(location: 0, length: text.utf16.count),
                              Diagnostic(path: "main.typ", line: 1, column: 17, severity: .error, message: "bad color", length: 4))]
        hover.provider = { NSLocationInRange($0, call) ? ("Docs", call) : nil }
        hover.pointerMoved(to: try point(at: call.location + 1, in: tv))
        for _ in 0..<100 {
            if (window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)?.rootView.markdown == "Docs" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let panel = try XCTUnwrap(window.childWindows?.last)
        hover.pointerMoved(to: try point(at: 1, in: tv))
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.childWindows?.last === panel)
        hover.hide()
    }

    func testErrorHoverCoversTheLineIncludingConcealedMathAndWhitespace() async throws {
        for concealed in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            let tv = TypstTextView(frame: window.contentView!.bounds)
            window.contentView!.addSubview(tv)
            tv.string = "$few$\nText"
            tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
            tv.concealsMath = concealed
            let hover = HoverController(textView: tv)
            hover.diagnostics = [(NSRange(location: 0, length: 5),
                                  Diagnostic(path: "main.typ", line: 1, column: 2, severity: .error, message: "unknown variable: few", length: 3))]
            var requestedDocs = false
            hover.provider = { _ in requestedDocs = true; return nil }
            let layout = try XCTUnwrap(tv.layoutManager)
            let container = try XCTUnwrap(tv.textContainer)
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: 2)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            for x in [rect.midX, CGFloat(150)] {
                requestedDocs = false
                hover.pointerMoved(to: NSPoint(x: x + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y))
                await shown(hover)
                XCTAssertTrue(hover.isShown, "concealed: \(concealed), x: \(x)")
                let content = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
                XCTAssertEqual(content.rootView.errors.first?.message, "unknown variable: few")
                if x == 150 { XCTAssertFalse(requestedDocs, "whitespace must not request unrelated symbol docs") }
                hover.hide()
            }
        }
    }

    func testTextViewRequestsPointerMovementForHover() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        tv.updateTrackingAreas()
        let tracking = try XCTUnwrap(tv.trackingAreas.first { $0.owner === tv && $0.options.contains(.mouseMoved) })
        XCTAssertTrue(tracking.options.contains(.mouseEnteredAndExited))
        var points: [NSPoint] = []
        tv.onPointerMoved = { points.append($0) }
        for type in [NSEvent.EventType.mouseEntered, .mouseMoved] {
            let point = NSPoint(x: 10, y: 20)
            let event = try XCTUnwrap(type == .mouseMoved
                ? NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                : NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            if type == .mouseEntered { tv.mouseEntered(with: event) } else { tv.mouseMoved(with: event) }
            XCTAssertEqual(points.last, tv.convert(point, from: nil))
        }
        XCTAssertEqual(points.count, 2)
    }

    func testDiagnosticsAppearBeforeDocumentationLoads() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        tv.string = "$1 V + 2 s =$"
        let hover = HoverController(textView: tv)
        let diagnostic = Diagnostic(path: "main.typ", line: 1, column: 2, severity: .error, message: "adding different units: s and V")
        hover.diagnostics = [(NSRange(location: 0, length: tv.string.utf16.count), diagnostic)]
        var pending: CheckedContinuation<(markdown: String, range: NSRange?)?, Never>?
        hover.provider = { _ in await withCheckedContinuation { pending = $0 } }
        hover.pointerMoved(to: try point(at: 1, in: tv))
        await shown(hover)
        XCTAssertTrue(hover.isShown, "errors must not wait for the language server")
        XCTAssertFalse(hover.isPinned)
        let panel = try XCTUnwrap(window.childWindows?.last)
        let content = try XCTUnwrap(panel.contentView as? PopupHostingView<HoverContent>)
        XCTAssertEqual(content.rootView.errors.map(\.message), [diagnostic.message])
        XCTAssertNil(content.rootView.markdown)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        _ = hover.handle(click)
        XCTAssertTrue(hover.isPinned)
        try XCTUnwrap(pending).resume(returning: ("Docs", NSRange(location: 1, length: 1)))
        for _ in 0..<100 {
            if (window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)?.rootView.markdown == "Docs" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let updated = try XCTUnwrap(window.childWindows?.last?.contentView as? PopupHostingView<HoverContent>)
        XCTAssertEqual(updated.rootView.errors.map(\.message), [diagnostic.message])
        XCTAssertEqual(updated.rootView.markdown, "Docs")
        XCTAssertTrue(hover.isPinned)
        hover.hide()
    }

    func testDismissedDiagnosticDoesNotReopenWhenDocumentationArrives() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = TypstTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(tv)
        tv.string = "$1 V + 2 s =$"
        let hover = HoverController(textView: tv)
        hover.diagnostics = [(NSRange(location: 0, length: tv.string.utf16.count),
                              Diagnostic(path: "main.typ", line: 1, column: 1, severity: .error, message: "incompatible units"))]
        var pending: CheckedContinuation<(markdown: String, range: NSRange?)?, Never>?
        hover.provider = { _ in await withCheckedContinuation { pending = $0 } }
        hover.pointerMoved(to: try point(at: 1, in: tv))
        await shown(hover)
        XCTAssertTrue(hover.isShown)
        hover.hide()
        try XCTUnwrap(pending).resume(returning: ("Docs", NSRange(location: 0, length: 1)))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(hover.isShown)
        XCTAssertFalse(hover.isPinned)
    }

    func testTrailStepsBack() async {
        let trail = DocsTrail()
        XCTAssertFalse(trail.back())
        let docs = FunctionDocs(markdown: "```typc\nlet f(x) = any;\n```")!
        trail.follow(docs)
        XCTAssertEqual(trail.pages.count, 1)
        XCTAssertTrue(trail.back())
        for _ in 0..<100 where trail.canGoBack { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(trail.canGoBack)
        XCTAssertFalse(trail.forward)
    }
}
