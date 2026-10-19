import AppKit
import Observation
import PDFKit

/// Owns the PDFView so toolbar buttons can drive it.
@MainActor @Observable
final class PreviewController {
    private(set) var scale: CGFloat = 1
    private(set) var page = 0
    private(set) var pageCount = 0

    @ObservationIgnored let view: PDFView = {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .underPageBackgroundColor
        return v
    }()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

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

    /// Pages start below the toolbar buttons and end above the glass bar, but scroll under both.
    private func insetForToolbar() {
        guard let scroll = view.documentView?.enclosingScrollView else { return }
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 60, right: 0)
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
