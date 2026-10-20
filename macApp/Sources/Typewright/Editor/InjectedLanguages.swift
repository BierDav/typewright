import AppKit
import TypewrightCore

/// Colouring for code embedded in Typst raw blocks and Markdown fences, by its language tag.
enum InjectedLanguages {
    /// Mirrors `CodeTokenKind` in the Kotlin core.
    enum Kind: Int32 {
        case keyword, string, comment, number, function, type, variable, annotation, `operator`, unit
    }

    /// Bounds Markdown in Typst in Markdown …, since each level highlights its body again.
    static let maxDepth = 3

    /// The canonical language for a tag, or nil for unsupported ones.
    static func language(_ tag: String) -> String? { CodeHighlight.shared.language(tag: tag) }

    private static func color(_ kind: Kind) -> NSColor {
        switch kind {
        case .keyword, .operator: Highlighter.keywordColor
        case .string: Highlighter.stringColor
        case .comment: Highlighter.commentColor
        case .number: Highlighter.numberColor
        case .function: Highlighter.functionColor
        case .type: Highlighter.typeColor
        case .variable: Highlighter.paramColor
        case .annotation: Highlighter.labelColor
        case .unit: Highlighter.unitColor
        }
    }

    /// Colours `range` of `storage` as the canonical `language`.
    static func apply(_ language: String, to storage: NSTextStorage, range: NSRange, font: NSFont, depth: Int) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        switch language {
        case "typst", "typc":
            Highlighter.apply(to: storage, range: range, font: font, code: language == "typc", depth: depth)
        case "markdown":
            MarkdownHighlighter.apply(to: storage, range: range, font: font, depth: depth)
        default:
            storage.addAttributes([.font: font, .foregroundColor: NSColor.textColor], range: range)
            let code = (storage.string as NSString).substring(with: range)
            let tokens = CodeHighlight.shared.tokens(language: language, code: code)
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            for i in stride(from: 0, to: Int(tokens.size) - 2, by: 3) {
                let start = Int(tokens.get(index: Int32(i))), length = Int(tokens.get(index: Int32(i + 1)))
                guard let kind = Kind(rawValue: tokens.get(index: Int32(i + 2))), start + length <= range.length else { continue }
                let r = NSRange(location: range.location + start, length: length)
                storage.addAttribute(.foregroundColor, value: color(kind), range: r)
                if kind == .comment { storage.addAttribute(.font, value: italic, range: r) }
            }
        }
    }
}
