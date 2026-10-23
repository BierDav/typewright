import AppKit
import XCTest
@testable import Typewright

@MainActor
final class SpaceShortcutHintsTests: XCTestCase {
    private final class Window: NSWindow {
        var key = true
        override var isKeyWindow: Bool { key }
    }

    func testHintsWaitBeforeAppearingAndHideImmediately() async throws {
        let window = Window()
        var flags: NSEvent.ModifierFlags = .command
        let hints = SpaceShortcutHints(delay: .milliseconds(40), modifiers: { flags }, applicationIsActive: { true })
        hints.start(in: window)
        defer { hints.stop() }
        hints.enabled = true
        XCTAssertFalse(hints.visible)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(hints.visible)
        flags = []
        hints.refresh()
        XCTAssertFalse(hints.visible)
        flags = .command
        hints.refresh()
        XCTAssertFalse(hints.visible, "each new hold waits again")
    }

    func testPendingHintsAreCancelledByReleaseFocusLossAndDismissal() async throws {
        let window = Window()
        var flags: NSEvent.ModifierFlags = .command
        let hints = SpaceShortcutHints(delay: .milliseconds(40), modifiers: { flags }, applicationIsActive: { true })
        defer { hints.stop() }
        for interruption in 0..<4 {
            flags = .command
            hints.start(in: window)
            hints.enabled = true
            XCTAssertFalse(hints.visible)
            switch interruption {
            case 0:
                flags = []
                hints.refresh()
            case 1:
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            case 2:
                hints.enabled = false
            default:
                hints.stop()
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(hints.visible, "cancelled hold \(interruption) must not appear later")
        }
    }

    func testLosingWindowOrApplicationFocusClearsHeldCommand() {
        let window = Window()
        let hints = SpaceShortcutHints(delay: .zero, modifiers: { .command }, applicationIsActive: { true })
        hints.start(in: window)
        defer { hints.stop() }
        hints.enabled = true
        for name in [NSWindow.didResignKeyNotification, NSWindow.willMiniaturizeNotification,
                     NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification] {
            hints.refresh()
            XCTAssertTrue(hints.visible)
            NotificationCenter.default.post(name: name, object: window)
            XCTAssertFalse(hints.visible, "\(name)")
        }
        for name in [NSApplication.willResignActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification] {
            hints.refresh()
            XCTAssertTrue(hints.visible)
            NotificationCenter.default.post(name: name, object: NSApp)
            XCTAssertFalse(hints.visible, "\(name)")
        }
    }

    func testReturningFocusResamplesKeysReleasedOutsideTheApp() {
        let window = Window()
        var flags: NSEvent.ModifierFlags = .command
        let hints = SpaceShortcutHints(delay: .zero, modifiers: { flags }, applicationIsActive: { true })
        hints.start(in: window)
        defer { hints.stop() }
        hints.enabled = true
        XCTAssertTrue(hints.visible)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        flags = []
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(hints.visible)
        flags = .command
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(hints.visible)
    }

    func testOnlyTheActiveOverviewInTheKeyWindowShowsCommandAlone() {
        let window = Window()
        var applicationActive = true
        let hints = SpaceShortcutHints(delay: .zero, modifiers: { .command }, applicationIsActive: { applicationActive })
        hints.start(in: window)
        defer { hints.stop() }
        XCTAssertFalse(hints.visible)
        hints.enabled = true
        XCTAssertTrue(hints.visible, "opening the overview with Command already held")
        for extra: NSEvent.ModifierFlags in [.shift, .option, .control] {
            hints.refresh(modifiers: [.command, extra])
            XCTAssertFalse(hints.visible)
        }
        hints.refresh(modifiers: [.command, .capsLock])
        XCTAssertTrue(hints.visible)
        window.key = false
        hints.refresh()
        XCTAssertFalse(hints.visible)
        window.key = true
        applicationActive = false
        hints.refresh()
        XCTAssertFalse(hints.visible)
        applicationActive = true
        hints.refresh()
        XCTAssertTrue(hints.visible)
        hints.enabled = false
        XCTAssertFalse(hints.visible, "closing the overview or showing an overlay")
        hints.enabled = true
        XCTAssertTrue(hints.visible)
    }

    func testUnmountingAndSwitchingWindowsDiscardOldObservers() {
        let first = Window(), second = Window()
        let hints = SpaceShortcutHints(delay: .zero, modifiers: { .command }, applicationIsActive: { true })
        hints.enabled = true
        hints.start(in: first)
        XCTAssertTrue(hints.visible)
        hints.stop()
        XCTAssertFalse(hints.visible)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
        XCTAssertFalse(hints.visible)
        hints.start(in: second)
        defer { hints.stop() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        XCTAssertTrue(hints.visible)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
        XCTAssertFalse(hints.visible)
    }
}
