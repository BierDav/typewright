import AppKit

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

    static func apply(to storage: NSTextStorage, font: NSFont) {
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
