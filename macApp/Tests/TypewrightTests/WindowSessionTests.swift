import AppKit
import XCTest
@testable import Typewright

@MainActor
final class WindowSessionTests: XCTestCase {
    private var main: NSScreen { NSScreen.main! }

    func testWindowGoesBackToItsOwnDisplay() throws {
        var session = WindowSession(space: nil)
        let frame = NSRect(x: main.visibleFrame.minX + 40, y: main.visibleFrame.minY + 30, width: 700, height: 500)
        session.frame = NSStringFromRect(frame)
        session.screen = main.uuid
        XCTAssertNotNil(session.screen)
        XCTAssertEqual(session.placement(), frame)
    }

    func testMissingDisplayKeepsTheSameTileOnTheMainDisplay() throws {
        var session = WindowSession(space: nil)
        session.frame = NSStringFromRect(NSRect(x: 90_000, y: 0, width: 1720, height: 1400))
        session.screen = "no-such-display"
        // The left half of the old display.
        session.area = NSStringFromRect(NSRect(x: 0, y: 0, width: 0.5, height: 1))
        let visible = main.visibleFrame
        let placed = try XCTUnwrap(session.placement())
        XCTAssertEqual(placed.minX, visible.minX, accuracy: 1)
        XCTAssertEqual(placed.width, visible.width / 2, accuracy: 1)
        XCTAssertEqual(placed.height, visible.height, accuracy: 1)
    }

    func testOlderSessionsLandOnAVisibleDisplay() throws {
        var session = WindowSession(space: nil)
        session.frame = NSStringFromRect(NSRect(x: 90_000, y: 90_000, width: 700, height: 500))
        let placed = try XCTUnwrap(session.placement())
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(placed) })
        XCTAssertEqual(placed.size, NSSize(width: 700, height: 500))
    }

    func testSavedSessionsWithoutDisplaysStillDecode() throws {
        let old = #"{"frame": "{{10, 20}, {700, 500}}", "sidebarVisible": true}"#
        let session = try JSONDecoder().decode(WindowSession.self, from: Data(old.utf8))
        XCTAssertNil(session.screen)
        XCTAssertNil(session.fullScreen)
    }
}
