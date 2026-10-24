import AppKit

struct WindowSession: Codable {
    var space: URL?
    var file: URL?
    var workspace: SpaceState?
    var sidebarVisible: Bool?
    /// The window's frame outside full screen.
    var frame: String?
    /// The display it was on, by its UUID.
    var screen: String?
    /// `frame` as fractions of that display's visible area, to place the window alike on another display.
    var area: String?
    var fullScreen: Bool?

    init(space: URL?) {
        self.space = space
    }

    @MainActor init(controller: MainWindowController) {
        let state = controller.state
        space = state.space
        file = state.pendingFile
        workspace = state.workspace?.session().state ?? state.pendingSession?.state
        sidebarVisible = state.sidebarVisible
        guard let window = controller.window else { return }
        let display = window.screen
        screen = display?.uuid
        var windowed = window.frame
        if window.styleMask.contains(.fullScreen), let display {
            if window.frame.width < display.frame.width - 1 {
                // One side of a split view; there's no way back into one, so it becomes the same tile.
                windowed = Self.rect(Self.fractions(of: window.frame, in: display.frame), in: display.visibleFrame)
            } else {
                fullScreen = true
                windowed = controller.windowedFrame ?? window.frame
            }
        }
        frame = NSStringFromRect(windowed)
        if let display { area = NSStringFromRect(Self.fractions(of: windowed, in: display.visibleFrame)) }
    }

    /// Where the window goes: its frame on its own display, or the same part of the main display if that's gone.
    @MainActor func placement() -> NSRect? {
        let saved = frame.map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 }
        if let id = screen, let display = NSScreen.screens.first(where: { $0.uuid == id }), let saved {
            return saved.intersection(display.frame).isEmpty ? Self.fit(saved, in: display.visibleFrame) : saved
        }
        if let area = area.map(NSRectFromString), !area.isEmpty, let display = NSScreen.main {
            return Self.rect(area, in: display.visibleFrame)
        }
        // Sessions saved before displays were kept.
        guard let saved else { return nil }
        let display = NSScreen.screens.first { $0.frame.intersects(saved) } ?? NSScreen.main
        return display.map { Self.fit(saved, in: $0.visibleFrame) } ?? saved
    }

    private static func fractions(of rect: NSRect, in bounds: NSRect) -> NSRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return NSRect(x: (rect.minX - bounds.minX) / bounds.width, y: (rect.minY - bounds.minY) / bounds.height,
                      width: rect.width / bounds.width, height: rect.height / bounds.height)
    }

    private static func rect(_ fractions: NSRect, in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX + fractions.minX * bounds.width, y: bounds.minY + fractions.minY * bounds.height,
               width: fractions.width * bounds.width, height: fractions.height * bounds.height).integral
    }

    /// Keeps the size where it fits and moves the window fully onto `bounds`.
    private static func fit(_ rect: NSRect, in bounds: NSRect) -> NSRect {
        let width = min(rect.width, bounds.width), height = min(rect.height, bounds.height)
        return NSRect(x: min(max(rect.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(rect.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
    }
}

extension NSScreen {
    /// Stable across launches and reconnections, unlike the display number.
    var uuid: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
