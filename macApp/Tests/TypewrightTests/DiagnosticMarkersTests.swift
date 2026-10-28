import AppKit
import XCTest
@testable import Typewright

@MainActor
final class DiagnosticMarkersTests: XCTestCase {
    private final class NotifyingLayoutManager: NSLayoutManager {
        var onLayout: (() -> Void)?
        var queries = 0

        override func lineFragmentRect(forGlyphAt glyphIndex: Int, effectiveRange: NSRangePointer?) -> NSRect {
            queries += 1
            // Bound recursion so a regression fails without overflowing the test runner's stack.
            if queries < 10 { onLayout?() }
            return NSRect(x: 0, y: 0, width: 100, height: 20)
        }
    }

    func testRefreshDefersLayoutAndCoalescesFrameNotifications() async throws {
        let storage = NSTextStorage(string: "An error")
        let layout = NotifyingLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: 1000))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.postsFrameChangedNotifications = true
        let markers = DiagnosticMarkers(textView: view)
        scroll.addSubview(markers)
        markers.diagnostics = [(NSRange(location: 0, length: 2),
                                Diagnostic(path: "main.typ", line: 1, column: 1, severity: .error, message: "Error"))]
        layout.onLayout = {
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: view)
        }
        let before = layout.queries
        for _ in 0..<10 {
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: view)
        }
        XCTAssertEqual(layout.queries, before)

        let refreshed = expectation(description: "Markers refreshed after layout")
        DispatchQueue.main.async { refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(layout.queries, before + 1)
        XCTAssertEqual(markers.layer?.sublayers?.count, 1)
    }
}
