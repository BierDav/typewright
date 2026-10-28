import AppKit
import SwiftUI

final class SpaceWindow: NSWindow {
    private weak var moveArea: WindowMoveArea.MoveView?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            moveArea = nil
            if let area = moveArea(at: event.locationInWindow) {
                moveArea = area
                area.mouseDown(with: event)
                return
            }
        case .leftMouseDragged:
            if let moveArea {
                moveArea.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if let area = moveArea {
                moveArea = nil
                area.mouseUp(with: event)
                return
            }
        default: break
        }
        super.sendEvent(event)
    }

    func moveArea(at point: NSPoint) -> WindowMoveArea.MoveView? {
        // Leave the perimeter to AppKit's native window resizing.
        let bounds = NSRect(origin: .zero, size: frame.size)
        if styleMask.contains(.resizable), !styleMask.contains(.fullScreen),
           !bounds.insetBy(dx: 8, dy: 8).contains(point) { return nil }
        guard let content = contentView, let frame = content.superview else { return nil }
        var hit = frame.hitTest(frame.convert(point, from: nil))
        while let view = hit {
            if view is NSControl { return nil }
            hit = view.superview
        }
        // The native transparent title bar intercepts clicks before the SwiftUI content gets them.
        return content.hitTest(frame.convert(point, from: nil)) as? WindowMoveArea.MoveView
    }
}

/// Blank sidebar areas behave like the titlebar without taking clicks from controls.
struct WindowMoveArea: NSViewRepresentable {
    func makeNSView(context: Context) -> MoveView { MoveView() }
    func updateNSView(_ view: MoveView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MoveView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class MoveView: NSView {
        private var mouseDownEvent: NSEvent?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent,
                  hypot(event.locationInWindow.x - down.locationInWindow.x,
                        event.locationInWindow.y - down.locationInWindow.y) >= 3 else { return }
            mouseDownEvent = nil
            // Starting a window drag on a plain click consumes the double-click sequence.
            window?.performDrag(with: down)
        }

        override func mouseUp(with event: NSEvent) {
            guard mouseDownEvent != nil else { return }
            mouseDownEvent = nil
            if event.clickCount == 2 { window?.performZoom(nil) }
        }
    }
}
