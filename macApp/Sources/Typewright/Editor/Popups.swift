import AppKit
import SwiftUI

/// Window-scoped dismissal shared by transient UI and editing tools.
@MainActor
enum Popups {
    private static let dismissal = Notification.Name("TypewrightDismissPopups")

    private final class Entry {
        weak var owner: AnyObject?
        weak var window: NSWindow?
        weak var surface: NSWindow?
        let close: (AnyObject) -> Void

        init(owner: AnyObject, window: NSWindow?, close: @escaping (AnyObject) -> Void) {
            self.owner = owner
            self.window = window
            self.close = close
        }
    }

    private enum Scope: Hashable {
        case all
        case window(ObjectIdentifier)
    }
    private static var dismissing: Set<Scope> = []
    private static var entries: [Entry] = []
    private static var trackingObservers: [any NSObjectProtocol] = []

    struct MenuCommand {
        let keys: KeyBinding
        let run: (NSWindow?) -> Void
    }
    static var menuCommands: () -> [MenuCommand] = { [] }

    @MainActor private final class MenuShortcut: NSMenuItem {
        weak var window: NSWindow?
        let run: (NSWindow?) -> Void

        init(shortcut: Shortcut, window: NSWindow?, run: @escaping (NSWindow?) -> Void) {
            self.window = window
            self.run = run
            super.init(title: "", action: #selector(invoke), keyEquivalent: String(shortcut.key.keyEquivalent.character))
            keyEquivalentModifierMask = shortcut.modifiers.nsFlags
            target = self
            isHidden = true
            allowsKeyEquivalentWhenHidden = true
        }

        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func invoke() {
            let window = window, run = run
            Popups.dismiss(in: window)
            DispatchQueue.main.async { run(window) }
        }
    }

    /// Register any transient tool without making it live longer or replacing its delegate.
    static func onDismiss<T: AnyObject>(_ owner: T, in window: NSWindow?, close: @escaping (T) -> Void) {
        remove(owner)
        entries.append(Entry(owner: owner, window: hostWindow(for: window)) { object in
            if let object = object as? T { close(object) }
        })
    }

    static func remove(_ owner: AnyObject) {
        entries.removeAll { $0.owner == nil || $0.owner === owner }
    }

    /// Native menus run their own tracking loop, which bypasses local key-event monitors.
    static func installTracking() {
        guard trackingObservers.isEmpty else { return }
        let center = NotificationCenter.default
        trackingObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let menu = note.object as? NSMenu else { return }
                    if !entries.contains(where: { $0.owner === menu }) {
                        let event = NSApp.currentEvent
                        let mouse = event?.type == .rightMouseDown || event?.type == .leftMouseDown
                        let window = mouse ? event?.window : NSApp.keyWindow ?? NSApp.mainWindow
                        onDismiss(menu, in: window) { $0.cancelTrackingWithoutAnimation() }
                    }
                    let host = entries.first { $0.owner === menu }?.window
                    for command in menuCommands() {
                        for shortcut in [command.keys.primary] + command.keys.alternates {
                            menu.addItem(MenuShortcut(shortcut: shortcut, window: host, run: command.run))
                        }
                    }
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let menu = note.object as? NSMenu else { return }
                    for item in menu.items where item is MenuShortcut { menu.removeItem(item) }
                    remove(menu)
                }
            },
            center.addObserver(forName: NSPopover.willShowNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let popover = note.object as? NSPopover,
                          !entries.contains(where: { $0.owner === popover }) else { return }
                    let event = NSApp.currentEvent
                    let mouse = event?.type == .rightMouseDown || event?.type == .leftMouseDown
                    track(popover, in: mouse ? event?.window : NSApp.keyWindow ?? NSApp.mainWindow)
                }
            },
            center.addObserver(forName: NSPopover.didShowNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let popover = note.object as? NSPopover else { return }
                    guard let entry = entries.first(where: { $0.owner === popover }) else { return }
                    entry.surface = popover.contentViewController?.view.window
                    if let parent = entry.surface?.parent { entry.window = hostWindow(for: parent) }
                }
            },
            center.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { if let popover = note.object as? NSPopover { remove(popover) } }
            },
        ]
    }

    static func track(_ popover: NSPopover, in window: NSWindow?) {
        onDismiss(popover, in: window) { $0.close() }
    }

    static func track(_ panel: NSPanel, in window: NSWindow?) {
        onDismiss(panel, in: window) { $0.close() }
        entries.first { $0.owner === panel }?.surface = panel
    }

    static func show(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
        guard !isCovered(view.window) else { return }
        onDismiss(menu, in: view.window) { $0.cancelTrackingWithoutAnimation() }
        defer { remove(menu) }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// Maps child windows and system panels back to the content they belong to.
    static func hostWindow(for window: NSWindow?) -> NSWindow? {
        guard let window else { return nil }
        if let entry = entries.last(where: { $0.owner != nil && $0.surface === window }), let host = entry.window {
            return host
        }
        if let parent = window.parent { return hostWindow(for: parent) }
        return window
    }

    static var menuWindow: NSWindow? {
        entries.last { $0.owner is NSMenu }?.window
    }

    /// Closes transient UI over `window`, or over every window for nil.
    static func dismiss(in window: NSWindow?) {
        let window = hostWindow(for: window)
        let scope = window.map { Scope.window(ObjectIdentifier($0)) } ?? .all
        guard !dismissing.contains(.all), dismissing.insert(scope).inserted else { return }
        defer { dismissing.remove(scope) }
        entries.removeAll { $0.owner == nil }
        let closing = entries.filter { window == nil || $0.window === window }
        for entry in closing.reversed() {
            if let owner = entry.owner { entry.close(owner) }
        }
        NotificationCenter.default.post(name: dismissal, object: window)
    }

    /// Keep the token while observing; the callback can also dismiss non-window tools.
    static func observe(window: @escaping @MainActor () -> NSWindow?, close: @escaping @MainActor () -> Void) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: dismissal, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let target = note.object as? NSWindow else { return close() }
                if target === hostWindow(for: window()) { close() }
            }
        }
    }

    private static var backHandlers: [(owner: () -> AnyObject?, window: () -> NSWindow?, back: () -> Bool)] = []

    /// Registers how a popup steps back for as long as `owner` lives.
    static func onBack(_ owner: AnyObject, window: @escaping () -> NSWindow?, back: @escaping () -> Bool) {
        backHandlers.removeAll { $0.owner() == nil }
        backHandlers.append(({ [weak owner] in owner }, window, back))
    }

    static func back(in window: NSWindow?) -> Bool {
        let window = hostWindow(for: window)
        return backHandlers.contains { $0.owner() != nil && hostWindow(for: $0.window()) === window && $0.back() }
    }

    static func isCovered(_ window: NSWindow?) -> Bool {
        guard let state = Opener.shared.state(for: window) else { return false }
        return state.overlay != nil || state.spacesOpen
    }
}

@MainActor
extension View {
    func dismissWithPopups(_ close: @escaping () -> Void) -> some View {
        background(PopupDismissal(close: close))
    }
}

private struct PopupDismissal: NSViewRepresentable {
    let close: () -> Void

    final class Anchor: NSView {
        var close: () -> Void = {}
        var observation: (any NSObjectProtocol)?
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.close = close
        view.observation = Popups.observe(window: { [weak view] in view?.window }) { [weak view] in view?.close() }
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) { view.close = close }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Anchor, context: Context) -> CGSize? { .zero }
}
