import AppKit
import XCTest
@testable import Typewright

@MainActor
private final class TrackedMenu: NSMenu, @unchecked Sendable {
    var cancellations = 0
    override func cancelTrackingWithoutAnimation() {
        cancellations += 1
        super.cancelTrackingWithoutAnimation()
    }
}

@MainActor
final class PopupsTests: XCTestCase {
    private final class Tool {
        var dismissals = 0
    }

    func testDismissalFollowsChildWindowsAndKeepsOtherWindowsOpen() {
        let first = NSWindow(), second = NSWindow(), child = NSPanel()
        first.addChildWindow(child, ordered: .above)
        defer { first.removeChildWindow(child) }
        let tool = Tool(), other = Tool()
        Popups.onDismiss(tool, in: child) { $0.dismissals += 1 }
        Popups.onDismiss(other, in: second) { $0.dismissals += 1 }
        defer { Popups.remove(tool); Popups.remove(other) }
        var observed = 0
        let token = Popups.observe(window: { child }) { observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        Popups.dismiss(in: child)
        XCTAssertEqual(tool.dismissals, 1)
        XCTAssertEqual(other.dismissals, 0)
        XCTAssertEqual(observed, 1)
        Popups.dismiss(in: nil)
        XCTAssertEqual(tool.dismissals, 2)
        XCTAssertEqual(other.dismissals, 1)
    }

    func testRegistrationDoesNotRetainToolsAndCanBeReplaced() {
        let window = NSWindow()
        var tool: Tool? = Tool()
        weak let weakTool = tool
        Popups.onDismiss(tool!, in: window) { $0.dismissals += 10 }
        Popups.onDismiss(tool!, in: window) { $0.dismissals += 1 }
        Popups.dismiss(in: window)
        XCTAssertEqual(tool?.dismissals, 1)
        tool = nil
        XCTAssertNil(weakTool)
        Popups.dismiss(in: window)
    }

    func testDismissalCanReenterWithoutCallingToolsTwice() {
        let window = NSWindow(), tool = Tool()
        Popups.onDismiss(tool, in: window) { tool in
            tool.dismissals += 1
            Popups.dismiss(in: window)
        }
        defer { Popups.remove(tool) }
        Popups.dismiss(in: window)
        XCTAssertEqual(tool.dismissals, 1)
    }

    func testMenusCreatedOutsideTheWrapperAreDismissed() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let menu = TrackedMenu(title: "Native Context Menu")
        menu.addItem(withTitle: "Action", action: nil, keyEquivalent: "")
        Popups.installTracking()
        var timedOut = false
        let timer = Timer(timeInterval: 0.03, repeats: false) { _ in
            MainActor.assumeIsolated { Popups.dismiss(in: nil) }
        }
        let timeout = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                timedOut = true
                menu.cancelTrackingWithoutAnimation()
            }
        }
        for timer in [timer, timeout] {
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .default)
        }
        defer { timer.invalidate(); timeout.invalidate() }
        menu.popUp(positioning: nil, at: NSPoint(x: 30, y: 40), in: window.contentView!)
        XCTAssertFalse(timedOut)
        XCTAssertGreaterThan(menu.cancellations, 0)
    }

    func testPanelShortcutsResolveToTheirOwningWindow() {
        let window = NSWindow(), panel = NSPanel()
        Popups.track(panel, in: window)
        defer { Popups.remove(panel) }
        XCTAssertTrue(Popups.hostWindow(for: panel) === window)
    }

    func testPopoverClosesThroughSharedDismissal() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let popover = NSPopover()
        popover.animates = false
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        popover.contentViewController = content
        Popups.installTracking()
        Popups.track(popover, in: window)
        popover.show(relativeTo: NSRect(x: 20, y: 20, width: 10, height: 10), of: window.contentView!, preferredEdge: .maxY)
        XCTAssertTrue(popover.isShown)
        Popups.dismiss(in: window)
        XCTAssertFalse(popover.isShown)
    }

    func testPaletteShortcutClosesNativeContextMenus() async {
        let controller = Opener.shared.newWindow()
        let window = controller.window!
        defer { window.close() }
        controller.state.overlay = nil
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        try? await Task.sleep(for: .milliseconds(30))
        let menu = TrackedMenu(title: "Context Actions")
        menu.addItem(withTitle: "Action", action: nil, keyEquivalent: "")
        Popups.installTracking()
        let key = KeyLayout.current.shortcuts.palette.primary
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers.nsFlags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: key.key.display.lowercased(), charactersIgnoringModifiers: key.key.display.lowercased(),
                    isARepeat: false, keyCode: key.key.keyCodes.first!)!
                XCTAssertTrue(Popups.menuWindow === window, "the context menu belongs to its originating window")
                XCTAssertTrue(menu.performKeyEquivalent(with: event))
            }
        }
        let timeout = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated { menu.cancelTrackingWithoutAnimation() }
        }
        for timer in [timer, timeout] {
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .default)
        }
        defer { timer.invalidate(); timeout.invalidate() }
        Popups.show(menu, at: NSPoint(x: 40, y: 80), in: window.contentView!)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(menu.numberOfItems, 1)
        XCTAssertGreaterThan(menu.cancellations, 0)
        XCTAssertEqual(controller.state.overlay, .palette())
        XCTAssertNil(Popups.menuWindow)
    }
}
