import AppKit
import Observation
import PDFKit

/// Lets floating controls over the PDF override PDFView's text cursor.
final class ArrowAwarePDFView: PDFView {
    override func mouseMoved(with event: NSEvent) {
        if let cursor = CursorArea.cursor(for: event) { cursor.set() } else { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = CursorArea.cursor(for: event) { cursor.set() } else { super.cursorUpdate(with: event) }
    }
}

/// Owns the PDFView so toolbar buttons can drive it.
@MainActor @Observable
final class PreviewController {
    private(set) var scale: CGFloat = 1
    private(set) var autoScales = true
    private(set) var page = 0
    private(set) var pageCount = 0

    @ObservationIgnored let view: PDFView = {
        let v = ArrowAwarePDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        // Clear so the pane's sidebar material shows around the pages.
        v.backgroundColor = .clear
        return v
    }()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var defaultMargins = NSEdgeInsets()
    @ObservationIgnored nonisolated(unsafe) private var magnifyMonitor: Any?
    /// Applied to the next document instead of keeping the current scroll position.
    @ObservationIgnored var pendingRestore: PreviewState?
    /// Like `pendingRestore`, as a position shared with the other previews.
    @ObservationIgnored var pendingPosition: DocumentPosition?
    @ObservationIgnored private var zoomTimer: Timer?

    init() {
        defaultMargins = view.pageBreakMargins
        applyMargins(auto: true)
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            },
            nc.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            },
        ]
        // Pinching zooms manually, so it ends fit-to-width before PDFView handles it.
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.view.autoScales, event.window === self.view.window,
                      self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)) else { return }
                self.view.autoScales = false
                self.sync()
            }
            return event
        }
    }

    deinit {
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
    }

    /// Swaps the document, keeping zoom and scroll position unless told otherwise.
    func show(_ document: PDFDocument?, keepingPosition: Bool = true) {
        guard let document, document !== view.document else { return }
        if pendingRestore == nil, let position = pendingPosition {
            pendingPosition = nil
            pendingRestore = Self.state(for: position, in: document)
        }
        if let state = pendingRestore {
            pendingRestore = nil
            view.document = document
            insetForToolbar()
            // Wait for the first layout so fit-to-width and the destination use the real size.
            DispatchQueue.main.async { self.restore(state) }
            sync()
            return
        }
        guard keepingPosition, view.document != nil, let scroll = view.documentView?.enclosingScrollView else {
            view.document = document
            insetForToolbar()
            sync()
            return
        }
        let origin = scroll.contentView.bounds.origin
        let auto = view.autoScales
        let scale = view.scaleFactor
        view.document = document
        if auto { view.autoScales = true } else { view.scaleFactor = scale }
        view.layoutDocumentView()
        if let newScroll = view.documentView?.enclosingScrollView {
            newScroll.contentView.scroll(to: origin)
            newScroll.reflectScrolledClipView(newScroll.contentView)
        }
        sync()
    }

    /// Pages end above the glass bar but scroll under it.
    private func insetForToolbar() {
        guard let scroll = view.documentView?.enclosingScrollView else { return }
        scroll.automaticallyAdjustsContentInsets = false
        scroll.drawsBackground = false
        // Light knobs vanish over white pages in dark mode.
        scroll.scrollerKnobStyle = .dark
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
    }

    func state() -> PreviewState? {
        guard let doc = view.document, let dest = view.currentDestination, let page = dest.page else { return nil }
        return PreviewState(scale: view.autoScales ? nil : Double(view.scaleFactor),
                            page: doc.index(for: page), x: dest.point.x, y: dest.point.y)
    }

    /// The top of the view as a page position, which the SVG and A4 HTML previews understand too.
    func position() -> DocumentPosition? {
        guard let doc = view.document, let dest = view.currentDestination, let page = dest.page else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        let fraction = bounds.height > 0 ? min(max((bounds.maxY - dest.point.y) / bounds.height, 0), 1) : 0
        return DocumentPosition(page: Double(doc.index(for: page)) + fraction,
                                zoom: view.autoScales ? nil : Double(view.scaleFactor))
    }

    private static func state(for position: DocumentPosition, in doc: PDFDocument) -> PreviewState {
        let index = min(max(Int(position.page), 0), max(doc.pageCount - 1, 0))
        let bounds = doc.page(at: index)?.bounds(for: .cropBox) ?? .zero
        let fraction = position.page - Double(index)
        return PreviewState(scale: position.zoom, page: index, x: bounds.minX, y: bounds.maxY - fraction * bounds.height)
    }

    private func restore(_ state: PreviewState) {
        guard let doc = view.document, doc.pageCount > 0 else { return }
        if let scale = state.scale { view.scaleFactor = scale } else { view.autoScales = true }
        view.layoutDocumentView()
        guard let page = doc.page(at: min(state.page, doc.pageCount - 1)) else { return }
        view.go(to: PDFDestination(page: page, at: NSPoint(x: state.x, y: state.y)))
        sync()
    }

    func zoomIn() { animateZoom(to: zoomTarget * 1.25) }
    func zoomOut() { animateZoom(to: zoomTarget / 1.25) }

    func setAutoScales(_ on: Bool) {
        guard on else {
            view.autoScales = false
            return sync()
        }
        applyMargins(auto: true)
        animateZoom(to: view.scaleFactorForSizeToFit) { [weak self] in
            self?.view.autoScales = true
            self?.sync()
        }
    }

    /// Where the running animation is heading, so quick repeated clicks keep stepping.
    @ObservationIgnored private var pendingScale: CGFloat?
    private var zoomTarget: CGFloat { pendingScale ?? view.scaleFactor }

    /// Steps the scale over a short ease-out, keeping the point at the view's center in place.
    private func animateZoom(to target: CGFloat, completion: (() -> Void)? = nil) {
        zoomTimer?.invalidate()
        view.autoScales = false
        let target = min(max(target, view.minScaleFactor), view.maxScaleFactor)
        let start = view.scaleFactor
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard abs(target - start) > 0.001, let page = view.page(for: center, nearest: true) else {
            view.scaleFactor = target
            pendingScale = nil
            completion?()
            return sync()
        }
        let anchor = view.convert(center, to: page)
        let began = CACurrentMediaTime()
        pendingScale = target
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = min((CACurrentMediaTime() - began) / 0.22, 1)
                let eased = 1 - pow(1 - t, 3)
                // Geometric steps feel equally fast at every zoom level.
                self.view.scaleFactor = start * pow(target / start, eased)
                self.keep(anchor, on: page, at: center)
                guard t >= 1 else { return }
                timer.invalidate()
                self.zoomTimer = nil
                self.pendingScale = nil
                completion?()
                self.sync()
            }
        }
    }

    /// Scrolls so `point` on `page` sits at `target` in the view again.
    private func keep(_ point: NSPoint, on page: PDFPage, at target: NSPoint) {
        guard let scroll = view.documentView?.enclosingScrollView else { return }
        view.layoutDocumentView()
        let now = view.convert(point, from: page)
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.x += now.x - target.x
        // The view's y grows upwards; a flipped document grows downwards.
        origin.y += clip.isFlipped ? target.y - now.y : now.y - target.y
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// Fit-to-width pages span the full pane; zoomed pages keep PDFKit's side margins. No margin above pages.
    private func applyMargins(auto: Bool) {
        var margins = defaultMargins
        if auto { margins.left = 0; margins.right = 0 }
        // The first page starts at the top edge; the gap between pages stays the same.
        margins.bottom += margins.top
        margins.top = 0
        let current = view.pageBreakMargins
        guard current.left != margins.left || current.right != margins.right || current.top != margins.top else { return }
        view.pageBreakMargins = margins
    }

    private func sync() {
        applyMargins(auto: view.autoScales)
        scale = view.scaleFactor
        autoScales = view.autoScales
        pageCount = view.document?.pageCount ?? 0
        if let p = view.currentPage, let doc = view.document { page = doc.index(for: p) }
    }
}
