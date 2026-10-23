import AppKit
import SwiftUI
import TypewrightCore
import TypstBridge

/// Typst syntax colouring from typst's own parser, in IntelliJ's palette.
enum Highlighter {
    static func operatorFont(size: CGFloat, ligatures: Bool = true) -> NSFont {
        EditorFont.register()
        let font = NSFont(name: "JetBrainsMono-Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .bold)
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kContextualAlternatesType,
            .selectorIdentifier: ligatures ? kContextualAlternatesOnSelector : kContextualAlternatesOffSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    /// Mirrors `HlTag` in the bridge.
    enum Tag: UInt32 {
        case plain, comment, punctuation, escape, strong, emph, link, raw, label, ref, heading, listMarker, listTerm
        case mathDelimiter, mathOperator, keyword, `operator`, number, string, function, interpolated, error, param, unit
    }

    struct Run {
        let range: NSRange
        let tag: Tag
        let bold: Bool
        let italic: Bool
        let math: Bool
    }

    /// Light and dark variants, after IntelliJ's Light and Dark themes.
    private static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func make(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? make(dark) : make(light) }
    }

    static let keywordColor = color(0x0033B3, 0xCF8E6D)
    static let stringColor = color(0x067D17, 0x6AAB73)
    static let numberColor = color(0x00838F, 0x2AACB8)
    static let unitColor = numberColor.withAlphaComponent(0.65)
    static let functionColor = color(0x00627A, 0x56A8F5)
    static let paramColor = color(0x871094, 0xC77DBB)
    static let labelColor = color(0x9E880D, 0xB3AE60)
    static let commentColor = color(0x8C8C8C, 0x7A7E85)
    static let mathColor = color(0x0E7C86, 0x5FB8C2)
    static let typeColor = color(0x1F7A6B, 0x4EC9B0)

    private static func foreground(_ tag: Tag) -> NSColor? {
        switch tag {
        case .keyword, .escape, .listMarker, .heading, .mathDelimiter, .mathOperator: keywordColor
        case .string, .raw: stringColor
        case .number: numberColor
        case .unit: unitColor
        case .function, .interpolated: functionColor
        case .param: paramColor
        case .label, .ref: labelColor
        case .comment: commentColor
        case .link: .linkColor
        case .operator: .textColor
        case .plain, .punctuation, .strong, .emph, .listTerm, .error: nil
        }
    }

    /// Runs with a style; unstyled text in between is left out.
    static func runs(in text: String, code: Bool = false) -> [Run] {
        var text = text
        var count = 0
        let values = text.withUTF8 { tw_highlight($0.baseAddress, $0.count, code, &count) }
        defer { tw_highlight_free(values, count) }
        return stride(from: 0, to: count - 2, by: 3).map { i in
            let packed = values[i + 2]
            return Run(range: NSRange(location: Int(values[i]), length: Int(values[i + 1])),
                       tag: Tag(rawValue: packed & 0xff) ?? .plain,
                       bold: packed >> 8 & 1 != 0, italic: packed >> 8 & 2 != 0, math: packed >> 8 & 4 != 0)
        }
    }

    /// A stretch of math shown as it renders, like `Omega` as `Ω` or the quotes of `"k"` hidden.
    struct Conceal: Equatable {
        let range: NSRange
        /// The character shown instead; 0 hides the range.
        let replacement: unichar
        /// The equation, `$` included; while the caret touches it, it shows its source.
        let equation: NSRange
    }

    /// Math from typst's parser, solveng code from solveng's editor support.
    static func conceals(in text: String, context: String = "") -> [Conceal] {
        var copy = text
        var count = 0
        let values = copy.withUTF8 { tw_conceal($0.baseAddress, $0.count, &count) }
        defer { tw_highlight_free(values, count) }
        let math = stride(from: 0, to: count - 4, by: 5).map { i in
            Conceal(range: NSRange(location: Int(values[i]), length: Int(values[i + 1])),
                    replacement: unichar(clamping: values[i + 2]),
                    equation: NSRange(location: Int(values[i + 3]), length: Int(values[i + 4] - values[i + 3])))
        }
        let source = text as NSString
        let isFold = { (conceal: Conceal) in
            let original = source.substring(with: conceal.range)
            return original != ":=" && original != "->"
        }
        let folds = math.filter(isFold)
        guard text.contains(SolvengSupport.tag) || !context.isEmpty || text.contains("worksheet") else { return folds }
        let code = SolvengSupport.conceals(text, context: context)
        let solveng = stride(from: 0, to: code.count - 4, by: 5).map { i in
            let v = { code[i + $0] }
            return Conceal(range: NSRange(location: v(0), length: v(1)), replacement: unichar(clamping: v(2)),
                           equation: NSRange(location: v(3), length: v(4) - v(3)))
        }
        return (folds + solveng.filter(isFold)).sorted { $0.range.location < $1.range.location }
    }

    /// Whether `location` is in math or a ```` ```solveng ```` block, where `""` glues names (`Delta""tau`).
    static func gluesNames(in text: String, at location: Int) -> Bool {
        let all = runs(in: text)
        // The run of the character before, which a quote typed here continues.
        guard location > 0, var i = all.firstIndex(where: { NSLocationInRange(location - 1, $0.range) }) else { return false }
        if all[i].math { return true }
        guard all[i].tag == .raw else { return false }
        // A raw block's lines are runs of their own; its fence starts the first.
        while i > 0, all[i - 1].tag == .raw, NSMaxRange(all[i - 1].range) == all[i].range.location { i -= 1 }
        let fence = "```" + SolvengSupport.tag
        let ns = text as NSString
        let start = all[i].range.location
        return ns.substring(with: NSRange(location: start, length: min((fence as NSString).length, ns.length - start))) == fence
    }

    /// Highlighted text for SwiftUI, e.g. code samples in the docs popup.
    static func highlighted(_ text: String, code: Bool, size: CGFloat) -> AttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let storage = NSTextStorage(string: text)
        apply(to: storage, font: font, code: code)
        var result = AttributedString()
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            var part = AttributedString(storage.attributedSubstring(from: range).string)
            if let color = attrs[.foregroundColor] as? NSColor { part.foregroundColor = Color(nsColor: color) }
            if let f = attrs[.font] as? NSFont {
                let traits = f.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { part.inlinePresentationIntent = .stronglyEmphasized }
                if traits.contains(.italic) { part.inlinePresentationIntent = (part.inlinePresentationIntent ?? []).union(.emphasized) }
            }
            result += part
        }
        return result
    }

    /// `solvengContext` is the text of the files around, see `EditorLanguage.solvengContext`.
    static func apply(to storage: NSTextStorage, font: NSFont, code: Bool = false, solvengContext: String = "") {
        storage.beginEditing()
        apply(to: storage, range: NSRange(location: 0, length: storage.length), font: font, code: code, depth: 0,
              solvengContext: solvengContext)
        storage.endEditing()
    }

    /// Highlights `range` as Typst; raw blocks with a known language tag get that language's colouring.
    static func apply(to storage: NSTextStorage, range: NSRange, font: NSFont, code: Bool, depth: Int, solvengContext: String = "") {
        let fonts = NSFontManager.shared
        let bold = fonts.convert(font, toHaveTrait: .boldFontMask)
        let italic = fonts.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = fonts.convert(bold, toHaveTrait: .italicFontMask)
        let ns = storage.string as NSString
        let text = range.location == 0 && range.length == ns.length ? storage.string : ns.substring(with: range)

        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: range)
        for run in runs(in: text, code: code) where NSMaxRange(run.range) <= range.length {
            let r = NSRange(location: range.location + run.range.location, length: run.range.length)
            var attrs: [NSAttributedString.Key: Any] = [:]
            let isItalic = run.italic || run.tag == .comment
            if run.bold || isItalic { attrs[.font] = run.bold && isItalic ? boldItalic : run.bold ? bold : italic }
            if let color = foreground(run.tag) {
                attrs[.foregroundColor] = color
            } else if run.math {
                attrs[.foregroundColor] = mathColor
            }
            if run.tag == .link { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if !attrs.isEmpty { storage.addAttributes(attrs, range: r) }
            if run.math {
                let operatorText = ns.substring(with: r)
                if operatorText == ":=" || operatorText == "->" {
                    storage.addAttributes([.font: operatorFont(size: font.pointSize), .ligature: 2], range: r)
                }
            }
            if run.tag == .raw, depth < InjectedLanguages.maxDepth { injectRaw(in: storage, run: r, font: font, depth: depth) }
        }
        // solveng colours what it calculates: its code blocks, math as `integration` says, and its calls' strings.
        guard !code, text.contains(SolvengSupport.tag) || !solvengContext.isEmpty || text.contains("worksheet")
                || text.contains("#graph") || text.contains("#lambdify") else { return }
        guard let solveng = SolvengSupport.highlight(text, context: solvengContext) else { return }
        for i in stride(from: 0, to: solveng.plain.count - 1, by: 2) where solveng.plain[i + 1] <= range.length {
            storage.addAttributes([.font: font, .foregroundColor: NSColor.textColor],
                                  range: NSRange(location: range.location + solveng.plain[i], length: solveng.plain[i + 1] - solveng.plain[i]))
        }
        InjectedLanguages.color(solveng.tokens, in: storage, at: range.location, length: range.length, font: font)
    }

    /// Colours the body of a ```` ```lang ```` raw block in its language; solveng code is coloured with the document.
    private static func injectRaw(in storage: NSTextStorage, run: NSRange, font: NSFont, depth: Int) {
        let raw = (storage.string as NSString).substring(with: run)
        let parts = raw.hasPrefix("```") ? rawBlockParts(raw: raw).map(Int.init) : []
        guard parts.count == 4 else { return }
        let tag = (raw as NSString).substring(with: NSRange(location: parts[0], length: parts[1] - parts[0]))
        guard let language = InjectedLanguages.language(tag), language != SolvengSupport.tag else { return }
        let body = NSRange(location: run.location + parts[2], length: parts[3] - parts[2])
        InjectedLanguages.apply(language, to: storage, range: body, font: font, depth: depth + 1)
    }
}
