import AppKit
import Observation
@preconcurrency import PDFKit

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
        v.maxScaleFactor = 100
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
    /// Horizontal scroll fraction to restore along with the pending state.
    @ObservationIgnored private var pendingPan: Double?
    @ObservationIgnored private var zoomTimer: Timer?
    @ObservationIgnored private var compiledPages: [CompiledPage] = []

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
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.view.window, self.view.document != nil,
                      self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)) else { return false }
                // ⌘-scroll zooms around the pointer, like pinching.
                if let factor = event.commandZoomFactor {
                    self.zoom(by: factor, at: event.locationInWindow)
                    return true
                }
                guard event.type != .scrollWheel, self.view.autoScales else { return false }
                self.view.autoScales = false
                self.sync()
                return false
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
    }

    /// Swaps the document, keeping zoom and scroll position unless told otherwise.
    func show(_ document: PDFDocument?, keepingPosition: Bool = true) {
        guard let document, document !== view.document else { return }
        withoutAnimation {
            compiledPages.removeAll()
            if pendingRestore == nil, let position = pendingPosition {
                pendingPosition = nil
                pendingRestore = Self.state(for: position, in: document)
                pendingPan = position.pan
            }
            if let state = pendingRestore {
                pendingRestore = nil
                let pan = pendingPan
                pendingPan = nil
                view.document = document
                insetForToolbar()
                // Wait for the first layout so fit-to-width and the destination use the real size.
                DispatchQueue.main.async { self.restore(state, pan: pan) }
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
            insetForToolbar()
            if auto { view.autoScales = true } else { view.scaleFactor = scale }
            view.layoutDocumentView()
            if let newScroll = view.documentView?.enclosingScrollView {
                newScroll.contentView.scroll(to: origin)
                newScroll.reflectScrolledClipView(newScroll.contentView)
            }
            sync()
        }
    }

    /// Keeps PDFKit's unchanged page objects and replaces only newly compiled pages.
    func showPages(_ pages: [CompiledPage]) {
        guard let document = view.document, !compiledPages.isEmpty else {
            let document = PDFDocument()
            for page in pages { document.insert(page.page.copy() as! PDFPage, at: document.pageCount) }
            show(document)
            compiledPages = pages
            return
        }
        let position = pendingPosition ?? self.position()
        let mustRestore = pendingPosition != nil
        pendingPosition = nil
        guard pages != compiledPages || mustRestore else { return }
        withoutAnimation {
            for index in pages.indices {
                if index < compiledPages.count, pages[index] === compiledPages[index] { continue }
                let replacement = pages[index].page.copy() as! PDFPage
                if index < document.pageCount {
                    // Keep a page installed at every visible index while PDFKit updates its layout.
                    document.insert(replacement, at: index)
                    document.removePage(at: index + 1)
                } else {
                    document.insert(replacement, at: index)
                }
            }
            while document.pageCount > pages.count { document.removePage(at: document.pageCount - 1) }
            compiledPages = pages
            view.layoutDocumentView()
            if let position, mustRestore || self.position() != position {
                restore(Self.state(for: position, in: document), pan: position.pan)
            }
            // PDFKit's crossfade reveals the page before its text tiles finish rendering.
            view.documentView?.layer?.removeAnimation(forKey: "transition")
            sync()
        }
    }

    private func withoutAnimation(_ update: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            update()
            CATransaction.commit()
        }
    }

    /// Empties the view when another file is previewed, so the old document never stands in for the new one.
    func clear() {
        compiledPages.removeAll()
        guard view.document != nil else { return }
        view.document = nil
        sync()
    }

    /// Pages end above the glass bar but scroll under it.
    private func insetForToolbar() {
        guard let scroll = view.documentView?.enclosingScrollView else { return }
        scroll.automaticallyAdjustsContentInsets = false
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        // Light knobs vanish over white pages in dark mode.
        scroll.scrollerKnobStyle = .dark
        // PDFKit's clip is flipped, so `top` is the space under the glass bar; a bottom inset would
        // reserve it above the pages and shrink the scroll range, which breaks every restored spot.
        scroll.contentInsets = NSEdgeInsets(top: 76, left: 0, bottom: 0, right: 0)
    }

    func state() -> PreviewState? {
        guard let doc = view.document, let dest = topDestination(), let page = dest.page else { return nil }
        return PreviewState(scale: view.autoScales ? nil : Double(view.scaleFactor),
                            page: doc.index(for: page), x: dest.point.x, y: dest.point.y)
    }

    /// The top of the view as a page position, which the SVG and A4 HTML previews understand too.
    func position() -> DocumentPosition? {
        guard let doc = view.document, let dest = topDestination(), let page = dest.page else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        let fraction = bounds.height > 0 ? min(max((bounds.maxY - dest.point.y) / bounds.height, 0), 1) : 0
        var pan = 0.0
        if let clip = view.documentView?.enclosingScrollView?.contentView, let width = view.documentView?.frame.width,
           width > clip.bounds.width {
            pan = min(max((clip.bounds.minX - clip.documentRect.minX) / (width - clip.bounds.width), 0), 1)
        }
        return DocumentPosition(page: Double(doc.index(for: page)) + fraction,
                                zoom: view.autoScales ? nil : Double(view.scaleFactor), pan: pan)
    }

    private func topDestination() -> PDFDestination? {
        guard let page = view.page(for: visibleTop, nearest: true) else { return nil }
        return PDFDestination(page: page, at: view.convert(visibleTop, to: page))
    }

    private static func state(for position: DocumentPosition, in doc: PDFDocument) -> PreviewState {
        let index = min(max(Int(position.page), 0), max(doc.pageCount - 1, 0))
        let bounds = doc.page(at: index)?.bounds(for: .cropBox) ?? .zero
        let fraction = position.page - Double(index)
        return PreviewState(scale: position.zoom, page: index, x: bounds.minX, y: bounds.maxY - fraction * bounds.height)
    }

    private func restore(_ state: PreviewState, pan: Double? = nil) {
        guard let doc = view.document, doc.pageCount > 0 else { return }
        if let scale = state.scale {
            if view.scaleFactor != scale { view.scaleFactor = scale }
        } else if !view.autoScales { view.autoScales = true }
        view.layoutDocumentView()
        let index = min(state.page, doc.pageCount - 1)
        guard let page = doc.page(at: index) else { return }
        view.go(to: PDFDestination(page: page, at: NSPoint(x: state.x, y: state.y)))
        align(index: index, to: NSPoint(x: state.x, y: state.y), pan: pan, attempt: 0)
        sync()
    }

    /// Puts `point` on the page at the pane's top edge, and keeps it there once PDFKit has laid the pages out.
    private func align(index: Int, to point: NSPoint, pan: Double?, attempt: Int) {
        guard let doc = view.document, let page = doc.page(at: min(index, max(doc.pageCount - 1, 0))) else { return }
        // Use the visible top edge instead of PDFKit's inset-adjusted destination.
        keep(point, on: page, at: visibleTop)
        applyPan(pan)
        // PDFKit scrolls to its own destination after the next layout, which would undo this alignment.
        guard attempt < 2 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let page = self.view.document?.page(at: index) else { return }
            // Overlay scrollers can change the available width after the first layout.
            self.applyPan(pan)
            let bounds = page.bounds(for: self.view.displayBox)
            guard bounds.height > 0, let now = self.position() else { return }
            let target = Double(index) + (bounds.maxY - point.y) / bounds.height
            guard abs(now.page - target) * bounds.height > 1 else { return }
            self.align(index: index, to: point, pan: pan, attempt: attempt + 1)
        }
    }

    private var visibleTop: NSPoint {
        NSPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY)
    }

    private func applyPan(_ pan: Double?) {
        guard let pan, let scroll = view.documentView?.enclosingScrollView,
              let width = view.documentView?.frame.width else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.x = clip.documentRect.minX + pan * max(width - clip.bounds.width, 0)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// Keeps the spot under `windowPoint` in place while the scale changes.
    func zoom(by factor: CGFloat, at windowPoint: NSPoint) {
        let point = view.convert(windowPoint, from: nil)
        guard let page = view.page(for: point, nearest: true) else { return }
        let pagePoint = view.convert(point, to: page)
        let index = view.document?.index(for: page) ?? 0
        view.autoScales = false
        view.scaleFactor = min(max(view.scaleFactor * factor, view.minScaleFactor), view.maxScaleFactor)
        keep(pagePoint, on: page, at: point)
        settleZoom(index: index, point: pagePoint, at: point)
        sync()
    }

    /// Puts the zoomed spot back under the pointer, which PDFKit moves when it relays the pages.
    private func settleZoom(index: Int, point: NSPoint, at target: NSPoint) {
        let scale = view.scaleFactor
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.scaleFactor == scale, let page = self.view.document?.page(at: index) else { return }
            self.view.layoutDocumentView()
            let now = self.view.convert(point, from: page)
            guard abs(now.x - target.x) > 1 || abs(now.y - target.y) > 1 else { return }
            self.keep(point, on: page, at: target)
            self.sync()
        }
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
        let pageIndex = view.document?.index(for: page) ?? 0
        let began = CACurrentMediaTime()
        pendingScale = target
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = min((CACurrentMediaTime() - began) / 0.22, 1)
                let eased = 1 - pow(1 - t, 3)
                // Geometric steps feel equally fast at every zoom level.
                self.view.scaleFactor = start * pow(target / start, eased)
                // Look the page up again so the sendable timer closure holds no PDFPage.
                if let page = self.view.document?.page(at: pageIndex) { self.keep(anchor, on: page, at: center) }
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
        let clip = scroll.contentView
        let now = clip.convert(view.convert(point, from: page), from: view)
        let target = clip.convert(target, from: view)
        var origin = clip.bounds.origin
        origin.x += now.x - target.x
        origin.y += now.y - target.y
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
