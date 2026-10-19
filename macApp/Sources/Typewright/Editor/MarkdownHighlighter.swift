import AppKit

/// Markdown colouring in the editor's palette; fenced code gets its language's colouring.
enum MarkdownHighlighter {
    private static func re(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let fence = re(#"^ {0,3}(`{3,}|~{3,})[ \t]*([\w+#.-]*)[^\n]*\n([\s\S]*?)(?:^ {0,3}\1[`~]*[ \t]*$|\z)"#)
    private static let frontMatter = re(#"\A---\n[\s\S]*?\n---[ \t]*$"#)
    private static let heading = re(#"^ {0,3}(#{1,6})(?:[ \t]+(.*))?$"#)
    private static let setext = re(#"^(?=.*\S).+\n {0,3}(=+|-+)[ \t]*$"#)
    private static let quote = re(#"^ {0,3}((?:>[ \t]?)+)(.*)$"#)
    private static let listMarker = re(#"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\][ \t])?"#)
    private static let rule = re(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let tablePipe = re(#"^[ \t]*\|.*\|[ \t]*$"#)
    private static let codeSpan = re(#"(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)"#, [])
    private static let strong = re(#"(\*\*|__)(?=\S)[\s\S]*?\S\1"#, [])
    private static let emphasis = re(#"(?<![*_\w])([*_])(?=\S)[^*_\n]*?\S\1(?![*_\w])"#, [])
    private static let strike = re(#"~~(?=\S)[^\n]*?\S~~"#, [])
    private static let link = re(#"(!?\[)((?:[^\]\\\n]|\\.)*)(\]\()([^)\s]*)((?:\s+"[^"]*")?\))"#, [])
    private static let reference = re(#"\[\^?[^\]\n]+\](?:\[[^\]\n]*\])?(?!\()"#, [])
    private static let url = re(#"<?(?:https?://|mailto:)[^\s<>()]+[^\s<>().,;:!?'"]>?"#, [])
    private static let math = re(#"\$\$[\s\S]+?\$\$|(?<![\\$\w])\$(?=\S)[^$\n]*?\S\$(?![\w$])"#, [])
    private static let html = re(#"</?[A-Za-z][\w-]*(?:\s[^<>]*)?/?>|<!--[\s\S]*?-->"#, [])
    private static let emoji = re(#":[a-z0-9_+-]+:"#, [])
    private static let escape = re(#"\\[\\`*_{}\[\]()#+\-.!|<>~$]"#, [])

    static func apply(to storage: NSTextStorage, font: NSFont) {
        storage.beginEditing()
        apply(to: storage, range: NSRange(location: 0, length: storage.length), font: font, depth: 0)
        storage.endEditing()
    }

    /// Highlights `range` alone; regexes treat its bounds as the text's start and end.
    static func apply(to storage: NSTextStorage, range full: NSRange, font: NSFont, depth: Int) {
        let string = storage.string
        let ns = string as NSString
        let fonts = NSFontManager.shared
        let bold = fonts.convert(font, toHaveTrait: .boldFontMask)
        let italic = fonts.convert(font, toHaveTrait: .italicFontMask)

        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)

        // Code blocks and front matter first; nothing inside them is Markdown.
        var protected: [NSRange] = []
        for m in frontMatter.matches(in: string, range: full) {
            storage.addAttributes([.foregroundColor: Highlighter.commentColor], range: m.range)
            protected.append(m.range)
        }
        for m in fence.matches(in: string, range: full) where !protected.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            storage.addAttributes([.foregroundColor: Highlighter.commentColor], range: m.range)
            let body = m.range(at: 3)
            let tag = m.range(at: 2).length > 0 ? ns.substring(with: m.range(at: 2)) : ""
            if body.length > 0 {
                if depth < InjectedLanguages.maxDepth, let language = InjectedLanguages.language(tag) {
                    InjectedLanguages.apply(language, to: storage, range: body, font: font, depth: depth + 1)
                } else {
                    storage.addAttributes([.foregroundColor: Highlighter.stringColor], range: body)
                }
            }
            protected.append(m.range)
        }
        let isFree = { (r: NSRange) in !protected.contains { NSIntersectionRange($0, r).length > 0 || NSLocationInRange(r.location, $0) } }
        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: string, range: full) { m, _, _ in
                if let m, isFree(m.range) { body(m) }
            }
        }
        func color(_ r: NSRange, _ c: NSColor) {
            if r.location != NSNotFound, r.length > 0 { storage.addAttribute(.foregroundColor, value: c, range: r) }
        }

        each(tablePipe) { m in
            let line = ns.substring(with: m.range) as NSString
            for i in 0..<line.length where line.character(at: i) == 124 { color(NSRange(location: m.range.location + i, length: 1), Highlighter.keywordColor) }
        }
        each(rule) { color($0.range, Highlighter.keywordColor) }
        each(listMarker) { m in
            color(m.range(at: 1), Highlighter.keywordColor)
            color(m.range(at: 2), Highlighter.keywordColor)
        }
        each(quote) { m in
            color(m.range(at: 1), Highlighter.keywordColor)
            if m.range(at: 2).length > 0 { storage.addAttribute(.font, value: italic, range: m.range(at: 2)) }
        }
        each(strike) { m in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Highlighter.commentColor], range: m.range)
        }
        each(emphasis) { storage.addAttribute(.font, value: italic, range: $0.range) }
        each(strong) { storage.addAttribute(.font, value: bold, range: $0.range) }
        each(html) { color($0.range, Highlighter.functionColor) }
        each(emoji) { color($0.range, Highlighter.labelColor) }
        each(reference) { color($0.range, Highlighter.labelColor) }
        each(url) { m in
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: m.range)
        }
        each(link) { m in
            color(m.range(at: 1), Highlighter.keywordColor)
            color(m.range(at: 2), .linkColor)
            color(m.range(at: 3), Highlighter.keywordColor)
            if m.range(at: 4).length > 0 {
                storage.addAttributes([.foregroundColor: Highlighter.commentColor, .underlineStyle: 0], range: m.range(at: 4))
            }
            color(m.range(at: 5), Highlighter.keywordColor)
        }
        each(heading) { m in
            storage.addAttributes([.font: bold, .foregroundColor: Highlighter.keywordColor], range: m.range)
        }
        each(setext) { m in storage.addAttributes([.font: bold, .foregroundColor: Highlighter.keywordColor], range: m.range) }
        each(math) { color($0.range, Highlighter.mathColor) }
        // Code spans and escapes win over everything they contain.
        each(codeSpan) { m in
            storage.addAttributes([.foregroundColor: Highlighter.stringColor, .font: font, .underlineStyle: 0,
                                   .strikethroughStyle: 0], range: m.range)
        }
        each(escape) { color($0.range, Highlighter.keywordColor) }
    }
}
