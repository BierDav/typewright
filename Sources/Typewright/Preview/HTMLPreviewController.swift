import AppKit
import Observation
import WebKit

/// Owns the web view for typst's HTML output and patches only the changed blocks between compiles.
@MainActor @Observable
final class HTMLPreviewController: NSObject, WKNavigationDelegate {
    /// Zoom chosen by the user; A4 pages additionally scale to fit the width.
    private(set) var zoom: CGFloat = 1
    private(set) var fit: CGFloat = 1
    var effectiveZoom: CGFloat { zoom * (pages ? fit : 1) }

    var darkMode = UserDefaults.standard.object(forKey: "htmlDarkMode") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(darkMode, forKey: "htmlDarkMode")
            applyAppearance()
        }
    }

    var pages = UserDefaults.standard.bool(forKey: "htmlPages") {
        didSet {
            UserDefaults.standard.set(pages, forKey: "htmlPages")
            updateFit()
            if isReady { view.evaluateJavaScript("tw.setPages(\(pages))") }
        }
    }

    @ObservationIgnored let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

    @ObservationIgnored private var loadedBase: URL?
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var pending: String?
    @ObservationIgnored private var sent: String?
    @ObservationIgnored private var isSending = false
    @ObservationIgnored nonisolated(unsafe) private var frameObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var magnifyMonitor: Any?

    override init() {
        super.init()
        view.navigationDelegate = self
        view.postsFrameChangedNotifications = true
        applyAppearance()
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFit() }
        }
        // Pinching changes the zoom so text reflows instead of being scaled.
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.view.window,
                      self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)) else { return false }
                self.setZoom(self.zoom * (1 + event.magnification))
                return true
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
    }

    func show(_ html: String?, baseURL: URL) {
        guard let html else { return }
        pending = html
        if loadedBase != baseURL {
            loadedBase = baseURL
            isReady = false
            sent = nil
            view.loadHTMLString(shell, baseURL: baseURL)
        } else {
            send()
        }
    }

    func zoomIn() { setZoom(zoom * 1.1) }
    func zoomOut() { setZoom(zoom / 1.1) }
    func resetZoom() { setZoom(1) }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 0.25), 5)
        view.pageZoom = effectiveZoom
    }

    /// A4 is 210mm = 794 CSS px; the sheet spans the full width.
    private func updateFit() {
        let width = view.bounds.width
        fit = width > 0 ? min(1, width / 794) : 1
        view.pageZoom = effectiveZoom
    }

    /// Forcing light appearance makes `prefers-color-scheme` light inside the page.
    private func applyAppearance() {
        view.appearance = darkMode ? nil : NSAppearance(named: .aqua)
    }

    /// Sends the newest output once the previous update is applied, so fast typing never queues stale pages.
    private func send() {
        guard isReady, !isSending, let html = pending, html != sent else { return }
        isSending = true
        sent = html
        view.callAsyncJavaScript("tw.update(html)", arguments: ["html": html], in: nil, in: .page) { [weak self] _ in
            guard let self else { return }
            self.isSending = false
            self.send()
        }
    }

    // MARK: - Page

    private var shell: String {
        "<!DOCTYPE html><html class=\"\(pages ? "tw-paged" : "")\"><head><meta charset=\"utf-8\">"
            + "<style>\(Self.style)</style><script>\(Self.script)\ntw.pages = \(pages);</script></head><body></body></html>"
    }

    // Typst frames (math, figures) are SVGs with black ink, so they get inverted in dark mode.
    private static let style = """
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 24px 28px 88px; font: 16px/1.55 -apple-system, sans-serif; }
        :root:not(.tw-paged) body > * { max-width: 46em; margin-left: auto; margin-right: auto; }
        img, svg { max-width: 100%; }
        .tw-paged body { padding: 18px 0 88px; background: color-mix(in srgb, CanvasText 7%, Canvas); }
        .tw-pages { display: flex; flex-direction: column; align-items: center; gap: 18px; }
        .tw-page {
          box-sizing: border-box; width: 210mm; min-height: 297mm; padding: 25mm;
          background: Canvas; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.25);
          font: 11pt/1.4 "New Computer Modern", "Libertinus Serif", Georgia, serif; overflow-wrap: break-word;
        }
        .tw-page > :first-child { margin-top: 0; }
        @media (prefers-color-scheme: dark) { svg { filter: invert(1) hue-rotate(180deg); } }
        """

    /// Keeps the rendered top-level blocks and swaps only the range that differs from the new output.
    private static let script = """
        window.tw = {
          nodes: [], sources: [], head: [], headSource: null, pages: false, wrap: null,

          update(html) {
            const doc = new DOMParser().parseFromString(html, 'text/html');
            if (doc.head.innerHTML !== this.headSource) {
              this.headSource = doc.head.innerHTML;
              this.head.forEach(n => n.remove());
              this.head = [...doc.head.children].filter(n => n.tagName !== 'SCRIPT')
                .map(n => document.head.appendChild(document.adoptNode(n)));
            }
            const fresh = [...doc.body.children];
            const sources = fresh.map(n => n.outerHTML);
            const old = this.sources;
            let p = 0;
            while (p < old.length && p < sources.length && old[p] === sources[p]) p++;
            let q = 0;
            while (q < old.length - p && q < sources.length - p
                   && old[old.length - 1 - q] === sources[sources.length - 1 - q]) q++;
            const anchor = this.nodes[old.length - q] || null;
            const parent = anchor ? anchor.parentNode : (p > 0 ? this.nodes[p - 1].parentNode : this.container());
            this.nodes.slice(p, old.length - q).forEach(n => n.remove());
            const added = fresh.slice(p, sources.length - q).map(n => document.adoptNode(n));
            for (const n of added) parent.insertBefore(n, anchor);
            this.nodes = [...this.nodes.slice(0, p), ...added, ...this.nodes.slice(old.length - q)];
            this.sources = sources;
            if (this.pages) this.paginate();
          },

          container() {
            if (!this.pages) return document.body;
            if (!this.wrap) {
              this.wrap = document.createElement('div');
              this.wrap.className = 'tw-pages';
              document.body.append(this.wrap);
            }
            return this.wrap.firstElementChild || this.wrap.appendChild(this.newPage());
          },

          newPage() {
            const page = document.createElement('div');
            page.className = 'tw-page';
            return page;
          },

          setPages(on) {
            this.pages = on;
            document.documentElement.classList.toggle('tw-paged', on);
            if (on) {
              this.container().append(...this.nodes);
              this.paginate();
            } else if (this.wrap) {
              document.body.append(...this.nodes);
              this.wrap.remove();
              this.wrap = null;
            }
          },

          // Measures every block once, then moves only the blocks whose page changed.
          paginate() {
            this.container();
            const limit = 247 * 96 / 25.4;
            const assign = [];
            let page = 0, used = 0, prevBottom = 0;
            for (const n of this.nodes) {
              const s = getComputedStyle(n);
              const h = n.offsetHeight, top = parseFloat(s.marginTop) || 0, bottom = parseFloat(s.marginBottom) || 0;
              let need = used === 0 ? h : Math.max(prevBottom, top) + h;
              if (used > 0 && used + need > limit) { page++; used = 0; need = h; }
              used += need;
              prevBottom = bottom;
              assign.push(page);
            }
            const pages = [...this.wrap.children];
            const count = page + 1;
            while (pages.length < count) pages.push(this.wrap.appendChild(this.newPage()));
            this.nodes.forEach((n, i) => {
              const target = pages[assign[i]];
              const prev = i > 0 && assign[i - 1] === assign[i] ? this.nodes[i - 1] : null;
              if (n.parentNode === target && n.previousElementSibling === prev) return;
              if (prev) prev.after(n); else target.prepend(n);
            });
            pages.slice(count).forEach(p => p.remove());
          },
        };
        """

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        updateFit()
        send()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Start over with a fresh shell next time.
        loadedBase = nil
    }

    /// Links open in the browser; in-page anchors scroll the preview.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        let current = webView.url?.absoluteString.components(separatedBy: "#").first ?? ""
        if url.fragment != nil, url.absoluteString.hasPrefix(current + "#") { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }
}
