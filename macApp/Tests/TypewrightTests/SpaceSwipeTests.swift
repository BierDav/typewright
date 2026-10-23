import AppKit
import XCTest
@testable import Typewright

@MainActor
final class SpaceSwipeTests: XCTestCase {
    private final class ScrollEvent: NSEvent {
        var host: NSWindow?
        var scrollPhase: NSEvent.Phase = []
        var momentum: NSEvent.Phase = []
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var point = NSPoint(x: 50, y: 50)

        override var window: NSWindow? { host }
        override var locationInWindow: NSPoint { point }
        override var hasPreciseScrollingDeltas: Bool { true }
        override var isDirectionInvertedFromDevice: Bool { true }
        override var scrollingDeltaX: CGFloat { dx }
        override var scrollingDeltaY: CGFloat { dy }
        override var phase: NSEvent.Phase { scrollPhase }
        override var momentumPhase: NSEvent.Phase { momentum }
    }

    private func setUpSwipe() -> (NSWindow, SpaceSwipe.SwipeView, WindowState) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let swipe = SpaceSwipe.SwipeView(frame: window.contentView!.bounds)
        let state = WindowState(space: URL(fileURLWithPath: "/test-space"))
        swipe.state = state
        swipe.width = 300
        window.contentView = swipe
        return (window, swipe, state)
    }

    func testHorizontalGestureAndMomentumAreConsumedFromTheFirstDelta() {
        let (window, swipe, state) = setUpSwipe()
        defer { window.close() }
        let event = ScrollEvent()
        event.host = window
        event.scrollPhase = .began
        event.dx = 1
        event.dy = 0.5
        XCTAssertNil(swipe.handle(event))
        event.scrollPhase = .changed
        XCTAssertNil(swipe.handle(event))
        XCTAssertNil(state.swipe)
        event.dx = 30
        XCTAssertNil(swipe.handle(event))
        XCTAssertGreaterThan(state.swipe ?? 0, 0)
        event.scrollPhase = .ended
        XCTAssertNil(swipe.handle(event))
        XCTAssertTrue(state.spacesOpen)
        event.scrollPhase = []
        event.momentum = .began
        XCTAssertNil(swipe.handle(event))
        event.momentum = .ended
        XCTAssertNil(swipe.handle(event))
    }

    func testVerticalGestureStillReachesTheFileTree() {
        let (window, swipe, state) = setUpSwipe()
        defer { window.close() }
        let event = ScrollEvent()
        event.host = window
        event.scrollPhase = .began
        event.dx = 0.5
        event.dy = 1
        XCTAssertNotNil(swipe.handle(event))
        event.scrollPhase = .changed
        event.dy = 30
        XCTAssertNotNil(swipe.handle(event))
        XCTAssertNil(state.swipe)
        event.scrollPhase = .ended
        XCTAssertNotNil(swipe.handle(event))
        event.momentum = .began
        XCTAssertNotNil(swipe.handle(event))
        XCTAssertFalse(state.spacesOpen)
    }

    func testHorizontalGestureInTheOtherDirectionDoesNotScrollTheTree() {
        let (window, swipe, state) = setUpSwipe()
        defer { window.close() }
        let event = ScrollEvent()
        event.host = window
        event.scrollPhase = .began
        event.dx = -20
        event.dy = 1
        XCTAssertNil(swipe.handle(event))
        event.scrollPhase = .changed
        XCTAssertNil(swipe.handle(event))
        XCTAssertNil(state.swipe)
        event.scrollPhase = .ended
        XCTAssertNil(swipe.handle(event))
        XCTAssertFalse(state.spacesOpen)
    }
}
