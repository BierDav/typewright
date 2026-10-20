import AppKit

final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        // Views no longer clip by default; numbers past the bottom would draw over the status bar.
        clipsToBounds = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func refresh() { needsDisplay = true }

    // Skip NSRulerView's border line.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (tv.font?.pointSize ?? 13) - 2), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let string = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: container)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = string.lineRange(for: NSRange(location: min(tv.selectedRange().location, string.length), length: 0))

        // The view may start inside a wrapped line; counting up to its middle would shift every number.
        let start = string.lineRange(for: NSRange(location: min(chars.location, string.length), length: 0)).location
        var line = 1
        string.enumerateSubstrings(in: NSRange(location: 0, length: start),
                                   options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }

        func draw(_ n: Int, y: CGFloat, height: CGFloat, highlighted: Bool) {
            let label = "\(n)" as NSString
            let size = label.size(withAttributes: attrs)
            let p = convert(NSPoint(x: 0, y: y + tv.textContainerOrigin.y), from: tv)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: p.y + (height - size.height) / 2),
                       withAttributes: highlighted ? current : attrs)
        }

        var index = start
        while index < NSMaxRange(chars) {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: lineRange.location), effectiveRange: nil)
            draw(line, y: rect.minY, height: rect.height, highlighted: lineRange.location == caretLine.location)
            index = NSMaxRange(lineRange)
            line += 1
        }
        if !lm.extraLineFragmentRect.isEmpty {
            let rect = lm.extraLineFragmentRect
            draw(line, y: rect.minY, height: rect.height, highlighted: caretLine.location == string.length)
        }
    }
}
