import AppKit
import XCTest
@testable import Typewright

@MainActor
final class PasteImageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chapters"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testImageDataIsSavedNextToTheFileWithUniqueNames() throws {
        let file = root.appendingPathComponent("chapters/one.typ")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let ws = Workspace(url: file)
        defer { ws.close() }
        ws.select(file)
        let pasteboard = NSPasteboard(name: .init("tw-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(try png(), forType: .png)

        let first = try XCTUnwrap(ws.pasteImage(from: pasteboard))
        let second = try XCTUnwrap(ws.pasteImage(from: pasteboard))
        XCTAssertTrue(first.hasPrefix("#image(\"image-"))
        XCTAssertNotEqual(first, second)
        let saved = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("chapters").path)
            .filter { $0.hasSuffix(".png") }
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.allSatisfy { first.contains($0) || second.contains($0) })
    }

    func testTextAndMarkdownFiles() throws {
        let file = root.appendingPathComponent("notes.md")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let image = root.appendingPathComponent("chapters/my plot.png")
        try png().write(to: image)
        let ws = Workspace(url: file)
        defer { ws.close() }
        ws.select(file)
        let pasteboard = NSPasteboard(name: .init("tw-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.writeObjects([image as NSURL])
        XCTAssertEqual(ws.pasteImage(from: pasteboard), "![](<my plot.png>)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("my plot.png").path))

        // Text wins over a picture of it, as rich text editors put both.
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        pasteboard.setData(try png(), forType: .png)
        XCTAssertNil(ws.pasteImage(from: pasteboard))
    }
}
