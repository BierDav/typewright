import XCTest
@testable import Typewright

final class HoverDocsTests: XCTestCase {
    func testLongerFencesShowShorterOnes() {
        let blocks = MarkdownBlock.parse("````typ\n#worksheet(```\n  t := 2 s\n```)\n````\n\nAfter.")
        XCTAssertEqual(blocks, [.code("#worksheet(```\n  t := 2 s\n```)", language: "typ"), .paragraph("After.")])
    }

    func testLists() {
        let blocks = MarkdownBlock.parse("Intro:\n\n- one\n  more\n- two\n\n1. first\n\nText.")
        XCTAssertEqual(blocks, [.paragraph("Intro:"), .list(["one more", "two"], markers: ["•", "•"]),
                                .list(["first"], markers: ["1."]), .paragraph("Text.")])
    }

    /// tinymist's shape: a signature, the description with its own parameter list, then generated sections.
    func testTinymistDocsSplitUp() throws {
        let markdown = """
            ```typc
            let worksheet(
              ..body: arguments,
              digits: auto = auto,
              hidden: bool = false,
              inherit: auto | bool = auto,
            ) = any;
            ```

            ---

            Calculates the math you write, like a ****Mathcad**** worksheet.

            ```typ
            #show: worksheet
            ```

            ****Units**** are names.

            ````typ
            #worksheet(```
              t := 2 s
            ```)
            ````

            - ..body (content, str): The content.
            - inherit (auto, bool): See the definitions made before.

            # Rest Parameters

            ## body

            ```typc
            type: arguments
            ```

            # Named Parameters

            ## digits (named)

            ```typc
            type: auto
            ```



            ## hidden (named)

            ```typc
            type: bool | false
            ```

            Calculate without showing.
            More of it.

            ```typ
            #worksheet(hidden: true)[]
            ```

            Details.
            """
        let docs = try XCTUnwrap(FunctionDocs(markdown: markdown))
        XCTAssertEqual(docs.name, "worksheet")
        XCTAssertNil(docs.returns)
        XCTAssertEqual(docs.summary, "Calculates the math you write, like a ****Mathcad**** worksheet.")
        XCTAssertEqual(docs.example?.code, "#show: worksheet")
        XCTAssertEqual(MarkdownBlock.parse(docs.details), [.paragraph("****Units**** are names."),
                                                           .code("#worksheet(```\n  t := 2 s\n```)", language: "typ")])
        XCTAssertEqual(docs.parameters, [
            .init(name: "..body", type: "arguments", default: "", summary: "The content."),
            .init(name: "hidden", type: "bool | false", default: "false", summary: "Calculate without showing. More of it."),
            .init(name: "inherit", type: "auto | bool", default: "auto", summary: "See the definitions made before."),
            .init(name: "digits", type: "auto", default: "auto", summary: ""),
        ])
    }

    func testOnlyFunctionsSplitUp() {
        XCTAssertNil(FunctionDocs(markdown: "```typc\nlet x: int = 1;\n```\n\nA number."))
        XCTAssertNil(FunctionDocs(markdown: "`worksheet` (solveng)\n\nCalculates."))
        XCTAssertEqual(FunctionDocs(markdown: "```typc\nlet f(a: int, b: str = \"(,)\") -> content;\n```")?.parameters.map(\.default), ["", "\"(,)\""])
    }

    /// Hover and completion docs of solveng's functions come from the package, in tinymist's shape.
    func testSolvengFunctionsReadLikeTinymist() throws {
        let f = try XCTUnwrap(SolvengSupport.function("worksheet"))
        let docs = try XCTUnwrap(FunctionDocs(markdown: FunctionDocs.markdown(for: f)))
        XCTAssertEqual(docs.name, "worksheet")
        XCTAssertEqual(docs.summary, f.doc)
        XCTAssertEqual(docs.parameters.count, f.positional.count + f.named.count)
        XCTAssertEqual(docs.parameters.first?.name, "..body")
        let digits = try XCTUnwrap(docs.parameters.first { $0.name == "digits" })
        XCTAssertTrue(digits.default.hasPrefix("auto ("), digits.default)
        XCTAssertFalse(digits.summary.isEmpty)
        XCTAssertNil(SolvengSupport.function("not-a-function"))
    }

    /// Inline code is highlighted as typst; accepted names link to their docs, only the name itself.
    func testInlineCodeLinksNames() {
        let text = MarkdownView.inline("like **this**, *that* or `#clear(all: true)` and `heading.where(level: 1)`", links: { $0 == "clear" })
        let linked = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0.absoluteString) } }
        XCTAssertEqual(linked.map(\.0), ["clear"])
        XCTAssertEqual(linked.map(\.1), ["typewright-docs:clear"])
        XCTAssertEqual(String(text.characters), "like this, that or #clear(all: true) and heading.where(level: 1)")
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent == .emphasized })
        // Highlighted: the code has more than one colour.
        let colours = Set(text.runs.filter { $0.inlinePresentationIntent == .code }.compactMap(\.foregroundColor))
        XCTAssertGreaterThan(colours.count, 1)
    }
}
