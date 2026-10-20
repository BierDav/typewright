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
        case SolvengSupport.tag:
            storage.addAttributes([.font: font, .foregroundColor: NSColor.textColor], range: range)
            let code = (storage.string as NSString).substring(with: range)
            color(SolvengSupport.tokens(code), in: storage, at: range.location, length: range.length, font: font)
        default:
            storage.addAttributes([.font: font, .foregroundColor: NSColor.textColor], range: range)
            let code = (storage.string as NSString).substring(with: range)
            color(CodeHighlight.shared.tokens(language: language, code: code), in: storage, at: range.location, length: range.length, font: font)
        }
    }

    /// Colours flat `(start, length, kind)` tokens relative to `location`, within `length`.
    static func color(_ tokens: [Int32], in storage: NSTextStorage, at location: Int, length: Int, font: NSFont) {
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for i in stride(from: 0, to: tokens.count - 2, by: 3) {
            let start = Int(tokens[i]), count = Int(tokens[i + 1])
            guard let kind = Kind(rawValue: tokens[i + 2]), start + count <= length else { continue }
            let r = NSRange(location: location + start, length: count)
            storage.addAttribute(.foregroundColor, value: color(kind), range: r)
            if kind == .comment { storage.addAttribute(.font, value: italic, range: r) }
        }
    }

    /// Colours `(start, length, kind)` tokens relative to `location`, within `length`.
    static func color(_ tokens: KotlinIntArray, in storage: NSTextStorage, at location: Int, length: Int, font: NSFont) {
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for i in stride(from: 0, to: Int(tokens.size) - 2, by: 3) {
            let start = Int(tokens.get(index: Int32(i))), count = Int(tokens.get(index: Int32(i + 1)))
            guard let kind = Kind(rawValue: tokens.get(index: Int32(i + 2))), start + count <= length else { continue }
            let r = NSRange(location: location + start, length: count)
            storage.addAttribute(.foregroundColor, value: color(kind), range: r)
            if kind == .comment { storage.addAttribute(.font, value: italic, range: r) }
        }
    }
}
