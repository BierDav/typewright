import AppKit
import PDFKit
import XCTest
@testable import Typewright

/// Temporary probe for how PDFKit positions a destination on the runner; deleted before release.
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

    private func dump(_ label: String, _ preview: PreviewController) {
        let view = preview.view
        let scroll = view.documentView?.enclosingScrollView
        let clip = scroll?.contentView
        let dest = view.currentDestination
        let destIndex = dest?.page.flatMap { view.document?.index(for: $0) }
        let top = NSPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY)
        let pageTop = view.page(for: top, nearest: true).flatMap { view.document?.index(for: $0) }
        let topPoint = view.page(for: top, nearest: true).map { view.convert(top, to: $0) }
        print("PROBE \(label) bounds=\(view.bounds) doc=\(String(describing: view.documentView?.frame)) "
            + "clip=\(String(describing: clip?.bounds)) docRect=\(String(describing: clip?.documentRect)) "
            + "insets=\(String(describing: scroll?.contentInsets)) scale=\(view.scaleFactor) auto=\(view.autoScales) "
            + "currentDest=\(String(describing: destIndex))/\(String(describing: dest?.point)) "
            + "topPage=\(String(describing: pageTop)) topPoint=\(String(describing: topPoint)) "
            + "pos=\(String(describing: preview.position()))")
    }

    private func pump() async throws {
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(40)) }
    }

    func testProbeDestinationPlacement() async throws {
        let result = await compiler.compile(main: "main.typ", buffers: ["main.typ": source], format: .pdf, incremental: true)
        let pages = try XCTUnwrap(result.previewPages, result.log)
        let preview = PreviewController()
        window.contentView = preview.view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        preview.pendingPosition = DocumentPosition(page: 1.25, zoom: 2, pan: 0.7)
        preview.showPages(pages)
        try await pump()
        dump("restored", preview)

        let view = preview.view
        let document = try XCTUnwrap(view.document)
        guard let page = document.page(at: 1), let scroll = view.documentView?.enclosingScrollView else {
            return XCTFail("no page or scroll view")
        }
        let clip = scroll.contentView
        // Ask PDFKit for the exact destination and see where it lands.
        view.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 675)))
        try await pump()
        dump("after go(to: 675)", preview)

        // Where is that point now?
        let point = NSPoint(x: 0, y: 675)
        let viewPoint = view.convert(point, from: page)
        let clipPoint = clip.convert(viewPoint, from: view)
        let target = view.isFlipped ? view.bounds.minY : view.bounds.maxY
        let clipTarget = clip.convert(NSPoint(x: view.bounds.midX, y: target), from: view)
        print("PROBE geometry pointView=\(viewPoint) pointClip=\(clipPoint) targetClip=\(clipTarget) "
            + "origin=\(clip.bounds.origin) constrained=\(clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + clipPoint.y - clipTarget.y), size: clip.bounds.size)))")

        // Now scroll by the delta the way `keep` does, twice, and watch whether it sticks.
        for step in 1...2 {
            var origin = clip.bounds.origin
            let now = clip.convert(view.convert(point, from: page), from: view)
            let goal = clip.convert(NSPoint(x: view.bounds.midX, y: target), from: view)
            origin.x += now.x - goal.x
            origin.y += now.y - goal.y
            let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
            clip.scroll(to: constrained.origin)
            scroll.reflectScrolledClipView(clip)
            print("PROBE scroll\(step) wanted=\(origin) constrained=\(constrained.origin) clipAfter=\(clip.bounds) "
                + "pointClip=\(clip.convert(view.convert(point, from: page), from: view))")
            try await pump()
            dump("after scroll\(step)", preview)
        }
    }
}
