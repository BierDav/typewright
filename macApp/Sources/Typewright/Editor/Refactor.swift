import Foundation
import TypstBridge

/// Extract and inline variable, worked out on typst's syntax tree in the bridge.
enum Refactor {
    struct Candidate: Decodable {
        let start: Int
        let length: Int
        let text: String
        var range: NSRange { NSRange(location: start, length: length) }
    }

    struct Response: Decodable {
        var error: String?
        var candidates: [Candidate] = []
        var edits: [Candidate] = []
        var names: [[Int]] = []
        var count = 0
        var kind: String?

        init(error: String? = nil) { self.error = error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            candidates = try c.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
            edits = try c.decodeIfPresent([Candidate].self, forKey: .edits) ?? []
            names = try c.decodeIfPresent([[Int]].self, forKey: .names) ?? []
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
        }

        private enum CodingKeys: String, CodingKey { case error, candidates, edits, names, count, kind }

        var textEdits: [TextEdit] { edits.map { TextEdit(range: $0.range, newText: $0.text) } }
        var nameRanges: [NSRange] { names.map { NSRange(location: $0[0], length: $0[1]) } }
    }

    /// Expressions to extract: the one selected, or those around the caret, inner to outer.
    static func candidates(in text: String, selection: NSRange) -> Response {
        run(["op": "candidates", "text": text, "start": selection.location, "length": selection.length])
    }

    static func extract(in text: String, range: NSRange, all: Bool) -> Response {
        run(["op": "extract", "text": text, "start": range.location, "length": range.length, "all": all])
    }

    /// Blocks the function can go into, inner to outer; each candidate's text is its label.
    static func scopes(in text: String, range: NSRange) -> Response {
        run(["op": "scopes", "text": text, "start": range.location, "length": range.length])
    }

    /// Into the innermost scope, or the one starting at `scope`.
    static func function(in text: String, range: NSRange, scope: Int? = nil) -> Response {
        var request: [String: Any] = ["op": "function", "text": text, "start": range.location, "length": range.length]
        if let scope { request["scope"] = scope }
        return run(request)
    }

    /// The name at `offset` and whether it's a "variable" or "function".
    static func symbol(in text: String, at offset: Int) -> (name: String, kind: String)? {
        let r = run(["op": "symbol", "text": text, "start": offset])
        guard let name = r.candidates.first?.text, let kind = r.kind else { return nil }
        return (name, kind)
    }

    /// Uses in this file of the name declared at `offset`, like an import item.
    static func usages(in text: String, at offset: Int) -> [NSRange] {
        run(["op": "usages", "text": text, "start": offset]).candidates.map(\.range)
    }

    static func inline(in text: String, at offset: Int) -> Response {
        run(["op": "inline", "text": text, "start": offset])
    }

    private static func run(_ request: [String: Any]) -> Response {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else { return Response(error: "Invalid request") }
        let raw = tw_refactor(json)
        defer { tw_string_free(raw) }
        return (try? JSONDecoder().decode(Response.self, from: Data(String(cString: raw).utf8)))
            ?? Response(error: "Invalid response")
    }
}
