import XCTest
@testable import Typewright

@MainActor
final class CompletionDocsTests: XCTestCase {
    /// tinymist leaves docs out of completions and resolve; they come from hovering the item.
    func testCompletionDocsComeFromHover() async throws {
        let binary = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Typewright/tinymist/tinymist")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "tinymist isn't downloaded")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.typ")
        let text = "#gr"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let client = try XCTUnwrap(LanguageClient(binary: binary, root: root, fontPaths: []))
        defer { client.stop() }
        client.open(file, text: text)
        let items = await client.completions(in: file, text: text as NSString, at: 3)
        let grid = try XCTUnwrap(items.first { $0.label == "grid" })
        let resolved = await client.documentation(of: grid)
        let hovered = await client.hoverDocumentation(of: grid, in: file, text: text as NSString)
        XCTAssertNil(resolved)
        XCTAssertNotNil(grid.range)
        XCTAssertTrue(hovered?.contains("grid") == true, String(describing: hovered))
        // The list stays open while typing, so its ranges trail the text.
        let typed = "#grid"
        client.change(file, text: typed)
        let later = await client.hoverDocumentation(of: grid, in: file, text: typed as NSString)
        XCTAssertTrue(later?.contains("grid") == true, String(describing: later))
    }
}
