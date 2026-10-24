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

    /// A function taking `..args`, like a package's override of `grid`, keeps the parameters its doc comment lists.
    func testOverriddenFunctionsKeepTheirParameterDocs() async throws {
        let binary = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Typewright/tinymist/tinymist")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "tinymist isn't downloaded")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        /// Arranges content in a grid.
        ///
        /// - columns (auto, int, array): The column sizes.
        ///
        ///   Default: `()`.
        ///
        ///   **In HTML:** CSS column tracks.
        ///
        /// - children (content, ...): The cells.
        ///
        ///   This parameter is positional.
        ///
        /// -> content
        #let grid(..args) = std.grid(..args)
        """.write(to: root.appendingPathComponent("lib.typ"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("main.typ")
        let text = "#import \"lib.typ\": *\n#grid(columns: 2)[a]\n#gr"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let client = try XCTUnwrap(LanguageClient(binary: binary, root: root, fontPaths: []))
        defer { client.stop() }
        client.open(file, text: text)
        let ns = text as NSString

        let hover = await client.documentedHover(in: file, text: ns, at: ns.range(of: "grid(").location + 1)
        let docs = try XCTUnwrap(hover.flatMap { FunctionDocs(markdown: $0.markdown) }, String(describing: hover))
        XCTAssertEqual(["columns", "..children"], docs.parameters.map(\.name))
        XCTAssertEqual("content", docs.returns)
        XCTAssertEqual("The column sizes. **In HTML:** CSS column tracks.", docs.parameters.first?.summary)
        XCTAssertEqual("()", docs.parameters.first?.default)

        let argument = await client.parameterDocs(in: file, text: ns, at: ns.range(of: "columns").location + 2)
        XCTAssertEqual("```typc\ncolumns: auto | int | array = ()\n```\n\nThe column sizes.\n\n**In HTML:** CSS column tracks.",
                       argument?.markdown)

        let items = await client.completions(in: file, text: ns, at: ns.length)
        let grid = try XCTUnwrap(items.first { $0.label == "grid" })
        let completion = await client.hoverDocumentation(of: grid, in: file, text: ns)
        XCTAssertEqual(["columns", "..children"], completion.flatMap { FunctionDocs(markdown: $0) }?.parameters.map(\.name))
    }
}
