import AppKit
import WebKit
import XCTest
@testable import Typewright

@MainActor
final class MarkdownPreviewTests: XCTestCase {
    func testRelativeImagesLoad() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appending(path: "Resources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 8, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: dir.appending(path: "Resources/logo.png"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let preview = HTMLPreviewController(markdown: true)
        window.contentView = preview.view
        let html = MarkdownRenderer.html("# Hi\n\n<img src=\"Resources/logo.png\" width=\"128\">\n\n![](Resources/logo.png)\n")
        preview.show(html, baseURL: dir)

        var widths: [Int] = []
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            let result = try? await preview.view.evaluateJavaScript(
                "[...document.images].map(i => i.complete ? i.naturalWidth : -1)")
            widths = (result as? [Int]) ?? []
            if widths.count == 2, !widths.contains(-1) { break }
        }
        XCTAssertEqual(widths, [8, 8])
    }
}
