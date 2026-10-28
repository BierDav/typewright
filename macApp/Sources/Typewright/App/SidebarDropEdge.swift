import AppKit
import SwiftUI

/// Finder drags need a native destination over the editor's AppKit views.
struct SidebarDropEdge: NSViewRepresentable {
    let onHover: (Bool) -> Void
    let onDrop: ([URL], Bool) -> Void

    func makeNSView(context: Context) -> DropView { DropView() }

    func updateNSView(_ view: DropView, context: Context) {
        view.onHover = onHover
        view.onDrop = onDrop
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DropView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class DropView: NSView, FileDropReceiving {
        var onHover: (Bool) -> Void = { _ in }
        var onDrop: ([URL], Bool) -> Void = { _, _ in }

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes(FileDropReceiver.types)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }

        let receiver = FileDropReceiver()

        private func configureReceiver() {
            receiver.onMove = { [weak self] _ in self?.onHover(true) }
            receiver.onExit = { [weak self] in self?.onHover(false) }
            receiver.onDrop = { [weak self] urls, _, copy in self?.onDrop(urls, copy) }
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            configureReceiver()
            return receiver.update(sender, in: self)
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) { onHover(false) }
        override func draggingEnded(_ sender: any NSDraggingInfo) { onHover(false); FileDragSession.shared.end() }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { receiver.accepts(sender) }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            configureReceiver()
            return receiver.perform(sender, in: self)
        }
    }
}
