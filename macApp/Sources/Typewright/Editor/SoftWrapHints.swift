import AppKit

final class EditorTextContainer: NSTextContainer {
    var wrapHintWidth: CGFloat = 8 {
        didSet {
            if wrapHintWidth != oldValue { layoutManager?.textContainerChangedGeometry(self) }
        }
    }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                          writingDirection: baseWritingDirection, remaining: remainingRect)
        guard let text = layoutManager?.textStorage?.string as NSString?, characterIndex <= text.length else { return rect }
        let line = text.lineRange(for: NSRange(location: characterIndex, length: 0))
        let leading = characterIndex > line.location ? wrapHintWidth : 0
        // Keep marker space in the layout even when the caret is elsewhere.
        rect.origin.x += leading
        rect.size.width = max(1, rect.width - leading - wrapHintWidth)
        return rect
    }
}

extension TypstTextView {
    struct SoftWrapHint {
        let rect: NSRect
        let continues: Bool
    }

    func softWrapHints(in dirtyRect: NSRect) -> [SoftWrapHint] {
        guard let lm = layoutManager, let container = textContainer as? EditorTextContainer else { return [] }
        lm.ensureLayout(for: container)
        let text = string as NSString
        let heads = currentCarets.map(\.head)
        let active = Set(heads.filter { $0 <= text.length }.map { text.lineRange(for: NSRange(location: $0, length: 0)).location })
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        var hints: [SoftWrapHint] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { line, used, _, glyphRange, _ in
            let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let logical = text.lineRange(for: NSRange(location: chars.location, length: 0))
            guard active.contains(logical.location) else { return }
            var end = 0
            text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: chars.location, length: 0))
            let width = container.wrapHintWidth
            if chars.location > logical.location {
                hints.append(SoftWrapHint(rect: NSRect(x: origin.x + line.minX + container.lineFragmentPadding - width,
                                                       y: origin.y + line.minY, width: width, height: line.height), continues: true))
            }
            if NSMaxRange(chars) < end {
                hints.append(SoftWrapHint(rect: NSRect(x: origin.x + used.maxX - container.lineFragmentPadding,
                                                       y: origin.y + line.minY, width: width, height: line.height), continues: false))
            }
        }
        return hints
    }

    func drawSoftWrapHints(in dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        for hint in softWrapHints(in: dirtyRect) {
            let box = hint.rect
            let width = min(box.width - 2, box.height * 0.45)
            let height = min(box.height * 0.65, width * 1.5)
            let x = box.midX - width / 2, y = box.midY - height / 2
            func point(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
                NSPoint(x: x + (hint.continues ? 1 - u : u) * width, y: y + v * height)
            }
            let path = NSBezierPath()
            // Mirror one diagonal arrow so both ends of a wrap have the same shape.
            path.move(to: point(0.48, 0.22))
            path.curve(to: point(0.78, 0.36), controlPoint1: point(0.88, -0.08), controlPoint2: point(1.12, 0.12))
            path.line(to: point(0.08, 0.9))
            path.move(to: point(0.08, 0.48))
            path.line(to: point(0.08, 0.9))
            path.line(to: point(0.62, 0.9))
            path.lineWidth = max(1, min(1.5, width * 0.18))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }
}
