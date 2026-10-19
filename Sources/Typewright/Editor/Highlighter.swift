import AppKit
import SwiftUI

/// Regex based Typst syntax colouring.
enum Highlighter {
    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let heading = re(#"^[ \t]*=+[ \t].*$"#, .anchorsMatchLines)
    private static let hashIdent = re(#"#[A-Za-z_][\w-]*"#)
    private static let keyword = re(#"#(let|set|show|import|include|if|else|for|while|return|break|continue|context)\b"#)
    private static let call = re(#"\b[A-Za-z_][\w-]*(?=\()"#)
    private static let math = re(#"\$(?:\\.|[^$\\])*\$"#)
    private static let label = re(#"<[\w:.-]+>|@[\w:.-]+"#)
    private static let emphasis = re(#"(?<![\w*])\*[^*\n]+\*(?![\w*])"#)
    // Comments, strings and raw text compete; the earliest match wins.
    private static let lexical = re(#"(?<!:)//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\\n])*"|```[\s\S]*?```|`[^`\n]*`"#)

    // In code mode (`typc`) keywords and values stand without a `#`.
    private static let codeKeyword = re(#"\b(let|set|show|import|include|if|else|for|in|while|return|break|continue|context|not|and|or)\b"#)
    private static let codeValue = re(#"\b(none|auto|true|false)\b|\b\d+(\.\d+)?(pt|em|cm|mm|in|%|fr|deg|rad)?\b"#)

    /// Highlighted text for SwiftUI, e.g. code samples in the docs popup.
    static func highlighted(_ text: String, code: Bool, size: CGFloat) -> AttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let storage = NSTextStorage(string: text)
        apply(to: storage, font: font, code: code)
        var result = AttributedString()
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            var part = AttributedString(storage.attributedSubstring(from: range).string)
            if let color = attrs[.foregroundColor] as? NSColor { part.foregroundColor = Color(nsColor: color) }
            if let f = attrs[.font] as? NSFont, f.fontDescriptor.symbolicTraits.contains(.bold) {
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            result += part
        }
        return result
    }

    static func apply(to storage: NSTextStorage, font: NSFont, code: Bool = false) {
        let full = NSRange(location: 0, length: storage.length)
        let string = storage.string
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)

        func color(_ regex: NSRegularExpression, _ attrs: [NSAttributedString.Key: Any]) {
            regex.enumerateMatches(in: string, range: full) { m, _, _ in
                if let r = m?.range { storage.addAttributes(attrs, range: r) }
            }
        }

        color(heading, [.font: bold, .foregroundColor: NSColor.systemBlue])
        color(emphasis, [.font: bold])
        color(call, [.foregroundColor: NSColor.systemBlue])
        color(hashIdent, [.foregroundColor: NSColor.systemBlue])
        color(keyword, [.foregroundColor: NSColor.systemPink])
        color(label, [.foregroundColor: NSColor.systemPurple])
        color(math, [.foregroundColor: NSColor.systemTeal])
        if code {
            color(codeValue, [.foregroundColor: NSColor.systemOrange])
            color(codeKeyword, [.foregroundColor: NSColor.systemPink])
        }

        lexical.enumerateMatches(in: string, range: full) { m, _, _ in
            guard let r = m?.range else { return }
            let token = (string as NSString).substring(with: NSRange(location: r.location, length: min(2, r.length)))
            let c: NSColor = token.hasPrefix("/") ? .secondaryLabelColor
                : token.hasPrefix("\"") ? .systemGreen : .systemOrange
            storage.addAttributes([.foregroundColor: c, .font: font], range: r)
        }
        storage.endEditing()
    }
}
