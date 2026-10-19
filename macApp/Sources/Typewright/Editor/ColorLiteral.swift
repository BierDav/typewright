import AppKit

/// A Typst color written in the source, like `rgb("#ff4136")`, `rgb("ff4136")`, `rgb(255, 65, 54)`, `luma(40%)` or `red`.
struct ColorLiteral: Equatable {
    enum Format: Equatable {
        case hex(uppercase: Bool, alpha: Bool, short: Bool = false, hash: Bool = true)
        case components(percent: Bool, alpha: Bool)
        case luma(percent: Bool)
        case named
    }

    let range: NSRange
    let color: NSColor
    let format: Format

    private static let hex = try! NSRegularExpression(pattern: ##"\brgb\(\s*"(#?)([0-9a-fA-F]{3,8})"\s*\)"##)
    private static let number = #"\s*(\d+(?:\.\d+)?%?)\s*"#
    private static let components = try! NSRegularExpression(
        pattern: #"\brgb\("# + number + "," + number + "," + number + "(?:," + number + #")?\)"#)
    private static let luma = try! NSRegularExpression(pattern: #"\bluma\("# + number + #"\)"#)
    // Only where a value is expected, so the words in prose stay plain.
    private static let named = try! NSRegularExpression(
        pattern: #"(?<=[:(,\[]\s{0,3})\b(black|gray|silver|white|navy|blue|aqua|teal|eastern|purple|fuchsia|maroon|red|orange|yellow|olive|green|lime)\b(?![\w.(-])"#)

    /// Typst's predefined colors.
    private static let palette: [String: UInt32] = [
        "black": 0x000000, "gray": 0xaaaaaa, "silver": 0xdddddd, "white": 0xffffff, "navy": 0x001f3f,
        "blue": 0x0074d9, "aqua": 0x7fdbff, "teal": 0x39cccc, "eastern": 0x239dad, "purple": 0xb10dc9,
        "fuchsia": 0xf012be, "maroon": 0x85144b, "red": 0xff4136, "orange": 0xff851b, "yellow": 0xffdc00,
        "olive": 0x3d9970, "green": 0x2ecc40, "lime": 0x01ff70,
    ]

    static func find(in text: String) -> [ColorLiteral] {
        let s = text as NSString
        let full = NSRange(location: 0, length: s.length)
        var found: [ColorLiteral] = []
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : s.substring(with: r)
        }

        for m in hex.matches(in: text, range: full) {
            guard let digits = group(m, 2), [3, 4, 6, 8].contains(digits.count) else { continue }
            let expanded = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
            guard let value = UInt64(expanded, radix: 16) else { continue }
            let alpha = expanded.count == 8
            let rgb = alpha ? value >> 8 : value
            let color = srgb(Double((rgb >> 16) & 0xff) / 255, Double((rgb >> 8) & 0xff) / 255, Double(rgb & 0xff) / 255,
                             alpha ? Double(value & 0xff) / 255 : 1)
            let uppercase = digits.contains { $0.isLetter && $0.isUppercase }
            let format = Format.hex(uppercase: uppercase, alpha: alpha, short: digits.count <= 4, hash: group(m, 1) == "#")
            found.append(ColorLiteral(range: m.range, color: color, format: format))
        }
        for m in components.matches(in: text, range: full) {
            let parts = (1...4).compactMap { group(m, $0) }
            let values = parts.compactMap(component)
            guard values.count == parts.count else { continue }
            let color = srgb(values[0], values[1], values[2], values.count == 4 ? values[3] : 1)
            found.append(ColorLiteral(range: m.range, color: color,
                                      format: .components(percent: parts[0].hasSuffix("%"), alpha: values.count == 4)))
        }
        for m in luma.matches(in: text, range: full) {
            guard let part = group(m, 1), let v = component(part) else { continue }
            found.append(ColorLiteral(range: m.range, color: srgb(v, v, v, 1), format: .luma(percent: part.hasSuffix("%"))))
        }
        for m in named.matches(in: text, range: full) {
            guard let name = group(m, 1), let rgb = palette[name] else { continue }
            let color = srgb(Double((rgb >> 16) & 0xff) / 255, Double((rgb >> 8) & 0xff) / 255, Double(rgb & 0xff) / 255, 1)
            found.append(ColorLiteral(range: m.range, color: color, format: .named))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Source for `color`: hex and `rgb(…)` keep their form, everything else becomes hex.
    static func source(for color: NSColor, format: Format) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent, a = c.alphaComponent
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        func percent(_ v: CGFloat) -> String {
            let p = (min(max(v, 0), 1) * 1000).rounded() / 10
            return p == p.rounded() ? "\(Int(p))%" : "\(p)%"
        }
        let opaque = byte(a) == 255
        if case .components(let isPercent, let hadAlpha) = format {
            var parts = [r, g, b].map { isPercent ? percent($0) : "\(byte($0))" }
            if hadAlpha || !opaque { parts.append(isPercent ? percent(a) : "\(byte(a))") }
            return "rgb(\(parts.joined(separator: ", ")))"
        }
        var bytes = [r, g, b].map(byte)
        if case .hex(_, true, _, _) = format { bytes.append(byte(a)) } else if !opaque { bytes.append(byte(a)) }
        var hex: String
        // `#f80` stays short while every byte is a doubled digit.
        if case .hex(_, _, true, _) = format, bytes.allSatisfy({ $0 % 17 == 0 }) {
            hex = bytes.map { String($0 / 17, radix: 16) }.joined()
        } else {
            hex = bytes.map { String(format: "%02x", $0) }.joined()
        }
        if case .hex(true, _, _, _) = format { hex = hex.uppercased() }
        if case .hex(_, _, _, false) = format { return "rgb(\"\(hex)\")" }
        return "rgb(\"#\(hex)\")"
    }

    /// The format of the source written by `source(for:format:)`, for the next edit.
    static func format(of source: String, previous: Format) -> Format {
        find(in: source).first?.format ?? previous
    }

    private static func component(_ s: String) -> Double? {
        if s.hasSuffix("%") { return Double(s.dropLast()).map { min($0 / 100, 1) } }
        // Typst only takes integers 0–255 for unscaled components.
        guard let v = Int(s), v <= 255 else { return nil }
        return Double(v) / 255
    }

    private static func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
