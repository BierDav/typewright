import AppKit
import SwiftUI
import TypewrightCore
import TypstBridge

/// Typst syntax colouring from typst's own parser, in IntelliJ's palette.
enum Highlighter {
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
        case .plain, .punctuation, .operator, .strong, .emph, .listTerm, .error: nil
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

    static func conceals(in text: String) -> [Conceal] {
        var text = text
        var count = 0
        let values = text.withUTF8 { tw_conceal($0.baseAddress, $0.count, &count) }
        defer { tw_highlight_free(values, count) }
        return stride(from: 0, to: count - 4, by: 5).map { i in
            Conceal(range: NSRange(location: Int(values[i]), length: Int(values[i + 1])),
                    replacement: unichar(clamping: values[i + 2]),
                    equation: NSRange(location: Int(values[i + 3]), length: Int(values[i + 4] - values[i + 3])))
        }
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

    static func apply(to storage: NSTextStorage, font: NSFont, code: Bool = false) {
        storage.beginEditing()
        apply(to: storage, range: NSRange(location: 0, length: storage.length), font: font, code: code, depth: 0)
        storage.endEditing()
    }

    /// Highlights `range` as Typst; raw blocks with a known language tag get that language's colouring.
    static func apply(to storage: NSTextStorage, range: NSRange, font: NSFont, code: Bool, depth: Int) {
        let fonts = NSFontManager.shared
        let bold = fonts.convert(font, toHaveTrait: .boldFontMask)
        let italic = fonts.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = fonts.convert(bold, toHaveTrait: .italicFontMask)
        let ns = storage.string as NSString
        let text = range.location == 0 && range.length == ns.length ? storage.string : ns.substring(with: range)

        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: range)
        // solveng's `plain-code: true` makes code without a language a calculation.
        let plain = !code && Solveng.shared.plainCode(document: text)
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
            if run.tag == .raw, depth < InjectedLanguages.maxDepth { injectRaw(in: storage, run: r, font: font, depth: depth, plain: plain) }
        }
    }

    /// Colours the body of a ```` ```lang ```` raw block in its language; with `plain`, untagged raw is solveng.
    private static func injectRaw(in storage: NSTextStorage, run: NSRange, font: NSFont, depth: Int, plain: Bool) {
        let raw = (storage.string as NSString).substring(with: run)
        let parts = raw.hasPrefix("```") ? CodeHighlight.shared.rawBlock(raw: raw) : KotlinIntArray(size: 0)
        guard parts.size == 4 else {
            let body = plain ? Solveng.shared.body(raw: raw, plain: true) : KotlinIntArray(size: 0)
            guard body.size == 2 else { return }
            let range = NSRange(location: run.location + Int(body.get(index: 0)), length: Int(body.get(index: 1) - body.get(index: 0)))
            InjectedLanguages.apply(Solveng.shared.TAG, to: storage, range: range, font: font, depth: depth + 1)
            return
        }
        let tag = (raw as NSString).substring(with: NSRange(location: Int(parts.get(index: 0)),
                                                            length: Int(parts.get(index: 1) - parts.get(index: 0))))
        guard let language = InjectedLanguages.language(tag) else { return }
        let body = NSRange(location: run.location + Int(parts.get(index: 2)), length: Int(parts.get(index: 3) - parts.get(index: 2)))
        InjectedLanguages.apply(language, to: storage, range: body, font: font, depth: depth + 1)
    }
}
