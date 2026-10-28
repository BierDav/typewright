import AppKit
import XCTest
@testable import Typewright

@MainActor
final class WindowMoveAreaTests: XCTestCase {
    func testHiddenSidebarExposesMoveAreaAtTopOfDetail() async throws {
        let controller = MainWindowController(space: nil)
        controller.state.sidebarVisible = false
        controller.showWindow(nil)
        defer { controller.close() }
        try await Task.sleep(for: .milliseconds(300))
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let point = NSPoint(x: content.bounds.midX,
                            y: content.isFlipped ? content.bounds.minY + 10 : content.bounds.maxY - 10)
        let target = content.hitTest(content.convert(point, to: content.superview))
        XCTAssertTrue(target is WindowMoveArea.MoveView, "The exposed top strip must receive double-clicks")
    }

    func testDoubleClickZoomsWithoutStartingWindowDrag() throws {
        let window = MoveWindow()
        window.isReleasedWhenClosed = false
        let view = WindowMoveArea.MoveView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        window.contentView = view
        defer { window.close() }

        for count in 1...2 {
            view.mouseDown(with: try event(.leftMouseDown, count: count))
            view.mouseUp(with: try event(.leftMouseUp, count: count))
        }

        XCTAssertEqual(window.zoomCount, 1)
        XCTAssertTrue(window.drags.isEmpty)
    }

    func testHiddenSidebarDoubleClickThroughWindowEventRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("note.txt")
        try "Some text".write(to: file, atomically: true, encoding: .utf8)
        let controller = MainWindowController(space: root, file: file)
        controller.state.sidebarVisible = false
        controller.showWindow(nil)
        defer {
            controller.state.workspace?.close()
            controller.close()
            try? FileManager.default.removeItem(at: root)
        }
        try await Task.sleep(for: .milliseconds(300))
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let point = content.convert(NSPoint(x: content.bounds.midX,
                                           y: content.isFlipped ? content.bounds.minY + 10 : content.bounds.maxY - 10), to: nil)
        let delegate = ZoomDelegate()
        window.delegate = delegate
        defer { window.delegate = controller }

        for count in 1...2 {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                           eventNumber: 0, clickCount: count, pressure: 1))
                window.sendEvent(event)
            }
        }

        XCTAssertEqual(delegate.zoomCount, 1)
    }

    func testDraggingWaitsForMovementAndDoesNotZoom() throws {
        let window = MoveWindow()
        window.isReleasedWhenClosed = false
        let view = WindowMoveArea.MoveView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        window.contentView = view
        defer { window.close() }
        let down = try event(.leftMouseDown, count: 2)
        view.mouseDown(with: down)
        view.mouseDragged(with: try event(.leftMouseDragged, count: 2, x: 11))
        XCTAssertTrue(window.drags.isEmpty)
        view.mouseDragged(with: try event(.leftMouseDragged, count: 2, x: 20))
        view.mouseDragged(with: try event(.leftMouseDragged, count: 2, x: 30))
        view.mouseUp(with: try event(.leftMouseUp, count: 2, x: 30))

        XCTAssertEqual(window.drags.count, 1)
        XCTAssertTrue(window.drags.first === down)
        XCTAssertEqual(window.zoomCount, 0)
    }

    private func event(_ type: NSEvent.EventType, count: Int, x: CGFloat = 10) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: count, pressure: 1))
    }

    private final class MoveWindow: NSWindow {
        var zoomCount = 0
        var drags: [NSEvent] = []

        override func performZoom(_ sender: Any?) { zoomCount += 1 }
        override func performDrag(with event: NSEvent) { drags.append(event) }
    }

    private final class ZoomDelegate: NSObject, NSWindowDelegate {
        var zoomCount = 0

        func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
            zoomCount += 1
            return false
        }
    }
}
