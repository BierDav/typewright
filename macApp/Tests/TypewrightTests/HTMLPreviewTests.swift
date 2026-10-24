import AppKit
import WebKit
import XCTest
@testable import Typewright

@MainActor
final class HTMLPreviewTests: XCTestCase {
    private var window: NSWindow!
    private var preview: HTMLPreviewController!
    private let base = FileManager.default.temporaryDirectory

    override func setUp() {
        preview = HTMLPreviewController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview.view
    }

    override func tearDown() {
        window.close()
        window = nil
        preview = nil
    }

    /// Dark mode only switches the color scheme; documents that don't declare one get a warning.
    func testNoticesDocumentsHandlingColorSchemes() {
        preview.show("<p>Plain typst</p>", baseURL: base)
        XCTAssertFalse(preview.handlesColorScheme)
        preview.show("<style>:root { color-scheme: light dark; }</style><p>letmeout</p>", baseURL: base)
        XCTAssertTrue(preview.handlesColorScheme)
        preview.show("<style>@media (prefers-color-scheme: dark) { p { color: white } }</style>", baseURL: base)
        XCTAssertTrue(preview.handlesColorScheme)
    }

    private func waitFor(_ condition: String) async throws {
        for _ in 0..<100 {
            if (try? await preview.view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out: \(condition)")
    }

    func testShowsTheHTMLWithTheBrowsersDefaultsOnly() async throws {
        preview.show("<h1>Heading</h1><p>Paragraph</p>", baseURL: base)
        try await waitFor("document.querySelector('p') !== null")
        let defaults = try await preview.view.evaluateJavaScript("""
            getComputedStyle(document.body).margin === '8px' && getComputedStyle(document.documentElement).colorScheme === 'normal'
            """) as! Bool
        XCTAssertTrue(defaults)
    }

    func testPreservesExportStylesAttributesAndIncrementalUpdates() async throws {
        let head = """
            <style>html.export body.document { margin: 17px; font: 19px Georgia; }
            body.document img { width: 800px; height: 400px; }</style>
            <script>window.headRuns = (window.headRuns || 0) + 1;</script>
            """
        func html(_ text: String, attrs: String = "class='document' data-version='1'") -> String {
            """
            <!DOCTYPE html><html class="export" lang="de" dir="ltr"><head>\(head)</head>
            <body \(attrs)>Leading text<h1 id="keep">Heading</h1><p id="edit">\(text)</p><footer>End</footer></body></html>
            """
        }
        preview.show(html("Before"), baseURL: base)
        try await waitFor("document.querySelector('#edit')?.textContent === 'Before'")
        let preserved = try await preview.view.evaluateJavaScript("""
            window.keptHeading = document.querySelector('#keep');
            window.keptDocument = document;
            document.documentElement.lang === 'de' && document.documentElement.dir === 'ltr'
              && document.body.dataset.version === '1' && getComputedStyle(document.body).marginLeft === '17px'
              && getComputedStyle(document.body).fontSize === '19px'
              && document.body.firstChild.textContent === 'Leading text'
            """) as! Bool
        XCTAssertTrue(preserved)

        preview.show(html("After", attrs: "class='document' data-revised='yes'"), baseURL: base)
        try await waitFor("document.querySelector('#edit')?.textContent === 'After'")
        let incremental = try await preview.view.evaluateJavaScript("""
            document === window.keptDocument && document.querySelector('#keep') === window.keptHeading
              && window.headRuns === 1 && !document.body.hasAttribute('data-version')
              && document.body.dataset.revised === 'yes'
            """) as! Bool
        XCTAssertTrue(incremental)
    }

    func testRapidUpdatesKeepTheLatestOutputWithoutReloading() async throws {
        preview.show("<h1 id='stable'>Heading</h1><p>Initial</p>", baseURL: base)
        try await waitFor("document.querySelector('p')?.textContent === 'Initial'")
        _ = try await preview.view.evaluateJavaScript("window.stableNode = document.querySelector('#stable'); true")
        for revision in 0..<40 {
            preview.show("<h1 id='stable'>Heading</h1><p>Revision \(revision)</p>", baseURL: base)
        }
        try await waitFor("document.querySelector('p')?.textContent === 'Revision 39'")
        let kept = try await preview.view.evaluateJavaScript("document.querySelector('#stable') === window.stableNode") as! Bool
        XCTAssertTrue(kept)
    }

    func testLeavesIntrinsicImageSizingAndColorsUntouched() async throws {
        window.setContentSize(NSSize(width: 360, height: 600))
        preview.show("""
            <figure><img width="800" height="400"></figure>
            <svg width="800" height="400" viewBox="0 0 800 400"></svg>
            """, baseURL: base)
        try await waitFor("document.querySelector('svg') !== null")
        let values = try await preview.view.evaluateJavaScript("""
            [document.querySelector('img').getBoundingClientRect().width,
             document.querySelector('svg').getBoundingClientRect().width,
             getComputedStyle(document.querySelector('svg')).filter]
            """) as! [Any]
        XCTAssertEqual(values[0] as! Double, 800, accuracy: 0.1)
        XCTAssertEqual(values[1] as! Double, 800, accuracy: 0.1)
        XCTAssertEqual(values[2] as! String, "none")
    }

    func testScrollBarsOverlayThePageWhenTheSystemShowsThemAlways() async throws {
        let method = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle))!
        let legacy: @convention(block) (AnyObject) -> NSScroller.Style = { _ in .legacy }
        let original = method_setImplementation(method, imp_implementationWithBlock(legacy))
        defer { method_setImplementation(method, original) }
        let html = (0..<200).map { "<p>Line \($0)</p>" }.joined()
        let plain = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        plain.loadHTMLString(html, baseURL: nil)
        preview = HTMLPreviewController()
        window.contentView = preview.view
        preview.show(html, baseURL: base)
        try await waitFor("document.querySelectorAll('p').length === 200")
        let overlaid = try await preview.view.evaluateJavaScript("document.documentElement.clientWidth === innerWidth") as! Bool
        XCTAssertTrue(overlaid)
        // Without the override the same page loses a strip to the scroll bar, so the check above means something.
        for _ in 0..<100 where (try? await plain.evaluateJavaScript("document.querySelectorAll('p').length")) as? Int != 200 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let strip = try await plain.evaluateJavaScript("document.documentElement.clientWidth < innerWidth") as! Bool
        XCTAssertTrue(strip)
    }

    func testPatchesInsideWrappersAndReplacesWhatScriptsChanged() async throws {
        func html(_ text: String, _ value: String) -> String {
            "<section class='page'><div class='sheet'><h1 id='keep'>Heading</h1><p id='edit'>\(text)</p>"
                + "<div id='widget'><span>\(value)</span></div></div></section>"
        }
        preview.show(html("Before", "A"), baseURL: base)
        try await waitFor("document.querySelector('#edit')?.textContent === 'Before'")
        // Stands in for a page script drawing into its element.
        _ = try await preview.view.evaluateJavaScript("""
            window.kept = [document.querySelector('.page'), document.querySelector('#keep'), document.querySelector('#widget')];
            document.querySelector('#widget').append(document.createElement('canvas')); true
            """)

        preview.show(html("After", "A"), baseURL: base)
        try await waitFor("document.querySelector('#edit')?.textContent === 'After'")
        let patched = try await preview.view.evaluateJavaScript("""
            window.kept.every((n, i) => n === [document.querySelector('.page'), document.querySelector('#keep'),
                                              document.querySelector('#widget')][i])
              && document.querySelector('#widget canvas') !== null
            """) as! Bool
        XCTAssertTrue(patched)

        preview.show(html("After", "B"), baseURL: base)
        try await waitFor("document.querySelector('#widget')?.textContent === 'B'")
        let replaced = try await preview.view.evaluateJavaScript("""
            document.querySelector('#widget') !== window.kept[2] && document.querySelector('#widget canvas') === null
              && document.querySelector('#keep') === window.kept[1]
            """) as! Bool
        XCTAssertTrue(replaced)
    }

    func testLargeImagesLoadThroughTheBridgeInsteadOfTheHTML() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Noise, so the PNG stays far above the size that is kept inline.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        for i in 0..<(bitmap.bytesPerRow * 100) { bitmap.bitmapData![i] = UInt8.random(in: 0...255) }
        try bitmap.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("photo.png"))

        let compiler = BuiltinCompiler(root: dir)
        let result = await compiler.compile(main: "main.typ", buffers: ["main.typ": "= Photo\n#image(\"photo.png\")"],
                                            format: .html)
        let html = String(decoding: try XCTUnwrap(result.output), as: UTF8.self)
        XCTAssertFalse(html.contains("data:image/png"), html)
        XCTAssertTrue(html.contains("src=\"twimage:///image/png/"), html)

        preview.show(html, baseURL: dir)
        try await waitFor("document.querySelector('img')?.complete && document.querySelector('img').naturalWidth === 200")
    }

    func testViewStaysOnTheSameContentWhenBlocksChangeAboveAndBelow() async throws {
        let lines = (0..<300).map { "<p id='l\($0)'>Line \($0)</p>" }
        preview.show(lines.joined(), baseURL: base)
        try await waitFor("document.querySelectorAll('p').length === 300")
        _ = try await preview.view.evaluateJavaScript("document.getElementById('l150').scrollIntoView(); true")
        let top = "document.getElementById('l150').getBoundingClientRect().top"
        let before = try await preview.view.evaluateJavaScript(top) as! Double

        let inserted = (0..<20).map { "<h2>New \($0)</h2>" }
        preview.show((inserted + lines + inserted).joined(), baseURL: base)
        try await waitFor("document.querySelectorAll('h2').length === 40")
        let afterInsert = try await preview.view.evaluateJavaScript(top) as! Double
        XCTAssertEqual(afterInsert, before, accuracy: 1)

        // One wrapper around everything comes in whole; unchanged elements inside it still hold the view.
        preview.show("<main>\(lines.joined())</main>", baseURL: base)
        try await waitFor("document.querySelector('main') !== null && document.querySelectorAll('h2').length === 0")
        let beforeWrapped = try await preview.view.evaluateJavaScript(top) as! Double
        XCTAssertEqual(beforeWrapped, before, accuracy: 2)
        preview.show("<main>\((inserted + lines).joined())</main>", baseURL: base)
        try await waitFor("document.querySelectorAll('h2').length === 20")
        let afterWrapped = try await preview.view.evaluateJavaScript(top) as! Double
        XCTAssertEqual(afterWrapped, beforeWrapped, accuracy: 1)
    }
}
