import AppKit
import Observation
import WebKit

/// Shows typst's pages as SVGs and replaces only the pages that changed, so edits appear without a reload.
@MainActor @Observable
final class SVGPreviewController: NSObject, WKNavigationDelegate {
    /// Zoom used when not fitting to width; 1 shows one typst point per screen point, like PDFView.
    private(set) var scale: CGFloat = 1
    private(set) var autoScales = true
    private(set) var pageCount = 0
    /// Width of the first page in points, to show the fit-to-width zoom.
    private(set) var pageWidth: CGFloat?
    private(set) var viewWidth: CGFloat = 0

    /// Inverts the pages while the app is dark; off keeps them white like paper.
    var darkMode = UserDefaults.standard.object(forKey: "svgDarkMode") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(darkMode, forKey: "svgDarkMode")
            applyAppearance()
        }
    }

    var effectiveScale: CGFloat {
        guard autoScales else { return scale }
        guard let pageWidth, pageWidth > 0, viewWidth > 0 else { return 1 }
        return viewWidth / pageWidth
    }

    @ObservationIgnored let view: WKWebView
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private let scrollReporter = ScrollReporter()
    @ObservationIgnored private var pagePosition = 0.0
    /// Scroll and zoom to apply once the next document is on screen.
    @ObservationIgnored var pendingRestore: DocumentPosition? {
        didSet { if pendingRestore != nil { restoreIfShown() } }
    }

    func position() -> DocumentPosition {
        DocumentPosition(page: pagePosition, zoom: autoScales ? nil : Double(scale))
    }

    /// Applies the pending state when the pages it's meant for are already shown.
    private func restoreIfShown() {
        guard isReady, !isSending, let pending, pending == sent, !sent.isEmpty, let state = pendingRestore else { return }
        pendingRestore = nil
        if let zoom = state.zoom {
            scale = CGFloat(zoom)
            autoScales = false
        } else {
            autoScales = true
        }
        pagePosition = state.page
        view.callAsyncJavaScript("tw.setZoom(auto, scale, false); " + ScrollReporter.restoreScript,
                                 arguments: ["auto": autoScales, "scale": scale, "page": state.page, "fraction": 0],
                                 in: nil, in: .page)
    }
    @ObservationIgnored private var pending: [String]?
    @ObservationIgnored private var sent: [String] = []
    @ObservationIgnored private var isSending = false
    @ObservationIgnored nonisolated(unsafe) private var frameObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var magnifyMonitor: Any?

    override init() {
        let config = WKWebViewConfiguration()
        scrollReporter.install(in: config.userContentController)
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        scrollReporter.onScroll = { [weak self] _, page in if let page { self?.pagePosition = page } }
        view.navigationDelegate = self
        // Pages float on the pane's material, like the PDF preview.
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.postsFrameChangedNotifications = true
        applyAppearance()
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewWidth = self?.view.bounds.width ?? 0 }
        }
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.view.window else { return false }
                let point = self.view.convert(event.locationInWindow, from: nil)
                guard self.view.bounds.contains(point) else { return false }
                // WKWebView is flipped, so this is already the page's client position.
                self.setScale(self.effectiveScale * (1 + event.magnification), animated: false, around: point)
                return true
            }
            return handled ? nil : event
        }
        view.loadHTMLString(Self.shell, baseURL: nil)
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
    }

    func show(_ pages: [String]?) {
        guard let pages else { return }
        pending = pages
        pageCount = pages.count
        pageWidth = pages.first.flatMap(Self.width)
        send()
    }

    /// Forcing light appearance makes `prefers-color-scheme` light inside the page.
    private func applyAppearance() {
        view.appearance = darkMode ? nil : NSAppearance(named: .aqua)
    }

    func zoomIn() { setScale(effectiveScale * 1.25, animated: true) }
    func zoomOut() { setScale(effectiveScale / 1.25, animated: true) }

    func fitToWidth() {
        autoScales = true
        applyZoom(animated: true)
    }

    /// `point` stays on the same spot of the document, like the pointer while pinching.
    private func setScale(_ value: CGFloat, animated: Bool, around point: NSPoint? = nil) {
        scale = min(max(value, 0.1), 8)
        autoScales = false
        applyZoom(animated: animated, around: point)
    }

    private func applyZoom(animated: Bool, around point: NSPoint? = nil) {
        guard isReady else { return }
        let anchor: Any = point.map { [Double($0.x), Double($0.y)] } ?? NSNull()
        view.callAsyncJavaScript("tw.setZoom(auto, scale, animated, anchor)",
                                 arguments: ["auto": autoScales, "scale": scale, "animated": animated, "anchor": anchor],
                                 in: nil, in: .page)
    }

    /// Sends only the pages that differ from what the page shows; the next update waits for this one.
    private func send() {
        guard isReady, !isSending, let pages = pending, pages != sent else { return restoreIfShown() }
        isSending = true
        var changes: [String: String] = [:]
        for (i, page) in pages.enumerated() where i >= sent.count || sent[i] != page { changes[String(i)] = page }
        sent = pages
        view.callAsyncJavaScript("tw.update(changes, count)", arguments: ["changes": changes, "count": pages.count],
                                 in: nil, in: .page) { [weak self] _ in
            guard let self else { return }
            self.isSending = false
            self.send()
        }
    }

    /// Reads the page width from the `viewBox` typst writes into every page.
    private static func width(of svg: String) -> CGFloat? {
        guard let range = svg.range(of: "viewBox=\"") else { return nil }
        let numbers = svg[range.upperBound...].prefix { $0 != "\"" }.split(separator: " ")
        return numbers.count == 4 ? Double(numbers[2]).map { CGFloat($0) } : nil
    }

    // MARK: - Page

    private static let shell = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; background: transparent; }
        body { padding: 0 0 88px; }
        /* Auto margins center pages only while they fit; wider ones start at the left edge instead of overflowing past it. */
        #pages { display: flex; flex-direction: column; align-items: flex-start; gap: 12px; }
        .page { background: white; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.25); line-height: 0; width: 100%;
          margin: 0 auto; flex-shrink: 0; }
        .page svg { display: block; width: 100%; height: auto; }
        .tw-animating .page { transition: width 0.22s cubic-bezier(0.33, 1, 0.68, 1); }
        /* Only the drawing is inverted, so the page shadow stays dark; images are turned back. */
        @media (prefers-color-scheme: dark) {
          .page { background: black; }
          .page > svg, .page > svg image { filter: invert(1) hue-rotate(180deg); }
        }
        </style><script>
        window.tw = {
          auto: true, scale: 1,

          update(changes, count) {
            const box = document.getElementById('pages');
            while (box.children.length > count) box.lastElementChild.remove();
            while (box.children.length < count) {
              const page = document.createElement('div');
              page.className = 'page';
              box.append(page);
            }
            for (const [i, svg] of Object.entries(changes)) box.children[+i].innerHTML = svg;
            this.layout();
          },

          setZoom(auto, scale, animated, anchor) {
            this.auto = auto;
            this.scale = scale;
            if (anchor) return this.zoomAround(anchor[0], anchor[1]);
            if (!animated) return this.layout();
            // Keep the middle of the view on the same spot of the document while the pages resize.
            const root = document.documentElement;
            const anchor = (scrollY + innerHeight / 2) / root.scrollHeight;
            const anchorX = (scrollX + innerWidth / 2) / root.scrollWidth;
            root.classList.add('tw-animating');
            this.layout();
            const end = performance.now() + 260;
            const follow = () => {
              scrollTo(anchorX * root.scrollWidth - innerWidth / 2, anchor * root.scrollHeight - innerHeight / 2);
              if (performance.now() < end) requestAnimationFrame(follow);
              else root.classList.remove('tw-animating');
            };
            requestAnimationFrame(follow);
          },

          // Keeps the spot under the pointer in place: same fraction of the same page, before and after.
          zoomAround(x, y) {
            const pages = [...document.getElementById('pages').children];
            const before = pages.map(p => p.getBoundingClientRect());
            let i = before.findIndex(r => y >= r.top && y <= r.bottom);
            if (i < 0) i = before.findIndex(r => y < r.top);
            if (i < 0) i = before.length - 1;
            if (i < 0) return this.layout();
            const r = before[i];
            const fx = r.width ? (x - r.left) / r.width : 0, fy = r.height ? (y - r.top) / r.height : 0;
            this.layout();
            const after = pages[i].getBoundingClientRect();
            scrollBy(after.left + fx * after.width - x, after.top + fy * after.height - y);
          },

          layout() {
            for (const page of document.getElementById('pages').children) {
              const svg = page.firstElementChild;
              const natural = svg && svg.viewBox && svg.viewBox.baseVal ? svg.viewBox.baseVal.width : 0;
              page.style.width = this.auto || !natural ? '100%' : (natural * this.scale) + 'px';
            }
          },
        };
        </script></head><body><div id="pages"></div></body></html>
        """

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        viewWidth = view.bounds.width
        sent = []
        applyZoom(animated: false)
        send()
    }

    /// Links in the document open in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }
}
