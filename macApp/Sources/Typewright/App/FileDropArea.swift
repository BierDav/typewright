import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class FileDragSession {
    static let shared = FileDragSession()
    private(set) var urls: [URL] = []
    var isDragging: Bool { !urls.isEmpty }
    func begin(_ urls: [URL]) { self.urls = urls }
    func end() { urls = [] }

}

@MainActor
final class FileDropReceiver {
    static let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, filenames]
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var onMove: (CGPoint) -> Void = { _ in }
    var onExit: () -> Void = {}
    var onDrop: ([URL], CGPoint, Bool) -> Void = { _, _, _ in }

    func update(_ sender: any NSDraggingInfo, in view: NSView, modifiers: NSEvent.ModifierFlags? = nil) -> NSDragOperation {
        let urls = files(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        FileDragSession.shared.begin(urls)
        onMove(view.convert(sender.draggingLocation, from: nil))
        return operation(for: sender, modifiers: modifiers)
    }

    func accepts(_ sender: any NSDraggingInfo) -> Bool {
        !files(on: sender.draggingPasteboard).isEmpty && !operation(for: sender).isEmpty
    }

    func perform(_ sender: any NSDraggingInfo, in view: NSView, modifiers: NSEvent.ModifierFlags? = nil) -> Bool {
        let urls = files(on: sender.draggingPasteboard)
        let operation = operation(for: sender, modifiers: modifiers)
        guard !urls.isEmpty, !operation.isEmpty else { return false }
        onDrop(urls, view.convert(sender.draggingLocation, from: nil), (modifiers ?? modifierFlags()).contains(.option))
        onExit()
        FileDragSession.shared.end()
        return true
    }

    private func operation(for sender: any NSDraggingInfo, modifiers: NSEvent.ModifierFlags? = nil) -> NSDragOperation {
        let allowed = sender.draggingSourceOperationMask
        if (modifiers ?? modifierFlags()).contains(.option) {
            if allowed.contains(.copy) { return .copy }
            return allowed.contains(.generic) ? .generic : []
        }
        if allowed.contains(.move) { return .move }
        if allowed.contains(.generic) { return .generic }
        return allowed.contains(.copy) ? .copy : []
    }

    private func files(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map { ($0 as NSURL).filePathURL ?? $0 } }
        if let paths = pasteboard.propertyList(forType: Self.filenames) as? [String] {
            return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        if let value = pasteboard.string(forType: .URL), let url = URL(string: value), url.isFileURL {
            return [(url as NSURL).filePathURL ?? url]
        }
        return []
    }
}

@MainActor
protocol FileDropReceiving {
    var receiver: FileDropReceiver { get }
}

/// Keeps Finder drops on the native ancestor of the sidebar's controls and move areas.
struct FileDropArea<Content: View>: NSViewRepresentable {
    var id = "fileDropArea"
    let onMove: (CGPoint) -> Void
    let onExit: () -> Void
    let onDrop: ([URL], CGPoint, Bool) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> DropView { DropView(rootView: content()) }

    func updateNSView(_ view: DropView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(id)
        view.receiver.onMove = onMove
        view.receiver.onExit = onExit
        view.receiver.onDrop = onDrop
        withTransaction(context.transaction) { view.rootView = content() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DropView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class DropView: NSHostingView<Content>, FileDropReceiving {
        let receiver = FileDropReceiver()

        required init(rootView: Content) {
            super.init(rootView: rootView)
            sizingOptions = []
            registerForDraggedTypes(FileDropReceiver.types)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(convert(point, from: superview)) else { return nil }
            return super.hitTest(point)
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { receiver.update(sender, in: self) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { receiver.update(sender, in: self) }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { receiver.onExit() }
        override func draggingEnded(_ sender: any NSDraggingInfo) { receiver.onExit(); FileDragSession.shared.end() }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { receiver.accepts(sender) }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { receiver.perform(sender, in: self) }
    }
}

/// AppKit tracks the entire card even when its pointer is over a native child view.
struct SidebarHoverRegion: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrackingView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
