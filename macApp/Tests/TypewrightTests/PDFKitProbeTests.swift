import AppKit
import PDFKit
import XCTest
@testable import Typewright

/// Temporary probe for how the toolbar inset affects PDFKit's scroll range; deleted before release.
@MainActor
final class PDFKitProbeTests: XCTestCase {
    private var root: URL!
    private var compiler: BuiltinCompiler!
    private var window: NSWindow!
    private let source = "#set page(width: 400pt, height: 900pt, margin: 0pt)\nOne\n#pagebreak()\nTwo"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        compiler = BuiltinCompiler(root: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    override func tearDownWithError() throws {
        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testProbeInsets() async throws {
        let result = await compiler.compile(main: "main.typ", buffers: ["main.typ": source], format: .pdf, incremental: true)
        let pages = try XCTUnwrap(result.previewPages, result.log)
        for config in ["bottom76", "top76", "none"] {
            let preview = PreviewController()
            window.contentView = preview.view
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            preview.pendingPosition = DocumentPosition(page: 1.25, zoom: 2, pan: 0.7)
            preview.showPages(pages)
            for _ in 0..<6 { try await Task.sleep(for: .milliseconds(40)) }
            let view = preview.view
            if let scroll = view.documentView?.enclosingScrollView {
                switch config {
                case "bottom76": scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
                case "top76": scroll.contentInsets = NSEdgeInsets(top: 76, left: 0, bottom: 0, right: 0)
                default: scroll.contentInsets = NSEdgeInsets()
                }
                // Re-show so the position is restored with this inset.
                preview.pendingPosition = DocumentPosition(page: 1.25, zoom: 2, pan: 0.7)
                preview.showPages(pages)
                for _ in 0..<6 { try await Task.sleep(for: .milliseconds(40)) }
            }
            let scroll = view.documentView?.enclosingScrollView
            let clip = scroll?.contentView
            let page = try XCTUnwrap(view.document?.page(at: 1))
            let top = view.convert(NSPoint(x: 0, y: page.bounds(for: view.displayBox).maxY), from: page)
            let bottom = view.convert(NSPoint(x: 0, y: page.bounds(for: view.displayBox).minY), from: page)
            var wanted = clip?.bounds.origin ?? .zero
            wanted.y -= 40
            let constrained = clip?.constrainBoundsRect(NSRect(origin: wanted, size: clip?.bounds.size ?? .zero)).origin
            print("PROBE \(config) insets=\(String(describing: scroll?.contentInsets)) clip=\(String(describing: clip?.bounds)) "
                + "page1Top=y\(top.y) page1Bottom=y\(bottom.y) viewBounds=\(view.bounds) "
                + "wantedY=\(wanted.y) constrainedY=\(String(describing: constrained?.y)) "
                + "pos=\(String(describing: preview.position()))")
        }
    }
}
