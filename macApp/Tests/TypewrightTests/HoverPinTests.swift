import AppKit
import XCTest
@testable import Typewright

@MainActor
final class HoverPinTests: XCTestCase {
    private func shown(_ hover: HoverController) async {
        for _ in 0..<100 where !hover.isShown { try? await Task.sleep(for: .milliseconds(10)) }
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
