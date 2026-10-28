import AppKit

extension TypstTextView {
    func updateConcealedFonts() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let key = Highlighter.concealedFontKey
        var desired: [NSRange: (original: NSFont, replacement: NSFont)] = [:]
        for conceal in conceals where conceal.replacement != 0 && self.conceal(at: conceal.range.location) != nil {
            let original = (storage.attribute(key, at: conceal.range.location, effectiveRange: nil) as? NSFont)
                ?? (storage.attribute(.font, at: conceal.range.location, effectiveRange: nil) as? NSFont)
            guard let original, let replacement = Highlighter.concealGlyph(conceal.replacement, font: original),
                  replacement.font != original else { continue }
            desired[conceal.range] = (original, replacement.font)
        }
        var restore: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let original = value as? NSFont, desired[range] == nil { restore.append((range, original)) }
        }
        let apply = desired.filter { range, fonts in
            storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont != fonts.replacement
        }
        guard !restore.isEmpty || !apply.isEmpty else { return }
        // Drawing reads the text attributes, so fallback glyphs need their font there too.
        storage.beginEditing()
        for (range, original) in restore {
            storage.addAttribute(.font, value: original, range: range)
            storage.removeAttribute(key, range: range)
        }
        for (range, fonts) in apply {
            storage.addAttributes([.font: fonts.replacement, key: fonts.original], range: range)
        }
        storage.endEditing()
    }

    func collapsedSegmentBoxes(in rect: NSRect) -> [(range: NSRange, box: NSRect)] {
        guard concealsMath, let layout = layoutManager, let container = textContainer else { return [] }
        let glyphs = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y),
                                     in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return collapsedSegments.filter {
            NSIntersectionRange($0, visible).length > 0 && hasConcealedGlyphs(in: $0, layout: layout)
        }.flatMap { range in
            highlightBoxes(for: range).filter { $0.intersects(rect) }.map { (range, $0) }
        }
    }

    private func hasConcealedGlyphs(in range: NSRange, layout: NSLayoutManager) -> Bool {
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let source = string as NSString
        for glyph in glyphs.location..<NSMaxRange(glyphs) {
            let index = layout.characterIndexForGlyph(at: glyph)
            guard let conceal = conceal(at: index) else { continue }
            // A typographic minus changes its shape without hiding source.
            if conceal.range.length == 1, source.character(at: index) == 0x2D, conceal.replacement == 0x2212 { continue }
            if layout.propertyForGlyph(at: glyph).contains(.null) { return true }
            guard conceal.replacement != 0, index == conceal.range.location,
                  conceal.range.length > 1 || source.character(at: index) != conceal.replacement,
                  let font = (textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? self.font else { continue }
            // Unsupported symbols keep their original spelling and need no marker.
            if let replacement = Highlighter.concealGlyph(conceal.replacement, font: font),
               layout.glyph(at: glyph) == replacement.glyph { return true }
        }
        return false
    }

    func collapsedSegment(at point: NSPoint) -> NSRange? {
        collapsedSegmentBoxes(in: visibleRect).first { $0.box.contains(point) }?.range
    }

    func collapsedSourceTooltip(for range: NSRange) -> String {
        let source = (string as NSString).substring(with: range)
        let longest = source.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "Collapsed source\n\n\(fence)typst\n\(source)\n\(fence)"
    }

    func drawCollapsedSegmentUnderlines(in rect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        for (_, box) in collapsedSegmentBoxes(in: rect) {
            let path = NSBezierPath()
            path.lineWidth = 1
            path.lineCapStyle = .round
            path.setLineDash([0, 3], count: 2, phase: 0)
            let y = box.maxY - 1.5
            path.move(to: NSPoint(x: box.minX + 0.5, y: y))
            path.line(to: NSPoint(x: box.maxX - 0.5, y: y))
            path.stroke()
        }
    }
}
