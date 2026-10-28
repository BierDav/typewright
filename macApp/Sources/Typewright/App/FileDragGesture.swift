import AppKit
import SwiftUI

/// SwiftUI's item-provider drag source only offers copying; native sessions also allow moving.
struct FileDragGesture: NSGestureRecognizerRepresentable {
    let url: URL
    let enabled: Bool
    let onBegin: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Source { Source() }

    func makeNSGestureRecognizer(context: Context) -> NSPanGestureRecognizer {
        NSPanGestureRecognizer()
    }

    func updateNSGestureRecognizer(_ recognizer: NSPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleNSGestureRecognizerAction(_ recognizer: NSPanGestureRecognizer, context: Context) {
        guard recognizer.state == .began, let view = recognizer.view, let event = NSApp.currentEvent else { return }
        onBegin()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = recognizer.location(in: view)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: icon)
        view.beginDraggingSession(with: [item], event: event, source: context.coordinator)
    }

    final class Source: NSObject, NSDraggingSource {
        static let operations: NSDragOperation = [.copy, .move]
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            Self.operations
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            FileDragSession.shared.end()
        }
    }
}
