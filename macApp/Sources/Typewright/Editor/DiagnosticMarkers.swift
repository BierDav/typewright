import AppKit
import SwiftUI

/// Errors and warnings as ticks along the scroll bar, like Xcode's; hovering one previews it, clicking jumps there.
final class DiagnosticMarkers: NSView {
    /// Tick height; ticks closer than this merge.
    private static let tick: CGFloat = 9

    private weak var textView: NSTextView?
    /// Diagnostics with the text they cover.
    var diagnostics: [(range: NSRange, diagnostic: Diagnostic)] = [] {
        didSet { refresh() }
    }
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

    /// Over the vertical scroll bar, below the inset.
    @objc private func place() {
        guard let superview else { return }
        let bounds = superview.bounds
        let height = max(bounds.height - topInset, 0)
        let style = (superview as? NSScrollView)?.scrollerStyle ?? .overlay
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
        frame = NSRect(x: bounds.width - width, y: superview.isFlipped ? topInset : 0, width: width, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refresh()
    }

    /// Lines map onto the strip like the scroll bar maps the document onto its track.
    @objc func refresh() {
        defer { layoutMarkers(animated: false) }
        guard let tv = textView, let lm = tv.layoutManager, tv.frame.height > 0, bounds.height > 0 else { return markers = [] }
        let length = (tv.string as NSString).length
        var rows: [Int: (range: NSRange, diagnostics: [Diagnostic])] = [:]
        for (range, diagnostic) in diagnostics.prefix(1000) where NSMaxRange(range) <= length {
            let glyph = lm.glyphIndexForCharacter(at: min(range.location, max(length - 1, 0)))
            let rect = length == 0 ? .zero : lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let fraction = (rect.midY + tv.textContainerOrigin.y) / tv.frame.height
            // Diagnostics closer than a tick merge into one.
            let row = Int((fraction * bounds.height / Self.tick).rounded())
            rows[row, default: (range, [])].diagnostics.append(diagnostic)
        }
        markers = rows.sorted { $0.key < $1.key }.map { row, value in
            Marker(y: min(max(CGFloat(row) * Self.tick, Self.tick / 2), bounds.height - Self.tick / 2), range: value.range,
                   diagnostics: value.diagnostics)
        }
    }

    private var markerLayers: [CALayer] = []

    /// One layer per tick, so the hovered one can grow with an animation.
    private func layoutMarkers(animated: Bool) {
        wantsLayer = true
        guard let layer else { return }
        while markerLayers.count < markers.count {
            let l = CALayer()
            l.cornerRadius = 1.5
            layer.addSublayer(l)
            markerLayers.append(l)
        }
        while markerLayers.count > markers.count { markerLayers.removeLast().removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (i, marker) in markers.enumerated() {
            let height = height(of: i)
            let color: NSColor = marker.isError ? .systemRed : .systemYellow
            markerLayers[i].backgroundColor = color.withAlphaComponent(i == hovered ? 1 : 0.85).cgColor
            // The layer tree isn't flipped; ticks count from the top.
            markerLayers[i].frame = NSRect(x: 0, y: bounds.height - marker.y - height / 2, width: bounds.width, height: height)
        }
        CATransaction.commit()
    }

    private func height(of index: Int) -> CGFloat { index == hovered ? Self.tick * 2 : Self.tick - 1 }

    private func marker(at point: NSPoint) -> Int? {
        guard point.x >= 0, point.x <= bounds.width else { return nil }
        if let hovered, hovered < markers.count, abs(markers[hovered].y - point.y) <= height(of: hovered) / 2 { return hovered }
        let nearest = markers.indices.min { abs(markers[$0].y - point.y) < abs(markers[$1].y - point.y) }
        return nearest.flatMap { abs(markers[$0].y - point.y) <= Self.tick / 2 ? $0 : nil }
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
        // Always, since the preview takes key once its text is clicked.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { follow(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { follow(event.locationInWindow) }

    private func follow(_ windowPoint: NSPoint) {
        guard let index = marker(at: convert(windowPoint, from: nil)) else { return }
        NSCursor.arrow.set()
        hover(index)
    }

    private func hover(_ index: Int) {
        leftAt = nil
        guard index != hovered else { return }
        hovered = index
        layoutMarkers(animated: true)
        showPreview(of: markers[index])
        startWatching()
    }

    private var watch: Timer?
    /// When the pointer left the tick for somewhere other than the preview.
    private var leftAt: Date?

    /// Tracking events miss moves over other windows and the preview, so the pointer is checked while it shows.
    private func startWatching() {
        guard watch == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private func check() {
        guard let window, hovered != nil else { return hidePreview() }
        let screenPoint = NSEvent.mouseLocation
        if let panel, panel.frame.insetBy(dx: -2, dy: -2).contains(screenPoint) {
            leftAt = nil
            return
        }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        if let index = marker(at: point) { return hover(index) }
        // Along the scroll bar the pointer isn't heading for the preview.
        if bounds.contains(point) { return hidePreview() }
        // Elsewhere a short grace period lets it cross over to the preview, to select and copy its text.
        if let leftAt {
            if Date().timeIntervalSince(leftAt) > 0.3 { hidePreview() }
        } else {
            leftAt = Date()
        }
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
        removePanel()
        guard let tv = textView, let window else { return }
        let s = tv.string as NSString
        guard NSMaxRange(marker.range) <= s.length else { return }
        let host = NSHostingView(rootView: HoverContent(errors: marker.diagnostics, markdown: nil, width: HoverContent.baseWidth,
                                                        fixes: { _ in [] }, onClose: { [weak self] in self?.hidePreview() },
                                                        onSize: { _ in }))
        host.frame.size = host.fittingSize
        // Takes key on a click, so its text can be selected and copied.
        let panel = HoverPanel(contentRect: NSRect(origin: .zero, size: host.frame.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.becomesKey = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = host
        // Left of the strip, centered on the tick, kept on screen.
        let tick = window.convertToScreen(convert(NSRect(x: 0, y: marker.y, width: 0, height: 0), to: nil))
        let screen = window.screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: tick.minX - host.frame.width - 2, y: tick.minY - host.frame.height / 2)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - host.frame.height)
        origin.x = max(origin.x, screen.minX)
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
    }

    private func hidePreview() {
        watch?.invalidate()
        watch = nil
        leftAt = nil
        if hovered != nil {
            hovered = nil
            layoutMarkers(animated: true)
        }
        removePanel()
    }

    private func removePanel() {
        guard let panel else { return }
        self.panel = nil
        let parent = panel.parent
        let wasKey = panel.isKeyWindow
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if wasKey { parent?.makeKey() }
    }
}
