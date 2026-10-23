import AppKit

extension TypstTextView {
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
            if layout.propertyForGlyph(at: glyph).contains(.null) { return true }
            guard conceal.replacement != 0, index == conceal.range.location,
                  conceal.range.length > 1 || source.character(at: index) != conceal.replacement,
                  let font = (textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? self.font else { continue }
            // Unsupported symbols keep their original spelling and need no marker.
            var character = conceal.replacement
            var replacement: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(font, &character, &replacement, 1), replacement != 0,
               layout.glyph(at: glyph) == replacement { return true }
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
