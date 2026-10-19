import AppKit
import SwiftUI

/// Marks a SwiftUI overlay where the AppKit text and PDF views underneath must show `cursor`.
struct CursorArea: NSViewRepresentable {
    var cursor: NSCursor = .arrow
    /// Wins over every other area it overlaps, e.g. over content dimmed behind the space selector.
    var isModal = false

    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) {
        view.cursor = cursor
        view.isModal = isModal
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AreaView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    @MainActor private static let areas = NSHashTable<AreaView>.weakObjects()

    /// The cursor of the area under the event's location, if any.
    @MainActor static func cursor(for event: NSEvent) -> NSCursor? {
        guard let window = event.window else { return nil }
        let hits = areas.allObjects.filter { area in
            area.window === window && !area.isHiddenOrHasHiddenAncestor
                && area.convert(area.bounds, to: nil).contains(event.locationInWindow)
        }
        return (hits.first(where: \.isModal) ?? hits.first)?.cursor
    }

    final class AreaView: NSView {
        var cursor: NSCursor = .arrow
        var isModal = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { CursorArea.areas.add(self) } else { CursorArea.areas.remove(self) }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        // Defers to a modal area on top, whose tracking area may fire first.
        override func cursorUpdate(with event: NSEvent) { (CursorArea.cursor(for: event) ?? cursor).set() }
        override func mouseEntered(with event: NSEvent) { (CursorArea.cursor(for: event) ?? cursor).set() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
