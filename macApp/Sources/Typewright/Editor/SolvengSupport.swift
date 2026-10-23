import Foundation
import TypstBridge

/// solveng's editor support (`solveng-ide` from the solveng repository, through the typst bridge): highlighting,
/// completions, concealing, conversions and hovers for its calculations. Offsets are UTF-16.
enum SolvengSupport {
    /// Language tag of solveng code.
    static let tag = "solveng"

    /// The bundled `solveng-ide` version.
    static let version: String = decode(call("version", "")) ?? ""

    struct Item: Decodable {
        let label: String
        /// Variable 0, function 1, unit 2, constant 3, parameter 4, option value 5.
        let kind: Int
        let detail: String
        /// Inserted text; `$0` marks the caret.
        let insert: String
        let documentation: String?
        /// What typing matches when it differs from `insert`: `Delta_R` for `Δ_R`.
        let filter: String?
    }

    /// `items` replace `from..<(to ?? offset)`; `exclusive` ones replace the language server's.
    struct Completions: Decodable {
        let from: Int
        let to: Int?
        let items: [Item]
        let exclusive: Bool
    }

    struct Conversion: Decodable {
        let title: String
        let start: Int
        let end: Int
        let text: String
    }

    /// One of the package's functions, read from its doc comments.
    struct Function: Decodable {
        let name: String
        /// The first paragraph of its docs.
        let doc: String
        let positional: [Parameter]
        let named: [Parameter]
    }

    struct Parameter: Decodable {
        let name: String
        /// `auto, str`, as the docs list them.
        let types: String
        let doc: String
        /// As in the signature, `auto (4)` for options whose `auto` means a default.
        let `default`: String
        let variadic: Bool
    }

    struct Hover: Decodable {
        let start: Int
        let end: Int
        let markdown: String
    }

    /// Where a name is: in a context file (relative to the root), or with no path in the document itself.
    struct Location: Decodable {
        let path: String?
        let start: Int
        let end: Int
    }

    /// Replace `start..<end` with `text`, in the document (no path) or a context file (relative to the root).
    struct Edit: Decodable {
        let path: String?
        let start: Int
        let end: Int
        let text: String
    }

    /// A name that can be renamed, as written at `start..<end`.
    struct RenameTarget: Decodable {
        let start: Int
        let end: Int
        let name: String
    }

    /// A problem solveng would report, found while typing, like an unknown unit.
    struct Problem: Decodable {
        let start: Int
        let end: Int
        let message: String
        let severity: String?
    }

    /// The context JSON the bridge reads: the files around (paths relative to the root), the last compile's report,
    /// the document's path, whether it's the compiled file and that file's path, where scopes are followed from, and
    /// the report of compiling the document on its own, used when the compiled file doesn't reach it.
    static func context(files: [(path: String, text: String)], report: String, path: String, main: Bool, mainPath: String = "",
                        fileReport: String = "") -> String {
        let object: [String: Any] = ["files": files.map { ["path": $0.path, "text": $0.text] }, "report": report,
                                     "path": path, "main": main, "mainPath": main ? path : mainPath, "fileReport": fileReport]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func call(_ op: String, _ document: String, context: String = "", offset: Int = 0) -> Data {
        var document = document
        var context = context
        let result = document.withUTF8 { doc in
            context.withUTF8 { ctx in
                tw_solveng(op, doc.baseAddress, doc.count, ctx.baseAddress, ctx.count, UInt32(clamping: max(offset, 0)))
            }
        }
        defer { tw_string_free(result) }
        return Data(String(cString: result).utf8)
    }

    private static func decode<T: Decodable>(_ data: Data) -> T? { try? JSONDecoder().decode(T.self, from: data) }

    /// Tokens of solveng code as flat `(start, length, kind)` triples, kinds as in `InjectedLanguages.Kind`.
    static func tokens(_ code: String) -> [Int32] { decode(call("tokens", code)) ?? [] }

    /// solveng code as documentation shows it (A², x₂), with its tokens as flat triples.
    struct Pretty: Decodable {
        let text: String
        let tokens: [Int32]
    }

    /// `units`: the document's own, read as units after a number like the built-in ones.
    static func pretty(_ code: String, units: [String] = []) -> Pretty? { decode(call("pretty", code, context: units.joined(separator: ","))) }

    /// Every solveng token of a document (calculated code and math, its calls' strings and options), and `(start, end)`
    /// pairs of calculated code and call strings, plain under them.
    struct Highlight: Decodable {
        let tokens: [Int32]
        let plain: [Int]
    }

    static func highlight(_ document: String, context: String) -> Highlight? {
        decode(call("highlight", document, context: context))
    }

    /// Flat `(start, length, character, elementStart, elementEnd)` quintuples.
    static func conceals(_ document: String, context: String) -> [Int] { decode(call("conceals", document, context: context)) ?? [] }

    static func complete(_ document: String, context: String, offset: Int) -> Completions? {
        decode(call("complete", document, context: context, offset: offset))
    }

    static func function(_ name: String) -> Function? { decode(call("function", name)) }

    static func hover(_ document: String, context: String, offset: Int) -> Hover? {
        decode(call("hover", document, context: context, offset: offset))
    }

    static func conversions(_ document: String, context: String, offset: Int) -> [Conversion] {
        decode(call("conversions", document, context: context, offset: offset)) ?? []
    }

    static func unitFixes(_ document: String, context: String, offset: Int) -> [Conversion] {
        decode(call("fixes", document, context: context, offset: offset)) ?? []
    }


    /// The definition of the solveng name at `offset`.
    static func definition(_ document: String, context: String, offset: Int) -> Location? {
        decode(call("definition", document, context: context, offset: offset))
    }

    /// Every use of the solveng name at `offset`, its definition included.
    static func usages(_ document: String, context: String, offset: Int) -> [Location] {
        decode(call("usages", document, context: context, offset: offset)) ?? []
    }

    /// The solveng name at `offset` that `rename` renames.
    static func renameTarget(_ document: String, context: String, offset: Int) -> RenameTarget? {
        decode(call("renameTarget", document, context: context, offset: offset))
    }

    /// Edits renaming the solveng name at `offset` and its usages to `name`, spelled as each place needs.
    static func rename(_ document: String, context: String, offset: Int, to name: String) -> [Edit] {
        decode(call("rename:" + name, document, context: context, offset: offset)) ?? []
    }

    static func diagnostics(_ document: String, context: String) -> [Problem] {
        decode(call("diagnostics", document, context: context)) ?? []
    }

    /// Local files a document imports or includes, as written.
    static func references(_ document: String) -> [String] { decode(call("references", document)) ?? [] }
}
