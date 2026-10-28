import AppKit
import XCTest
@testable import Typewright

@MainActor
final class SidebarDropTests: XCTestCase {
    func testFinderDragRevealsHiddenSidebarAndDropsIntoSpace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-drop-\(UUID().uuidString)")
        let source = root.appendingPathComponent("finder.txt")
        let space = root.appendingPathComponent("Space")
        try FileManager.default.createDirectory(at: space, withIntermediateDirectories: true)
        try "Finder file".write(to: source, atomically: true, encoding: .utf8)
        try "= Main".write(to: space.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        for folder in ["A/Child", "B"] {
            try FileManager.default.createDirectory(at: space.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let controller = MainWindowController(space: space)
        defer {
            FileDragSession.shared.end()
            controller.state.workspace?.close()
            controller.close()
            try? FileManager.default.removeItem(at: root)
        }
        controller.state.sidebarVisible = false
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        func hitTest(_ point: NSPoint) -> NSView? {
            content.hitTest(content.convert(point, to: content.superview))
        }
        func edge(in view: NSView) -> SidebarDropEdge.DropView? {
            if let edge = view as? SidebarDropEdge.DropView { return edge }
            return view.subviews.lazy.compactMap { edge(in: $0) }.first
        }
        let deadline = Date().addingTimeInterval(5)
        while edge(in: content) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        content.layoutSubtreeIfNeeded()
        let destination = try XCTUnwrap(edge(in: content))
        destination.receiver.modifierFlags = { [] }
        XCTAssertTrue(destination.registeredDraggedTypes.contains(.fileURL))
        XCTAssertGreaterThan(destination.bounds.height, 0)
        let point = destination.convert(NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: content)
        XCTAssertTrue(hitTest(point) === destination)
        let drag = FinderDrag(source: source, window: window)
        XCTAssertEqual(destination.draggingEntered(drag), .move)
        XCTAssertTrue(controller.state.floatingSidebar)
        XCTAssertFalse(controller.state.sidebarVisible)
        try await Task.sleep(for: .milliseconds(300))
        func find(_ view: NSView, matching predicate: @escaping (NSView) -> Bool) -> NSView? {
            if predicate(view) { return view }
            return view.subviews.lazy.compactMap { find($0, matching: predicate) }.first
        }
        let tree = try XCTUnwrap(find(content) { $0.identifier?.rawValue == "floatingFileTreeDrop" })
        try XCTUnwrap(tree as? any FileDropReceiving).receiver.modifierFlags = { [] }
        let moveArea = try XCTUnwrap(find(tree) { $0 is WindowMoveArea.MoveView })
        let blank = moveArea.convert(NSPoint(x: moveArea.bounds.midX, y: moveArea.bounds.maxY - 40), to: content)
        var target = hitTest(blank)
        while let view = target, !view.registeredDraggedTypes.contains(.fileURL) { target = view.superview }
        XCTAssertTrue(target === tree, "Finder must reach the file tree from the native move area")
        let hover = try XCTUnwrap(find(content) { $0 is SidebarHoverRegion.TrackingView })
        XCTAssertGreaterThanOrEqual(hover.convert(hover.bounds, to: nil).maxY, content.convert(content.bounds, to: nil).maxY - 1)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        hover.mouseEntered(with: event)
        destination.draggingExited(drag)
        drag.draggingLocation = tree.convert(content.convert(blank, to: tree), to: nil)
        XCTAssertEqual(tree.draggingEntered(drag), .move)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.state.floatingSidebar)
        tree.draggingExited(drag)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.state.floatingSidebar, "The move region still contains the pointer")
        let footer = try XCTUnwrap(find(content) { $0.identifier?.rawValue == "floatingFileFooterDrop" })
        let footerPoint = footer.convert(NSPoint(x: footer.bounds.midX, y: footer.bounds.midY), to: content)
        var footerTarget = hitTest(footerPoint)
        while let view = footerTarget, !view.registeredDraggedTypes.contains(.fileURL) { footerTarget = view.superview }
        XCTAssertTrue(footerTarget === footer, "Footer target: \(footerTarget?.identifier?.rawValue ?? "none"), footer \(footer.frame), tree \(tree.frame)")
        let selection = controller.state.workspace?.selectedFile

        let workspace = try XCTUnwrap(controller.state.workspace)
        func location(over folder: URL) -> NSPoint {
            func rows(_ nodes: [FileNode]) -> [FileNode] {
                nodes.flatMap { node in
                    [node] + (workspace.expanded.contains(node.url) ? rows(node.children ?? []) : [])
                }
            }
            let index = rows(workspace.tree).firstIndex { $0.url == folder }!
            return tree.convert(NSPoint(x: 30, y: CGFloat(index) * 36 + 21), to: nil)
        }
        let first = space.appendingPathComponent("A"), second = space.appendingPathComponent("B")
        drag.draggingLocation = location(over: first)
        XCTAssertEqual(tree.draggingUpdated(drag), .move)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(workspace.expanded.contains(first))
        drag.draggingLocation = location(over: second)
        XCTAssertEqual(tree.draggingUpdated(drag), .move)
        XCTAssertFalse(workspace.expanded.contains(first), "Leaving a spring-opened folder must collapse it")
        drag.draggingLocation = location(over: second)
        XCTAssertEqual(tree.draggingUpdated(drag), .move)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(workspace.expanded.contains(second))
        XCTAssertTrue(tree.prepareForDragOperation(drag))
        XCTAssertTrue(tree.performDragOperation(drag))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: space.appendingPathComponent("B/finder.txt"), encoding: .utf8), "Finder file")
        XCTAssertTrue(workspace.expanded.contains(second), "A confirmed drop keeps its destination expanded")
        XCTAssertEqual(controller.state.workspace?.selectedFile, selection)
        hover.mouseExited(with: event)
        tree.draggingEnded(drag)
        try await Task.sleep(for: .milliseconds(500))
        let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let containsPointer = hover.convert(hover.bounds, to: nil).contains(pointer)
        XCTAssertEqual(controller.state.floatingSidebar, containsPointer,
                       "An actual pointer over the card must keep it open even after a simulated exit")

        try Data("Finder file".utf8).write(to: source)
        XCTAssertEqual(destination.draggingEntered(drag), .move)
        try await Task.sleep(for: .milliseconds(300))
        let header = try XCTUnwrap(find(content) { $0.identifier?.rawValue == "floatingFileHeaderDrop" })
        try XCTUnwrap(header as? any FileDropReceiving).receiver.modifierFlags = { [] }
        XCTAssertEqual(header.draggingEntered(drag), .move)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(controller.state.spacesOpen, "The up target must spring open the space selector")
        header.draggingExited(drag)
        header.draggingEnded(drag)

    }

    func testOptionProposesNativeCopyAndCopiesOnDrop() throws {
        let window = NSWindow()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("finder-copy-\(UUID().uuidString).txt")
        try Data().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let drag = FinderDrag(source: source, window: window)
        drag.draggingSourceOperationMask = FileDragGesture.Source.operations
        let receiver = FileDropReceiver()
        receiver.modifierFlags = { [] }
        defer { FileDragSession.shared.end() }
        XCTAssertEqual(receiver.update(drag, in: view, modifiers: []), .move)
        XCTAssertEqual(receiver.update(drag, in: view, modifiers: .option), .copy)
        var copied: [URL] = []
        receiver.onDrop = { urls, _, copy in
            XCTAssertTrue(copy)
            copied = urls
        }
        XCTAssertTrue(receiver.perform(drag, in: view, modifiers: .option))
        XCTAssertEqual(copied, [source])
    }

    func testDockStackFilenamesAreAccepted() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("dock-file-\(UUID().uuidString)")
        try Data().write(to: source)
        defer { try? FileManager.default.removeItem(at: source); FileDragSession.shared.end() }
        let drag = FinderDrag(source: source, window: NSWindow())
        drag.draggingSourceOperationMask = .generic
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.setPropertyList([source.path], forType: FileDropReceiver.filenames)
        let receiver = FileDropReceiver()
        receiver.modifierFlags = { [] }
        let view = NSView()
        var dropped: [URL] = []
        receiver.onDrop = { urls, _, copy in XCTAssertFalse(copy); dropped = urls }
        XCTAssertTrue(FileDropReceiver.types.contains(FileDropReceiver.filenames))
        XCTAssertEqual(receiver.update(drag, in: view), .generic)
        XCTAssertTrue(receiver.perform(drag, in: view))
        XCTAssertEqual(dropped, [source])
    }

    func testCopyOnlySourceDoesNotTurnAnOrdinaryDropIntoACopy() throws {
        let drag = FinderDrag(source: URL(fileURLWithPath: "/tmp/source.txt"), window: NSWindow())
        drag.draggingSourceOperationMask = .copy
        let receiver = FileDropReceiver()
        receiver.modifierFlags = { [] }
        var copying: Bool?
        receiver.onDrop = { _, _, copy in copying = copy }
        XCTAssertTrue(receiver.perform(drag, in: NSView(), modifiers: []))
        XCTAssertEqual(copying, false)
    }

    @MainActor private final class FinderDrag: NSObject, @preconcurrency NSDraggingInfo {
        let draggingPasteboard = NSPasteboard.withUniqueName()
        let draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation = FileDragGesture.Source.operations
        var draggingLocation = NSPoint.zero
        let draggedImageLocation = NSPoint.zero
        let draggedImage: NSImage? = nil
        let draggingSource: Any? = nil
        let draggingSequenceNumber = 1
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(source: URL, window: NSWindow) {
            draggingDestinationWindow = window
            super.init()
            draggingPasteboard.writeObjects([source as NSURL])
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }
}
