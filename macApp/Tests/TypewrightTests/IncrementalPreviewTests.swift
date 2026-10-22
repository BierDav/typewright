import AppKit
import PDFKit
import XCTest
@testable import Typewright

@MainActor
final class IncrementalPreviewTests: XCTestCase {
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
        compiler = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func attach(_ preview: PreviewController) {
        window.contentView = preview.view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Waits until the preview stopped re-aligning, since PDFKit lays swapped pages out after the call.
    private func settle(_ preview: PreviewController) async throws {
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<20 {
            let before = preview.position()
            try await Task.sleep(for: .milliseconds(20))
            if preview.position() == before { return }
        }
    }

    private func pages(_ text: String) async throws -> [CompiledPage] {
        let result = await compiler.compile(main: "main.typ", buffers: ["main.typ": text], format: .pdf, incremental: true)
        return try XCTUnwrap(result.previewPages, result.log)
    }

    func testInternalLinksKeepTheirDocumentDestinations() async throws {
        let text = "#link(<end>)[Jump]\n#pagebreak()\n= End <end>"
        let result = await compiler.compile(main: "main.typ", buffers: ["main.typ": text], format: .pdf, incremental: true)
        XCTAssertNil(result.previewPages)
        let document = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(result.output)))
        XCTAssertEqual(document.pageCount, 2)
        let links = try XCTUnwrap(document.page(at: 0)).annotations
        XCTAssertFalse(links.isEmpty)
        XCTAssertTrue(links.contains { annotation in
            guard let action = annotation.action as? PDFActionGoTo, let page = action.destination.page else { return false }
            return document.index(for: page) == 1
        })
    }

    func testDocumentLivePreviewPerformance() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEWRIGHT_PERF_DOCUMENT"] else {
            throw XCTSkip("Set TYPEWRIGHT_PERF_DOCUMENT to profile a local document")
        }
        let file = URL(fileURLWithPath: path)
        let text = try String(contentsOf: file, encoding: .utf8)
        let compiler = BuiltinCompiler(root: file.deletingLastPathComponent())
        let preview = PreviewController()
        attach(preview)
        let initial = await compiler.compile(main: file.lastPathComponent, buffers: [:], format: .pdf, incremental: true)
        preview.showPages(try XCTUnwrap(initial.previewPages, initial.log))
        try await Task.sleep(for: .milliseconds(100))
        for revision in 0..<5 {
            let start = Date()
            let result = await compiler.compile(main: file.lastPathComponent,
                buffers: [file.lastPathComponent: text + "\nPerformance revision \(revision)"], format: .pdf, incremental: true)
            let pages = try XCTUnwrap(result.previewPages, result.log)
            preview.showPages(pages)
            let ready = Date().timeIntervalSince(start) * 1000
            let bitmap = try XCTUnwrap(preview.view.bitmapImageRepForCachingDisplay(in: preview.view.bounds))
            preview.view.cacheDisplay(in: preview.view.bounds, to: bitmap)
            print("Incremental PDF edit \(revision): compile \(result.duration * 1000) ms, PDFKit update \(ready) ms, snapshot \(Date().timeIntervalSince(start) * 1000) ms")
        }
    }

    func testOnlyChangedPagesAreReplacedAndPositionSurvives() async throws {
        let preview = PreviewController()
        attach(preview)
        let before = try await pages(source)
        preview.pendingPosition = DocumentPosition(page: 1.25, zoom: 4, pan: 0.7)
        preview.showPages(before)
        try await settle(preview)
        let position = try XCTUnwrap(preview.position())
        let document = try XCTUnwrap(preview.view.document)
        let first = document.page(at: 0)
        let second = document.page(at: 1)
        let after = try await pages(source + ", edited")
        XCTAssertTrue(after[0] === before[0])
        preview.showPages(after)
        try await settle(preview)
        XCTAssertTrue(document === preview.view.document)
        XCTAssertTrue(first === document.page(at: 0))
        XCTAssertFalse(second === document.page(at: 1))
        let updated = try XCTUnwrap(preview.position())
        XCTAssertEqual(updated.page, position.page, accuracy: 0.001)
        XCTAssertEqual(updated.pan, position.pan, accuracy: 0.001)
        XCTAssertEqual(updated.zoom, position.zoom)
        preview.showPages(try await pages("One"))
        XCTAssertEqual(document.pageCount, 1)
        preview.showPages(try await pages(source))
        XCTAssertEqual(document.pageCount, 2)
    }

    func testCursorZoomReachesTenThousandPercentAndBoundsMatchPDF() async throws {
        let preview = PreviewController()
        attach(preview)
        preview.showPages(try await pages(source))
        try await settle(preview)
        let cursor = NSPoint(x: 200, y: 200)
        let page = try XCTUnwrap(preview.view.page(for: cursor, nearest: true))
        let anchor = preview.view.convert(cursor, to: page)
        preview.zoom(by: 100 / preview.view.scaleFactor, at: preview.view.convert(cursor, to: nil))
        XCTAssertEqual(preview.view.scaleFactor, 100, accuracy: 0.001)
        try await settle(preview)
        let zoomed = preview.view.convert(anchor, from: page)
        XCTAssertEqual(zoomed.x, cursor.x, accuracy: 1)
        XCTAssertEqual(zoomed.y, cursor.y, accuracy: 1)
        let scroll = try XCTUnwrap(preview.view.documentView?.enclosingScrollView)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.width, scroll.contentView.bounds.width)
        preview.zoom(by: 0.5 / preview.view.scaleFactor, at: preview.view.convert(cursor, to: nil))
        XCTAssertLessThanOrEqual(try XCTUnwrap(scroll.documentView).frame.width, scroll.contentView.bounds.width + 1)
    }

    func testFullPDFAndIncrementalPreviewRoundTrip() async throws {
        let full = await compiler.compile(main: "main.typ", buffers: ["main.typ": source], format: .pdf)
        let document = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(full.output)))
        let incremental = try await pages(source)
        let pdf = PreviewController()
        let fast = PreviewController()
        for zoom in [2.0, 20, 100] {
            attach(pdf)
            pdf.pendingPosition = DocumentPosition(page: 1.25, zoom: zoom, pan: 0.7)
            pdf.show(document.copy() as? PDFDocument)
            try await settle(pdf)
            let position = try XCTUnwrap(pdf.position())
            attach(fast)
            fast.pendingPosition = position
            fast.showPages(incremental)
            try await settle(fast)
            let transferred = try XCTUnwrap(fast.position())
            XCTAssertEqual(transferred.page, position.page, accuracy: 0.001)
            XCTAssertEqual(transferred.pan, position.pan, accuracy: 0.001)
            XCTAssertEqual(transferred.zoom, position.zoom)
            attach(pdf)
            pdf.pendingPosition = transferred
            pdf.show(document.copy() as? PDFDocument)
            try await settle(pdf)
            let restored = try XCTUnwrap(pdf.position())
            XCTAssertEqual(restored.page, position.page, accuracy: 0.001)
            XCTAssertEqual(restored.pan, position.pan, accuracy: 0.001)
        }
    }
}
