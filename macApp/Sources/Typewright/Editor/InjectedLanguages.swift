import AppKit
import TypewrightCore

/// Colouring for code embedded in Typst raw blocks and Markdown fences, by its language tag.
enum InjectedLanguages {
    /// Mirrors `highlight::kind` in the Rust core.
    enum Kind: Int32 {
        case keyword, string, comment, number, function, type, variable, annotation, `operator`, unit
    }

    /// solveng's kind for a function's parameter (and what a graph plots against), beyond the shared kinds.
    static let parameter: Int32 = 10
    /// solveng's `=` or `->` that shows a result, set very bold as Mathcad does.
    static let evaluate: Int32 = 11
    static let functionCall: Int32 = 12
    static let builtinFunction: Int32 = 13
    static let unitReference: Int32 = 14
    static let constant: Int32 = 15

    /// Bounds Markdown in Typst in Markdown …, since each level highlights its body again.
    static let maxDepth = 3

    /// The canonical language for a tag, or nil for unsupported ones.
    static func language(_ tag: String) -> String? { codeLanguage(tag: tag) }

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
            color(codeTokens(language: language, code: code), in: storage, at: range.location, length: range.length, font: font)
        }
    }

    /// Colours flat `(start, length, kind)` tokens relative to `location`, within `length`.
    static func color(_ tokens: [Int32], in storage: NSTextStorage, at location: Int, length: Int, font: NSFont) {
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        // Weight 7 of 15 is medium; families without it fall back to the regular face.
        let medium = font.familyName.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 7, size: font.pointSize) } ?? font
        for i in stride(from: 0, to: tokens.count - 2, by: 3) {
            let start = Int(tokens[i]), count = Int(tokens[i + 1])
            // solveng's parameters: variables that stand out.
            if tokens[i + 2] == parameter, start + count <= length {
                let r = NSRange(location: location + start, length: count)
                storage.addAttributes([.foregroundColor: Highlighter.paramColor, .font: bold], range: r)
                continue
            }
            if tokens[i + 2] == evaluate, start + count <= length {
                let r = NSRange(location: location + start, length: count)
                storage.addAttributes([.foregroundColor: Highlighter.keywordColor,
                                       .font: Highlighter.operatorFont(size: font.pointSize), .ligature: 2,
                                       .strokeWidth: -3, .strokeColor: Highlighter.keywordColor], range: r)
                continue
            }
            if (tokens[i + 2] == functionCall || tokens[i + 2] == builtinFunction), start + count <= length {
                let r = NSRange(location: location + start, length: count)
                storage.addAttribute(.foregroundColor, value: tokens[i + 2] == builtinFunction ? Highlighter.typeColor : NSColor.textColor, range: r)
                continue
            }
            if tokens[i + 2] == constant, start + count <= length {
                let r = NSRange(location: location + start, length: count)
                storage.addAttributes([.foregroundColor: Highlighter.constantColor,
                                       .font: medium], range: r)
                continue
            }
            if tokens[i + 2] == unitReference, start + count <= length {
                storage.addAttribute(.foregroundColor, value: Highlighter.commentColor,
                                     range: NSRange(location: location + start, length: count))
                continue
            }
            guard let kind = Kind(rawValue: tokens[i + 2]), start + count <= length else { continue }
            let r = NSRange(location: location + start, length: count)
            storage.addAttribute(.foregroundColor, value: color(kind), range: r)
            if kind == .operator {
                let text = (storage.string as NSString).substring(with: r)
                if text == ":=" || text == "->" {
                    storage.addAttributes([.font: Highlighter.operatorFont(size: font.pointSize), .ligature: 2], range: r)
                }
            }
            if kind == .comment { storage.addAttribute(.font, value: italic, range: r) }
        }
    }
}
