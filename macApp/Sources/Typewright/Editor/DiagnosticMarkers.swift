import AppKit
import SwiftUI

/// Errors and warnings as ticks along the scroll bar, like Xcode's; hovering one previews it, clicking jumps there.
final class DiagnosticMarkers: NSView {
    static let width: CGFloat = 10

    private weak var textView: NSTextView?
    /// Diagnostics with the text they cover.
    var diagnostics: [(range: NSRange, diagnostic: Diagnostic)] = [] {
        didSet { refresh() }
    }
    /// The fence language of the line excerpt in the preview.
    var language = "typ"
    /// Kept clear at the top, like the scroll view's content inset.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { place() } }
    }

    private struct Marker {
        let y: CGFloat
        let range: NSRange
        let diagnostics: [Diagnostic]
        var isError: Bool { diagnostics.contains { $0.severity == .error } }
    }

    private var markers: [Marker] = []
    private var hovered: Int?
    private var panel: NSPanel?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.frameDidChangeNotification, object: textView)
        guard let superview else { return }
        superview.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: superview)
        place()
    }

    /// Along the scroll view's right edge, below the inset.
    @objc private func place() {
        guard let superview else { return }
        let bounds = superview.bounds
        let height = max(bounds.height - topInset, 0)
        frame = NSRect(x: bounds.width - Self.width, y: superview.isFlipped ? topInset : 0, width: Self.width, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refresh()
    }

    /// Lines map onto the strip like the scroll bar maps the document onto its track.
    @objc func refresh() {
        defer { needsDisplay = true }
        guard let tv = textView, let lm = tv.layoutManager, tv.frame.height > 0, bounds.height > 0 else { return markers = [] }
        let length = (tv.string as NSString).length
        var rows: [Int: (range: NSRange, diagnostics: [Diagnostic])] = [:]
        for (range, diagnostic) in diagnostics.prefix(1000) where NSMaxRange(range) <= length {
            let glyph = lm.glyphIndexForCharacter(at: min(range.location, max(length - 1, 0)))
            let rect = length == 0 ? .zero : lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let fraction = (rect.midY + tv.textContainerOrigin.y) / tv.frame.height
            // Diagnostics closer than a tick merge into one.
            let row = Int((fraction * bounds.height / 4).rounded())
            rows[row, default: (range, [])].diagnostics.append(diagnostic)
        }
        markers = rows.sorted { $0.key < $1.key }.map { row, value in
            Marker(y: min(max(CGFloat(row) * 4, 2), bounds.height - 2), range: value.range, diagnostics: value.diagnostics)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, marker) in markers.enumerated() {
            let color: NSColor = marker.isError ? .systemRed : .systemYellow
            color.withAlphaComponent(i == hovered ? 1 : 0.85).setFill()
            let height: CGFloat = i == hovered ? 4 : 3
            NSBezierPath(roundedRect: NSRect(x: 2, y: marker.y - height / 2, width: bounds.width - 4, height: height),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    private func marker(at point: NSPoint) -> Int? {
        guard point.x >= 0, point.x <= bounds.width else { return nil }
        let nearest = markers.indices.min { abs(markers[$0].y - point.y) < abs(markers[$1].y - point.y) }
        return nearest.flatMap { abs(markers[$0].y - point.y) <= 4 ? $0 : nil }
    }

    /// Whether a window point is on a tick, where the arrow replaces the text cursor.
    func hasMarker(atWindowPoint point: NSPoint) -> Bool {
        !isHiddenOrHasHiddenAncestor && marker(at: convert(point, from: nil)) != nil
    }

    // Only the ticks take the pointer; between them the scroll bar underneath works as usual.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return marker(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = marker(at: convert(event.locationInWindow, from: nil))
        if index != nil { NSCursor.arrow.set() }
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
        if let index { showPreview(of: markers[index]) } else { hidePreview() }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        hidePreview()
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = marker(at: convert(event.locationInWindow, from: nil)), let tv = textView else { return }
        hidePreview()
        let range = markers[index].range
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: range.location, length: 0))
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range.length > 0 ? range : (tv.string as NSString).lineRange(for: range))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hidePreview() }
    }

    // MARK: - Preview

    private func showPreview(of marker: Marker) {
        hidePreview()
        guard let tv = textView, let window else { return }
        let s = tv.string as NSString
        guard NSMaxRange(marker.range) <= s.length else { return }
        let line = s.substring(with: s.lineRange(for: NSRange(location: marker.range.location, length: 0)))
            .trimmingCharacters(in: .newlines)
        let excerpt = line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "```\(language)\n\(line)\n```"
        let host = NSHostingView(rootView: HoverContent(errors: marker.diagnostics, markdown: excerpt, width: HoverContent.baseWidth,
                                                        fixes: { _ in [] }, onClose: {}, onSize: { _ in }))
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.frame.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.contentView = host
        // Left of the strip, centered on the tick, kept on screen.
        let tick = window.convertToScreen(convert(NSRect(x: 0, y: marker.y, width: 0, height: 0), to: nil))
        let screen = window.screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: tick.minX - host.frame.width - 6, y: tick.minY - host.frame.height / 2)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - host.frame.height)
        origin.x = max(origin.x, screen.minX)
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
    }

    private func hidePreview() {
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
