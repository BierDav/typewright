import AppKit
import SwiftUI

final class TypstTextView: NSTextView {
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
    let diagnostics: [Diagnostic]
    let reveal: RevealRequest?
    let onChange: (String) -> Void

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
        tv.insertionPointColor = .controlAccentColor
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        let ruler = LineNumberRuler(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onChange = onChange
        guard let tv = c.textView else { return }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if c.documentID != documentID || c.font != font {
            let isNewDocument = c.documentID != documentID
            c.documentID = documentID
            c.font = font
            tv.font = font
            if isNewDocument && tv.string != text {
                tv.string = text
                tv.undoManager?.removeAllActions()
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.scrollToBeginningOfDocument(nil)
            }
            if let storage = tv.textStorage { Highlighter.apply(to: storage, font: font) }
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
        var diagnostics: [Diagnostic] = []
        var reveal: RevealRequest?
        var onChange: (String) -> Void = { _ in }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if let storage = tv.textStorage, let font { Highlighter.apply(to: storage, font: font) }
            onChange(tv.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
        }
    }
}
