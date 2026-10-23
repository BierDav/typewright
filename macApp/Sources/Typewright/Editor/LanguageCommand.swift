import Foundation

/// Commands the docs link to, like tinymist's `command:tinymist.replaceText?{…}` for an outdated package version.
enum LanguageCommand {
    /// The edit a `tinymist.replaceText` link asks for, in UTF-16 offsets of `text`.
    static func replaceText(in link: URL, text: String) -> (range: NSRange, text: String)? {
        let prefix = "command:tinymist.replaceText?"
        guard link.absoluteString.hasPrefix(prefix),
              let json = link.absoluteString.dropFirst(prefix.count).removingPercentEncoding,
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let range = object["range"] as? [String: Any],
              let start = position(range["start"]), let end = position(range["end"]),
              let replacement = object["replace"] as? String,
              let offsets = Self.range(from: start, to: end, in: text)
        else { return nil }
        return (offsets, replacement)
    }

    /// An LSP position: zero-based line, and character in UTF-16 units of that line.
    private static func position(_ value: Any?) -> (line: Int, character: Int)? {
        guard let value = value as? [String: Any], let line = value["line"] as? Int,
              let character = value["character"] as? Int, line >= 0, character >= 0 else { return nil }
        return (line, character)
    }

    private static func range(from start: (line: Int, character: Int), to end: (line: Int, character: Int),
                              in text: String) -> NSRange? {
        guard let start = offset(of: start, in: text), let end = offset(of: end, in: text), start <= end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// A position's UTF-16 offset, clamped to the end of its line.
    private static func offset(of position: (line: Int, character: Int), in text: String) -> Int? {
        let s = text as NSString
        var line = 0
        var index = 0
        while line < position.line {
            let current = s.lineRange(for: NSRange(location: index, length: 0))
            guard NSMaxRange(current) > index, NSMaxRange(current) <= s.length else { return nil }
            index = NSMaxRange(current)
            line += 1
        }
        var end = NSMaxRange(s.lineRange(for: NSRange(location: index, length: 0)))
        while end > index, [10, 13].contains(s.character(at: end - 1)) { end -= 1 }
        return min(index + position.character, end)
    }
}
