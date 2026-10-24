import AppKit
import CoreText
import Observation
import UniformTypeIdentifiers
import WebKit

/// Owns the web view for typst's HTML output, or rendered Markdown, and patches only the changed blocks.
@MainActor @Observable
final class HTMLPreviewController: NSObject, WKNavigationDelegate {
    /// Shows Markdown with GitHub's look instead of typst's HTML; it never has pages.
    let isMarkdown: Bool
    /// A4 zoom in points per screen point, like the PDF preview; nil fits the width.
    private(set) var pageScale: CGFloat?
    private(set) var fitScale: CGFloat = 1
    @ObservationIgnored private var zoomTimer: Timer?
    var effectiveScale: CGFloat { pageScale ?? fitScale }
    /// A4 pages zoom; reflowing text changes its size instead.
    var paged: Bool { !isMarkdown && pages }
    /// 210 mm is 794 CSS pixels but 595 points.
    private static let pointsPerPixel: CGFloat = 595.28 / 793.7
    private var pageZoom: CGFloat { paged ? effectiveScale * Self.pointsPerPixel : 1 }

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
            if isReady { view.evaluateJavaScript("tw.setPages(\(paged))") }
        }
    }

    @ObservationIgnored let view: WKWebView
    @ObservationIgnored private let fontHandler = FontSchemeHandler()
    @ObservationIgnored private var fontCSS = ""

    /// Folders whose fonts the page may use; WebKit only sees installed fonts on its own.
    private(set) var fontDirectories: [URL] = []

    /// Rescans even for the same folders, since fonts inside them may have been added or replaced.
    func setFontDirectories(_ dirs: [URL]) {
        fontDirectories = dirs
        loadFonts()
    }

    @ObservationIgnored private var loadedBase: URL?
    /// The shell load in flight; an older load finishing must not mark the new shell ready.
    @ObservationIgnored private var loading: WKNavigation?
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private let scrollReporter = ScrollReporter()
    @ObservationIgnored private var scrollFraction = 0.0
    @ObservationIgnored private var pagePosition = 0.0
    @ObservationIgnored private var panFraction = 0.0
    /// Scroll and zoom to apply once the next document is on screen.
    @ObservationIgnored var pendingRestore: DocumentPosition? {
        didSet { if pendingRestore != nil { restoreIfShown() } }
    }

    /// Page and zoom only mean something with A4 pages; `flow` is the reflowing scroll.
    func position() -> DocumentPosition {
        DocumentPosition(page: pagePosition, zoom: pageScale.map(Double.init), flow: scrollFraction, pan: panFraction)
    }

    /// Applies the pending state when the document it's meant for is already shown.
    private func restoreIfShown() {
        guard isReady, !isSending, let pending, pending == sent, let state = pendingRestore else { return }
        pendingRestore = nil
        if paged {
            pageScale = state.zoom.map { CGFloat($0) }
            applyZoom(animated: false)
            pagePosition = state.page
        }
        scrollFraction = state.flow
        panFraction = state.pan
        view.callAsyncJavaScript(ScrollReporter.restoreScript,
                                 arguments: ["page": paged ? state.page : NSNull(), "fraction": state.flow, "pan": state.pan],
                                 in: nil, in: .page)
    }
    @ObservationIgnored private var pending: String?
    @ObservationIgnored private var sent: String?
    @ObservationIgnored private var isSending = false
    @ObservationIgnored nonisolated(unsafe) private var frameObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var magnifyMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var textSizeObserver: NSObjectProtocol?

    init(markdown: Bool = false) {
        isMarkdown = markdown
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(fontHandler, forURLScheme: FontSchemeHandler.scheme)
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        scrollReporter.install(in: config.userContentController)
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        scrollReporter.onScroll = { [weak self] fraction, page, pan in
            self?.scrollFraction = fraction
            self?.panFraction = pan
            if let page { self?.pagePosition = page }
        }
        // Like the PDF preview, A4 sheets float on the pane's material.
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = self
        view.postsFrameChangedNotifications = true
        applyAppearance()
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFit() }
        }
        // Pinching zooms A4 pages and resizes reflowing text, instead of scaling the page as a picture.
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.view.window,
                      self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)) else { return false }
                // ⌘-scroll zooms like pinching.
                let factor = event.type == .magnify ? 1 + event.magnification : event.commandZoomFactor
                guard let factor else { return false }
                if self.paged {
                    self.setScale(self.effectiveScale * factor, animated: false)
                } else {
                    PreviewTextSize.shared.set(PreviewTextSize.shared.size * factor, animated: false)
                }
                return true
            }
            return handled ? nil : event
        }
        textSizeObserver = NotificationCenter.default.addObserver(forName: PreviewTextSize.didChange, object: nil,
                                                                  queue: .main) { [weak self] note in
            let animated = note.userInfo?[PreviewTextSize.animatedKey] as? Bool ?? true
            MainActor.assumeIsolated { self?.applyTextSize(animated: animated) }
        }
    }

    deinit {
        if let textSizeObserver { NotificationCenter.default.removeObserver(textSizeObserver) }
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
            // A page loaded from a string can't read files; relative images and links go through the scheme instead.
            loading = view.loadHTMLString(shell, baseURL: LocalFileSchemeHandler.url(for: baseURL))
        } else {
            send()
        }
    }

    /// Empties the page when another file is previewed, so the old document never stands in for the new one.
    func clear() {
        pending = nil
        guard isReady, sent != "" else { return }
        sent = ""
        view.callAsyncJavaScript("tw.update(html)", arguments: ["html": ""], in: nil, in: .page)
    }

    func zoomIn() {
        if paged { setScale(effectiveScale * 1.25) } else { PreviewTextSize.shared.size = (textSize * 1.1).rounded() }
    }

    func zoomOut() {
        if paged { setScale(effectiveScale / 1.25) } else { PreviewTextSize.shared.size = (textSize / 1.1).rounded() }
    }

    /// Fits A4 pages to the width, or puts the text back to its standard size.
    func resetZoom() {
        if paged {
            pageScale = nil
            applyZoom(animated: true)
        } else {
            PreviewTextSize.shared.size = PreviewTextSize.standard
        }
    }

    var textSize: Double { PreviewTextSize.shared.size }

    private func setScale(_ value: CGFloat, animated: Bool = true) {
        pageScale = min(max(value, 0.1), 8)
        applyZoom(animated: animated)
    }

    private func applyZoom(animated: Bool) {
        let start = view.pageZoom
        guard animated, abs(pageZoom - start) > 0.001 else {
            zoomTimer?.invalidate()
            view.pageZoom = pageZoom
            return
        }
        // Each step reflows the page, so this runs at a lower rate than the PDF zoom.
        zoomTimer?.invalidate()
        let began = CACurrentMediaTime()
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = min((CACurrentMediaTime() - began) / 0.2, 1)
                let target = self.pageZoom
                self.view.pageZoom = start * pow(target / start, 1 - pow(1 - t, 3))
                if t >= 1 { timer.invalidate() }
            }
        }
    }

    /// A4 is 210mm = 794 CSS px; fitting spans the sheet across the full width.
    private func updateFit() {
        let width = view.bounds.width
        fitScale = width > 0 ? width / 794 / Self.pointsPerPixel : 1
        view.pageZoom = pageZoom
    }

    private func applyTextSize(animated: Bool = true) {
        guard isReady else { return }
        view.callAsyncJavaScript("tw.setTextSize(px, animated)", arguments: ["px": textSize, "animated": animated], in: nil, in: .page)
    }

    /// Forcing light appearance makes `prefers-color-scheme` light inside the page.
    private func applyAppearance() {
        view.appearance = darkMode ? nil : NSAppearance(named: .aqua)
    }

    /// Sends the newest output once the previous update is applied, so fast typing never queues stale pages.
    private func send() {
        guard isReady, !isSending, let html = pending, html != sent else { return restoreIfShown() }
        isSending = true
        sent = html
        view.callAsyncJavaScript("tw.update(html)", arguments: ["html": html], in: nil, in: .page) { [weak self] _ in
            guard let self else { return }
            self.isSending = false
            self.send()
        }
    }

    // MARK: - Fonts

    private func loadFonts() {
        let dirs = fontDirectories
        Task {
            let faces = await Task.detached { FontFace.scan(dirs) }.value
            guard dirs == fontDirectories else { return }
            fontHandler.files = faces.map(\.url)
            fontCSS = faces.enumerated().map { i, face in
                let family = face.family.replacingOccurrences(of: "\"", with: "\\\"")
                return "@font-face { font-family: \"\(family)\"; src: url(\"\(FontSchemeHandler.scheme):///\(i)\"); "
                    + "font-weight: \(face.weight); font-style: \(face.italic ? "italic" : "normal"); }"
            }.joined(separator: "\n")
            applyFonts()
        }
    }

    private func applyFonts() {
        guard isReady else { return }
        view.callAsyncJavaScript("tw.setFonts(css)", arguments: ["css": fontCSS], in: nil, in: .page)
    }

    // MARK: - Page

    private var shell: String {
        let style = isMarkdown ? MarkdownRenderer.style + MarkdownRenderer.codeCSS : Self.style
        return "<!DOCTYPE html><html class=\"\(paged ? "tw-paged" : "")\" style=\"--tw-text: \(textSize)px\">"
            + "<head><meta charset=\"utf-8\"><style>\(style)</style><script>\(Self.script)\ntw.pages = \(paged);"
            + "tw.markdown = \(isMarkdown);</script></head><body class=\"\(isMarkdown ? "markdown-body" : "")\"></body></html>"
    }

    // Typst frames (math, figures) are SVGs with black ink, so they get inverted in dark mode.
    private static let style = """
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 0 28px 88px; font: var(--tw-text, 16px)/1.55 -apple-system, sans-serif; }
        :root:not(.tw-paged) body > * { max-width: 46em; margin-left: auto; margin-right: auto; }
        img, svg { max-width: 100%; }
        :root:not(.tw-paged) { background: Canvas; }
        .tw-paged body { padding: 0 0 88px; background: transparent; }
        body > :first-child { margin-top: 0; }
        .tw-pages { display: flex; flex-direction: column; align-items: flex-start; gap: 18px; }
        .tw-page { margin: 0 auto; flex-shrink: 0; }
        .tw-page {
          box-sizing: border-box; width: 210mm; min-height: 297mm; padding: 25mm;
          background: Canvas; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.25);
          font: 11pt/1.4 "New Computer Modern", "Libertinus Serif", Georgia, serif; overflow-wrap: break-word;
        }
        .tw-page > :first-child { margin-top: 0; }
        /* solveng's live graphs draw in the page's colors already. */
        @media (prefers-color-scheme: dark) {
          svg:not(.solveng-plot-live > svg, .solveng-plot-live .sp-row > svg) { filter: invert(1) hue-rotate(180deg); }
        }
        """

    /// Keeps the rendered top-level blocks and swaps only the range that differs from the new output.
    private static let script = """
        window.tw = {
          nodes: [], sources: [], head: [], headSource: null, pages: false, markdown: false, wrap: null, mermaid: null,

          // Eases the reflowing text to its new size, keeping the same spot of the document in view.
          setTextSize(px, animated) {
            const root = document.documentElement;
            const start = parseFloat(root.style.getPropertyValue('--tw-text')) || px;
            const max = () => Math.max(root.scrollHeight - innerHeight, 0);
            const fraction = max() > 0 ? scrollY / max() : 0;
            const began = performance.now();
            cancelAnimationFrame(this.textFrame);
            const step = now => {
              const t = animated ? Math.min((now - began) / 200, 1) : 1;
              root.style.setProperty('--tw-text', (start + (px - start) * (1 - Math.pow(1 - t, 3))) + 'px');
              scrollTo(0, fraction * max());
              if (t < 1) this.textFrame = requestAnimationFrame(step);
              else if (window.twReport) twReport();
            };
            // Pinches and scrolls already come in small steps, so they apply right away.
            if (animated) this.textFrame = requestAnimationFrame(step); else step(began);
          },

          setFonts(css) {
            let style = document.getElementById('tw-fonts');
            if (!style) {
              style = document.createElement('style');
              style.id = 'tw-fonts';
              document.head.append(style);
            }
            style.textContent = css;
          },

          update(html) {
            const doc = new DOMParser().parseFromString(html, 'text/html');
            if (doc.head.innerHTML !== this.headSource) {
              this.headSource = doc.head.innerHTML;
              this.head.forEach(n => n.remove());
              this.head = this.runScripts([...doc.head.children].filter(n => !this.markdown || n.tagName !== 'SCRIPT')
                .map(n => document.head.appendChild(document.adoptNode(n))));
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
            let added = fresh.slice(p, sources.length - q).map(n => document.adoptNode(n));
            for (const n of added) parent.insertBefore(n, anchor);
            added = this.runScripts(added);
            this.nodes = [...this.nodes.slice(0, p), ...added, ...this.nodes.slice(old.length - q)];
            this.sources = sources;
            if (this.pages) this.paginate();
            if (this.markdown) this.renderDiagrams(added);
            if (window.twReport) twReport();
          },

          // Parsed scripts never run, so typst's are swapped for fresh copies once in the page; GitHub runs none.
          runScripts(nodes) {
            if (this.markdown) return nodes;
            const fresh = old => {
              const s = document.createElement('script');
              for (const a of old.attributes) s.setAttribute(a.name, a.value);
              s.textContent = old.textContent;
              old.replaceWith(s);
              return s;
            };
            return nodes.map(n => {
              if (n.tagName === 'SCRIPT') return fresh(n);
              n.querySelectorAll('script').forEach(fresh);
              return n;
            });
          },

          // Mermaid is fetched on first use; GitHub draws these diagrams too.
          renderDiagrams(added) {
            const nodes = added.flatMap(n => n.matches('pre.mermaid') ? [n] : [...n.querySelectorAll('pre.mermaid')]);
            if (!nodes.length) return;
            this.mermaid ??= import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs').then(m => {
              const dark = matchMedia('(prefers-color-scheme: dark)').matches;
              m.default.initialize({ startOnLoad: false, theme: dark ? 'dark' : 'default' });
              return m.default;
            });
            this.mermaid.then(m => m.run({ nodes })).catch(() => {});
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
        guard navigation == loading else { return }
        isReady = true
        // The fresh shell is empty, whatever an older one was sent.
        sent = nil
        updateFit()
        applyTextSize()
        applyFonts()
        send()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Start over with a fresh shell next time; a load replaced by a newer one doesn't count.
        guard navigation == loading else { return }
        loadedBase = nil
    }

    /// Links open in the browser, local files in their app; in-page anchors scroll the preview.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        let current = webView.url?.absoluteString.components(separatedBy: "#").first ?? ""
        if url.fragment != nil, url.absoluteString.hasPrefix(current + "#") { return .allow }
        NSWorkspace.shared.open(LocalFileSchemeHandler.fileURL(for: url) ?? url)
        return .cancel
    }
}

/// One face of a font file, described for `@font-face`.
private struct FontFace: Sendable {
    let url: URL
    let family: String
    let weight: Int
    let italic: Bool

    private static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]

    static func scan(_ dirs: [URL]) -> [FontFace] {
        dirs.flatMap { dir -> [FontFace] in
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { extensions.contains($0.pathExtension.lowercased()) } ?? []
            return files.flatMap { url -> [FontFace] in
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
                return descriptors.compactMap { face(url, $0) }
            }
        }
    }

    private static func face(_ url: URL, _ descriptor: CTFontDescriptor) -> FontFace? {
        guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else { return nil }
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
        let weight = (traits[kCTFontWeightTrait] as? Double) ?? 0
        let symbolic = (traits[kCTFontSymbolicTrait] as? UInt32) ?? 0
        return FontFace(url: url, family: family, weight: cssWeight(weight),
                        italic: symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0)
    }

    /// Core Text weights run from -1 to 1; CSS uses 100 to 900.
    private static func cssWeight(_ value: Double) -> Int {
        let steps: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500),
                                      (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
        return steps.min { abs($0.0 - value) < abs($1.0 - value) }!.1
    }
}

/// Serves `twlocal://file/<absolute path>` from disk, so the page's relative images and files load.
private final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "twlocal"

    static func url(for directory: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = directory.standardizedFileURL.path + "/"
        return components.url
    }

    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme else { return nil }
        return URL(fileURLWithPath: url.path(percentEncoded: false))
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.fileURL(for: url),
              let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Serves `twfont:///<index>` from the scanned font files, which the page can't read from disk itself.
private final class FontSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "twfont"
    var files: [URL] = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let index = Int(url.lastPathComponent), files.indices.contains(index),
              let data = try? Data(contentsOf: files[index]) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        // Fonts are fetched cross-origin from the file: page.
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "font/\(files[index].pathExtension.lowercased())",
            "Access-Control-Allow-Origin": "*",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
