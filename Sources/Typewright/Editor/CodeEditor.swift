import AppKit
import SwiftUI

final class TypstTextView: NSTextView {
    // NSTextView sets the I-beam on every move, even under floating controls.
    override func mouseMoved(with event: NSEvent) {
        if let cursor = CursorArea.cursor(for: event) { cursor.set() } else { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = CursorArea.cursor(for: event) { cursor.set() } else { super.cursorUpdate(with: event) }
    }

    override func insertTab(_ sender: Any?) {
        insertText("  ", replacementRange: selectedRange())
    }

    /// Keeps the indentation of the current line.
    override func insertNewline(_ sender: Any?) {
        let s = string as NSString
        let line = s.substring(with: s.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }
}

struct CodeEditor: NSViewRepresentable {
    let documentID: Int
    let text: String
    let fontSize: CGFloat
    let highlights: Bool
    let diagnostics: [Diagnostic]
    let reveal: RevealRequest?
    /// Restored when a new document is shown.
    let state: EditorState?
    let topInset: CGFloat
    let onChange: (String) -> Void
    let onStateChange: (EditorState) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = TypstTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 6, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .labelColor
        // Neutral selection instead of the system accent.
        tv.selectedTextAttributes = [.backgroundColor: NSColor.gray.withAlphaComponent(0.3)]
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        // Text starts below the hidden title bar strip but scrolls under it.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        let ruler = LineNumberRuler(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.didScroll),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onChange = onChange
        c.highlights = highlights
        c.onStateChange = onStateChange
        guard let tv = c.textView else { return }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if c.documentID != documentID || c.font != font {
            let isNewDocument = c.documentID != documentID
            c.documentID = documentID
            c.font = font
            tv.font = font
            if isNewDocument {
                c.isRestoring = true
                if tv.string != text {
                    tv.string = text
                    tv.undoManager?.removeAllActions()
                }
                let state = state ?? EditorState()
                // Wait for the view to get its real width so line positions are final.
                DispatchQueue.main.async {
                    Self.restore(state, in: tv)
                    c.isRestoring = false
                }
            }
            if let storage = tv.textStorage { c.style(storage) }
        }

        if c.diagnostics != diagnostics {
            c.diagnostics = diagnostics
            markDiagnostics(in: tv)
        }

        if let reveal, c.reveal != reveal {
            c.reveal = reveal
            DispatchQueue.main.async { Self.select(line: reveal.line, column: reveal.column, in: tv) }
        }
        c.ruler?.needsDisplay = true
    }

    // Fitting size follows the text; never let it set the column's min size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }

    private func markDiagnostics(in tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let s = tv.string as NSString
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: s.length))
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: s.length))
        for d in diagnostics {
            guard let range = Self.lineRange(d.line, in: s) else { continue }
            let tint: NSColor = d.severity == .error ? .systemRed : .systemYellow
            lm.addTemporaryAttributes([.backgroundColor: tint.withAlphaComponent(0.12)], forCharacterRange: range)
            let start = min(range.location + max(d.column - 1, 0), NSMaxRange(range))
            let underline = NSRange(location: start, length: NSMaxRange(range) - start)
            lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                                       .underlineColor: tint], forCharacterRange: underline)
        }
    }

    static func lineRange(_ line: Int, in s: NSString) -> NSRange? {
        var current = 1
        var index = 0
        while current < line {
            let r = s.lineRange(for: NSRange(location: index, length: 0))
            guard NSMaxRange(r) < s.length else { return nil }
            index = NSMaxRange(r)
            current += 1
        }
        var r = s.lineRange(for: NSRange(location: index, length: 0))
        if r.length > 0, s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        return r
    }

    private static func restore(_ state: EditorState, in tv: NSTextView) {
        let length = (tv.string as NSString).length
        let location = min(state.selection, length)
        tv.setSelectedRange(NSRange(location: location, length: min(state.length, length - location)))
        guard let lm = tv.layoutManager, let scroll = tv.enclosingScrollView else { return }
        var y = -scroll.contentInsets.top
        if length > 0, state.top > 0 {
            let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(state.top, length - 1)), effectiveRange: nil)
            y += rect.minY + tv.textContainerOrigin.y
        }
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private static func select(line: Int, column: Int, in tv: NSTextView) {
        let s = tv.string as NSString
        guard let r = lineRange(line, in: s) else { return }
        let loc = min(r.location + max(column - 1, 0), NSMaxRange(r))
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        tv.scrollRangeToVisible(r)
        tv.showFindIndicator(for: r)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var ruler: NSRulerView?
        var documentID = -1
        var font: NSFont?
        var highlights = true
        var diagnostics: [Diagnostic] = []
        var reveal: RevealRequest?
        var onChange: (String) -> Void = { _ in }
        var onStateChange: (EditorState) -> Void = { _ in }
        var isRestoring = false

        @objc func didScroll() { report() }

        private func report() {
            guard !isRestoring, let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer,
                  let scroll = tv.enclosingScrollView else { return }
            let selection = tv.selectedRange()
            let y = scroll.contentView.bounds.minY + scroll.contentInsets.top - tv.textContainerOrigin.y
            let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: container)
            let top = (tv.string as NSString).length == 0 ? 0 : lm.characterIndexForGlyph(at: glyph)
            onStateChange(EditorState(selection: selection.location, length: selection.length, top: top))
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if let storage = tv.textStorage { style(storage) }
            onChange(tv.string)
        }

        func style(_ storage: NSTextStorage) {
            guard let font else { return }
            if highlights {
                Highlighter.apply(to: storage, font: font)
            } else {
                storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor],
                                      range: NSRange(location: 0, length: storage.length))
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
            report()
        }
    }
}
