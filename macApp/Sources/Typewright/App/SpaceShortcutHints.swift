import AppKit
import Observation

@MainActor @Observable
final class SpaceShortcutHints {
    private(set) var visible = false
    var enabled = false {
        didSet { refresh() }
    }
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var pendingReveal: Task<Void, Never>?
    private let delay: Duration
    private let modifiers: () -> NSEvent.ModifierFlags
    private let applicationIsActive: () -> Bool

    init(delay: Duration = .milliseconds(350), modifiers: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
         applicationIsActive: @escaping () -> Bool = { NSApp.isActive }) {
        self.delay = delay
        self.modifiers = modifiers
        self.applicationIsActive = applicationIsActive
    }

    func start(in window: NSWindow?) {
        stop()
        self.window = window
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.refresh(modifiers: event.modifierFlags)
            return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willMiniaturizeNotification,
                     NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification] {
            observe(name, object: window, gainingFocus: false)
        }
        for name in [NSApplication.willResignActiveNotification, NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            observe(name, object: NSApp, gainingFocus: false)
        }
        observe(NSWindow.didBecomeKeyNotification, object: window, gainingFocus: true)
        observe(NSWindow.didEndSheetNotification, object: window, gainingFocus: true)
        observe(NSApplication.didBecomeActiveNotification, object: NSApp, gainingFocus: true)
        refresh()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        window = nil
        hide()
    }

    func refresh(modifiers: NSEvent.ModifierFlags? = nil) {
        guard shouldShow(modifiers: modifiers ?? self.modifiers()) else { hide(); return }
        guard !visible, pendingReveal == nil else { return }
        if delay == .zero { visible = true; return }
        let delay = delay
        pendingReveal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingReveal = nil
            self.visible = self.shouldShow(modifiers: self.modifiers())
        }
    }

    private func shouldShow(modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        return enabled && window?.isKeyWindow == true && window?.attachedSheet == nil && applicationIsActive() && flags == .command
    }

    private func hide() {
        pendingReveal?.cancel()
        pendingReveal = nil
        visible = false
    }

    private func observe(_ name: Notification.Name, object: AnyObject, gainingFocus: Bool) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if gainingFocus { self?.refresh() } else { self?.hide() }
            }
        })
    }

    deinit {
        pendingReveal?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
