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
    private(set) var zoomScale: CGFloat = 1
    @ObservationIgnored private var zoomTimer: Timer?

    var darkMode = UserDefaults.standard.object(forKey: "htmlDarkMode") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(darkMode, forKey: "htmlDarkMode")
            applyAppearance()
        }
    }

    /// Whether the shown HTML styles itself for a color scheme, as letmeout does; dark mode alone doesn't restyle it.
    private(set) var handlesColorScheme = true

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
    @ObservationIgnored private var panFraction = 0.0
    /// Scroll and zoom to apply once the next document is on screen.
    @ObservationIgnored var pendingRestore: DocumentPosition? {
        didSet { if pendingRestore != nil { restoreIfShown() } }
    }

    /// HTML uses browser zoom and a scroll fraction in either mode.
    func position() -> DocumentPosition {
        DocumentPosition(zoom: isMarkdown ? nil : Double(zoomScale), flow: scrollFraction, pan: panFraction)
    }

    /// Applies the pending state when the document it's meant for is already shown.
    private func restoreIfShown() {
        guard isReady, !isSending, let pending, pending == sent, let state = pendingRestore else { return }
        pendingRestore = nil
        if !isMarkdown {
            zoomScale = CGFloat(state.zoom ?? 1)
            applyZoom(animated: false)
        }
        scrollFraction = state.flow
        panFraction = state.pan
        view.callAsyncJavaScript(ScrollReporter.restoreScript,
                                 arguments: ["page": NSNull(), "fraction": state.flow, "pan": state.pan],
                                 in: nil, in: .page)
    }
    @ObservationIgnored private var pending: String?
    @ObservationIgnored private var sent: String?
    @ObservationIgnored private var isSending = false
    @ObservationIgnored nonisolated(unsafe) private var magnifyMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var textSizeObserver: NSObjectProtocol?

    init(markdown: Bool = false) {
        isMarkdown = markdown
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(fontHandler, forURLScheme: FontSchemeHandler.scheme)
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: PreviewImages.scheme)
        scrollReporter.install(in: config.userContentController)
        view = NSScroller.overlaid { WKWebView(frame: .zero, configuration: config) }
        super.init()
        scrollReporter.onScroll = { [weak self] fraction, _, pan in
            self?.scrollFraction = fraction
            self?.panFraction = pan
        }
        // Let the surrounding material show through Markdown; HTML gets a browser's canvas.
        if markdown { view.setValue(false, forKey: "drawsBackground") }
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = self
        applyAppearance()
        // Browser zoom keeps HTML text, math and images in proportion.
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.view.window,
                      self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)) else { return false }
                // ⌘-scroll zooms like pinching.
                let factor = event.type == .magnify ? 1 + event.magnification : event.commandZoomFactor
                guard let factor else { return false }
                if !self.isMarkdown {
                    self.setScale(self.zoomScale * factor, animated: false)
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
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
    }

    func show(_ html: String?, baseURL: URL) {
        guard let html else { return }
        pending = html
        // `color-scheme` or `prefers-color-scheme`, in CSS or a meta tag.
        let handles = html.contains("color-scheme")
        if handles != handlesColorScheme { handlesColorScheme = handles }
        if loadedBase != baseURL {
            loadedBase = baseURL
            isReady = false
            sent = nil
            // A page loaded from a string can't read files; relative images and links go through the scheme instead.
            loading = NSScroller.overlaid { view.loadHTMLString(shell, baseURL: LocalFileSchemeHandler.url(for: baseURL)) }
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
        if !isMarkdown { setScale(zoomScale * 1.25) } else { PreviewTextSize.shared.size = (textSize * 1.1).rounded() }
    }

    func zoomOut() {
        if !isMarkdown { setScale(zoomScale / 1.25) } else { PreviewTextSize.shared.size = (textSize / 1.1).rounded() }
    }

    /// Resets HTML to actual size, or Markdown to its standard text size.
    func resetZoom() {
        if !isMarkdown {
            setScale(1)
        } else {
            PreviewTextSize.shared.size = PreviewTextSize.standard
        }
    }

    var textSize: Double { PreviewTextSize.shared.size }

    private func setScale(_ value: CGFloat, animated: Bool = true) {
        zoomScale = min(max(value, 0.1), 8)
        applyZoom(animated: animated)
    }

    private func applyZoom(animated: Bool) {
        let start = view.pageZoom
        guard animated, abs(zoomScale - start) > 0.001 else {
            zoomTimer?.invalidate()
            view.pageZoom = zoomScale
            return
        }
        // Each step reflows the page, so this runs at a lower rate than the PDF zoom.
        zoomTimer?.invalidate()
        let began = CACurrentMediaTime()
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = min((CACurrentMediaTime() - began) / 0.2, 1)
                let target = self.zoomScale
                self.view.pageZoom = start * pow(target / start, 1 - pow(1 - t, 3))
                if t >= 1 { timer.invalidate() }
            }
        }
    }

    private func applyTextSize(animated: Bool = true) {
        guard isReady, isMarkdown else { return }
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
            let faces = await Task.detached { HTMLFontFace.scan(dirs) }.value
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

    /// typst's HTML is shown as a browser would show it; styling it for screens is the document's job (letmeout).
    private var shell: String {
        let style = isMarkdown ? "<style>\(MarkdownRenderer.style + MarkdownRenderer.codeCSS)</style>" : ""
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">\(style)"
            + "<script>\(Self.script)\ntw.markdown = \(isMarkdown);</script>"
            + "</head><body class=\"\(isMarkdown ? "markdown-body" : "")\"></body></html>"
    }

    /// Keeps the rendered top-level blocks and swaps only the range that differs from the new output.
    private static let script = """
        window.tw = {
          root: { nodes: [], sources: [], shells: [], kids: new Map() }, head: [], headSource: null, markdown: false, mermaid: null,
          htmlAttrs: [], bodyAttrs: [], pin: null, pinning: null,

          atBottom() {
            const tolerance = 1 + 1 / devicePixelRatio;
            return Math.abs(Math.max(document.documentElement.scrollHeight - innerHeight, 0) - scrollY) <= tolerance;
          },

          // Eases the reflowing text to its new size, keeping the same spot of the document in view.
          setTextSize(px, animated) {
            const root = document.documentElement;
            const start = parseFloat(root.style.getPropertyValue('--tw-text')) || px;
            const max = () => Math.max(root.scrollHeight - innerHeight, 0);
            const fraction = max() > 0 ? scrollY / max() : 0;
            const began = performance.now();
            this.pin = null;
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
            const atBottom = this.pin?.bottom || (this.root.nodes.length > 0 && this.atBottom());
            const doc = new DOMParser().parseFromString(html, 'text/html');
            this.htmlAttrs = [...doc.documentElement.attributes].map(a => [a.name, a.value]);
            this.bodyAttrs = [...doc.body.attributes].map(a => [a.name, a.value]);
            this.applyAttributes();
            if (doc.head.innerHTML !== this.headSource) {
              this.headSource = doc.head.innerHTML;
              this.head.forEach(n => n.remove());
              this.head = this.runScripts([...doc.head.children].filter(n => !this.markdown || n.tagName !== 'SCRIPT')
                .map(n => document.head.appendChild(document.adoptNode(n))));
            }
            // Plan every swap first, so the marks are taken from the page as it was.
            const swaps = [];
            const root = this.plan(document.body, this.root, [...doc.body.childNodes], swaps);
            const marks = this.marks(new Set(swaps.flatMap(s => s.removed)));
            const added = [];
            for (const s of swaps) {
              s.removed.forEach(n => n.remove());
              const nodes = s.fresh.map(n => s.parent.insertBefore(document.adoptNode(n), s.anchor?.parentNode === s.parent ? s.anchor : null));
              const kept = this.runScripts(nodes);
              s.done(kept);
              added.push(...kept);
            }
            this.root = root;
            if (atBottom) {
              this.setPin({ bottom: true });
              this.holdPin();
            } else this.keepMark(marks, added);
            if (this.markdown) this.renderDiagrams(added);
            if (window.twReport) twReport();
          },

          // Diffs an element's children against what was last put there. An element kept or changed in place is
          // diffed inside instead, so wrappers (letmeout's pages) never replace the whole document; it then has a
          // record of its own instead of a source, so each update serializes every node only once.
          plan(parent, record, fresh, swaps) {
            const { nodes, sources: old, shells, kids } = record;
            const sources = [];
            const source = j => sources[j] ??= fresh[j].outerHTML ?? fresh[j].textContent;
            const inside = (i, j) => this.sameShell(nodes[i], fresh[j]) && this.intact(nodes[i], kids.get(nodes[i]));
            const same = (i, j) => old[i] === null ? inside(i, j) : old[i] === source(j);
            let p = 0;
            while (p < old.length && p < fresh.length && same(p, p)) p++;
            let q = 0;
            while (q < old.length - p && q < fresh.length - p && same(old.length - 1 - q, fresh.length - 1 - q)) q++;
            const next = { nodes, sources: [], shells: [], kids: new Map() };
            const keep = (i, j, inner) => {
              next.shells[j] = shells[i];
              if (!inner) return next.sources[j] = old[i];
              next.sources[j] = null;
              next.kids.set(nodes[i], this.plan(nodes[i], inner, [...fresh[j].childNodes], swaps));
            };
            for (let i = 0; i < p; i++) keep(i, i, kids.get(nodes[i]));
            for (let k = 1; k <= q; k++) keep(old.length - k, fresh.length - k, kids.get(nodes[old.length - k]));
            const removed = nodes.slice(p, old.length - q);
            const added = fresh.slice(p, fresh.length - q);
            if (removed.length === 1 && added.length === 1 && old[p] !== null && this.sameShell(removed[0], added[0])) {
              const inner = this.childRecord(removed[0], old[p]);
              if (inner) {
                keep(p, p, inner);
                return next;
              }
            }
            added.forEach((n, k) => {
              next.sources[p + k] = source(p + k);
              next.shells[p + k] = this.shell(n);
            });
            if (removed.length || added.length) {
              swaps.push({ parent, anchor: nodes[old.length - q] ?? null, removed, fresh: added,
                           done: kept => next.nodes = [...nodes.slice(0, p), ...kept, ...nodes.slice(old.length - q)] });
            }
            return next;
          },

          // Tag and attributes of an element, the text of anything else.
          shell(n) {
            if (n.nodeType !== Node.ELEMENT_NODE) return [n.nodeType, n.data];
            return [n.namespaceURI, n.localName, ...[...n.attributes].flatMap(a => [a.namespaceURI, a.name, a.value])];
          },

          sameShells(a, b) {
            return a.length === b.length && a.every((v, i) => v === b[i]);
          },

          // Scripts and styles only take effect when inserted whole.
          sameShell(live, fresh) {
            return live.nodeType === Node.ELEMENT_NODE && fresh.nodeType === Node.ELEMENT_NODE
              && !['script', 'style', 'template', 'textarea', 'title'].includes(live.localName)
              && this.sameShells(this.shell(live), this.shell(fresh));
          },

          // Whether the element still holds the children last put there; page scripts may have changed them since.
          intact(el, record) {
            const live = el.childNodes;
            return live.length === record.nodes.length
              && record.nodes.every((n, i) => live[i] === n && this.sameShells(this.shell(n), record.shells[i]));
          },

          // The record of an element that was inserted whole, from its source.
          childRecord(live, source) {
            const template = document.createElement('template');
            template.innerHTML = source;
            const parsed = [...(template.content.firstChild?.childNodes ?? [])];
            if (parsed.length !== live.childNodes.length) return null;
            const record = { nodes: [...live.childNodes], sources: parsed.map(n => n.outerHTML ?? n.textContent),
                             shells: parsed.map(n => this.shell(n)), kids: new Map() };
            return this.intact(live, record) ? record : null;
          },

          // Elements in view, those starting nearest the top first, that can hold the view in place across an update.
          marks(removed) {
            this.pin = null;
            if (scrollY <= 0) return [];
            const found = [];
            const visit = (el, gone) => {
              if (found.length > 400) return;
              const r = el.getBoundingClientRect();
              if (r.height > 0) {
                if (r.bottom <= 0 || r.top >= innerHeight) return;
                found.push({ el, gone, top: r.top, y: r.top + scrollY, height: r.height });
              }
              for (const c of el.children) visit(c, gone || removed.has(c));
            };
            for (const n of document.body.children) visit(n, removed.has(n));
            found.sort((a, b) => Math.abs(a.top) - Math.abs(b.top) || a.height - b.height);
            // Replaced elements often come back unchanged, so they're found again by their markup.
            let keyed = 0;
            return found.slice(0, 40).filter(m => !m.gone || (keyed++ < 12 && (m.html = m.el.outerHTML).length < 20000));
          },

          // Scrolls so the first mark still in the page, or back unchanged, sits where it was.
          keepMark(marks, added) {
            const roots = added.filter(n => n.nodeType === Node.ELEMENT_NODE);
            for (const m of marks) {
              let el = m.gone ? null : m.el;
              if (m.gone) {
                const tag = CSS.escape(m.el.localName);
                let best = Infinity;
                for (const root of roots) {
                  for (const c of root.matches(tag) ? [root, ...root.querySelectorAll(tag)] : root.querySelectorAll(tag)) {
                    if (c.outerHTML !== m.html) continue;
                    const d = Math.abs(c.getBoundingClientRect().top + scrollY - m.y);
                    if (d < best) { best = d; el = c; }
                  }
                }
              }
              if (!el) continue;
              scrollBy(0, el.getBoundingClientRect().top - m.top);
              // Images and diagrams load later; the mark holds until the user scrolls.
              this.setPin({ el, top: m.top });
              return;
            }
          },

          setPin(pin) {
            this.pin = { ...pin, until: performance.now() + 3000 };
            if (!this.pinning) {
              this.pinning = new ResizeObserver(() => this.holdPin());
              this.pinning.observe(document.body);
              this.pinning.observe(document.documentElement);
              for (const type of ['wheel', 'keydown', 'mousedown']) {
                addEventListener(type, () => this.pin = null, { capture: true, passive: true });
              }
            }
            this.followPin();
          },

          followPin() {
            if (!this.pin || this.pinFrame) return;
            // WebKit can update its scroll limits after resize observers and graph animations finish.
            const step = () => {
              this.pinFrame = null;
              this.holdPin();
              if (this.pin?.bottom) this.pinFrame = requestAnimationFrame(step);
            };
            this.pinFrame = requestAnimationFrame(step);
          },

          holdPin() {
            const pin = this.pin;
            if (!pin || (!pin.bottom && (performance.now() > pin.until || !pin.el.isConnected))) return this.pin = null;
            const delta = pin.bottom ? document.documentElement.scrollHeight - innerHeight - scrollY
                                     : pin.el.getBoundingClientRect().top - pin.top;
            if (Math.abs(delta) > 0.5) scrollBy(0, delta);
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
              if (n.nodeType !== Node.ELEMENT_NODE) return n;
              if (n.tagName === 'SCRIPT') return fresh(n);
              n.querySelectorAll('script').forEach(fresh);
              return n;
            });
          },

          // Mermaid is fetched on first use; GitHub draws these diagrams too.
          renderDiagrams(added) {
            const nodes = added.filter(n => n.nodeType === Node.ELEMENT_NODE).flatMap(n => n.matches('pre.mermaid') ? [n] : [...n.querySelectorAll('pre.mermaid')]);
            if (!nodes.length) return;
            this.mermaid ??= import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs').then(m => {
              const dark = matchMedia('(prefers-color-scheme: dark)').matches;
              m.default.initialize({ startOnLoad: false, theme: dark ? 'dark' : 'default' });
              return m.default;
            });
            this.mermaid.then(m => m.run({ nodes })).catch(() => {});
          },

          applyAttributes() {
            if (this.markdown) return;
            // Copy root attributes too, so exported selectors and inherited styles still work.
            for (const [element, attrs] of [[document.documentElement, this.htmlAttrs], [document.body, this.bodyAttrs]]) {
              const names = new Set(attrs.map(([name]) => name));
              for (const attr of [...element.attributes]) if (!names.has(attr.name)) element.removeAttribute(attr.name);
              for (const [name, value] of attrs) if (element.getAttribute(name) !== value) element.setAttribute(name, value);
            }
          },
        };
        // Arm following before newly visible graphs or images change the page's height.
        addEventListener('scroll', () => {
          if (tw.atBottom()) tw.setPin({ bottom: true });
        }, { passive: true });
        """

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation == loading else { return }
        isReady = true
        // The fresh shell is empty, whatever an older one was sent.
        sent = nil
        applyZoom(animated: false)
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

extension NSScroller {
    /// WebKit takes its scroll bar style from this when it starts a page's process; reporting overlay just then
    /// gives the preview WebKit's own overlay scroll bars without changing any other scroll view.
    @MainActor static func overlaid<T>(_ body: () -> T) -> T {
        guard preferredScrollerStyle != .overlay,
              let method = class_getClassMethod(NSScroller.self, #selector(getter: preferredScrollerStyle)) else { return body() }
        let overlay: @convention(block) (AnyObject) -> NSScroller.Style = { _ in .overlay }
        let original = method_setImplementation(method, imp_implementationWithBlock(overlay))
        defer { method_setImplementation(method, original) }
        return body()
    }
}

/// One face of a font file, described for `@font-face`.
struct HTMLFontFace: Sendable {
    let url: URL
    let family: String
    let weight: Int
    let italic: Bool

    private static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]

    static func scan(_ dirs: [URL]) -> [HTMLFontFace] {
        dirs.flatMap { dir -> [HTMLFontFace] in
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { extensions.contains($0.pathExtension.lowercased()) } ?? []
            return files.flatMap { url -> [HTMLFontFace] in
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
                return descriptors.compactMap { face(url, $0) }
            }
        }
    }

    private static func face(_ url: URL, _ descriptor: CTFontDescriptor) -> HTMLFontFace? {
        guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else { return nil }
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
        let weight = (traits[kCTFontWeightTrait] as? Double) ?? 0
        let symbolic = (traits[kCTFontSymbolicTrait] as? UInt32) ?? 0
        return HTMLFontFace(url: url, family: family, weight: cssWeight(weight),
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

/// Serves the images `PreviewImages` took out of the HTML.
private final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let image = PreviewImages.image(at: url) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        // An id always stands for the same bytes.
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": image.mime,
            "Cache-Control": "max-age=31536000, immutable",
            "Access-Control-Allow-Origin": "*",
        ])!
        task.didReceive(response)
        task.didReceive(image.data)
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
