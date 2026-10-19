import AppKit
import SwiftUI

/// Marks a SwiftUI overlay where the AppKit text and PDF views underneath must show `cursor`.
struct CursorArea: NSViewRepresentable {
    var cursor: NSCursor = .arrow

    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) { view.cursor = cursor }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AreaView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    @MainActor private static let areas = NSHashTable<AreaView>.weakObjects()

    /// The cursor of the area under the event's location, if any.
    @MainActor static func cursor(for event: NSEvent) -> NSCursor? {
        guard let window = event.window else { return nil }
        return areas.allObjects.first { area in
            area.window === window && !area.isHiddenOrHasHiddenAncestor
                && area.convert(area.bounds, to: nil).contains(event.locationInWindow)
        }?.cursor
    }

    final class AreaView: NSView {
        var cursor: NSCursor = .arrow

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

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
