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
    /// Applied to the next document instead of keeping the current scroll position.
    @ObservationIgnored var pendingRestore: PreviewState?

    init() {
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            },
            nc.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            },
        ]
    }

    /// Swaps the document while keeping zoom and scroll position.
    func show(_ document: PDFDocument?) {
        guard let document, document !== view.document else { return }
        if let state = pendingRestore {
            pendingRestore = nil
            view.document = document
            insetForToolbar()
            // Wait for the first layout so fit-to-width and the destination use the real size.
            DispatchQueue.main.async { self.restore(state) }
            sync()
            return
        }
        guard view.document != nil, let scroll = view.documentView?.enclosingScrollView else {
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
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
    }

    func state() -> PreviewState? {
        guard let doc = view.document, let dest = view.currentDestination, let page = dest.page else { return nil }
        return PreviewState(scale: view.autoScales ? nil : Double(view.scaleFactor),
                            page: doc.index(for: page), x: dest.point.x, y: dest.point.y)
    }

    private func restore(_ state: PreviewState) {
        guard let doc = view.document, doc.pageCount > 0 else { return }
        if let scale = state.scale { view.scaleFactor = scale } else { view.autoScales = true }
        view.layoutDocumentView()
        guard let page = doc.page(at: min(state.page, doc.pageCount - 1)) else { return }
        view.go(to: PDFDestination(page: page, at: NSPoint(x: state.x, y: state.y)))
        sync()
    }

    func zoomIn() { view.zoomIn(nil) }
    func zoomOut() { view.zoomOut(nil) }
    func fit() { view.autoScales = true }

    private func sync() {
        scale = view.scaleFactor
        pageCount = view.document?.pageCount ?? 0
        if let p = view.currentPage, let doc = view.document { page = doc.index(for: p) }
    }
}
