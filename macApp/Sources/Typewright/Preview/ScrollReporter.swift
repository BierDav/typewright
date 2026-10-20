import WebKit

/// Reports a web preview's scroll position, so it can be saved without asking the page.
@MainActor
final class ScrollReporter: NSObject, WKScriptMessageHandler {
    private static let name = "twScroll"
    /// Scroll fraction (0 top, 1 bottom), for paged previews the page position like `DocumentPosition.page`,
    /// and the horizontal scroll fraction.
    var onScroll: (Double, Double?, Double) -> Void = { _, _, _ in }

    /// Installs the reporting script; it survives reloads of the page.
    func install(in controller: WKUserContentController) {
        controller.add(WeakHandler(self), name: Self.name)
        controller.addUserScript(WKUserScript(source: Self.overlayScrollbars, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: """
            (() => {
              const pages = () => document.querySelectorAll('.page, .tw-page');
              window.twReport = () => {
                const max = document.documentElement.scrollHeight - innerHeight;
                let page = -1;
                const all = pages();
                for (let i = 0; i < all.length; i++) {
                  const r = all[i].getBoundingClientRect();
                  if (i > 0 && r.top > 0.5) break;
                  page = i + Math.min(Math.max(-r.top / Math.max(r.height, 1), 0), 1);
                }
                const maxX = document.documentElement.scrollWidth - innerWidth;
                webkit.messageHandlers.\(Self.name).postMessage({ f: max > 0 ? scrollY / max : 0, p: page,
                                                                  x: maxX > 0 ? scrollX / maxX : 0 });
              };
              // Scrolls to a page position, or to a fraction when the page has no pages.
              window.twRestore = (page, fraction, pan) => {
                const all = pages();
                const x = pan * Math.max(document.documentElement.scrollWidth - innerWidth, 0);
                if (page !== null && all.length) {
                  const i = Math.min(Math.floor(page), all.length - 1);
                  const r = all[i].getBoundingClientRect();
                  scrollTo(x, r.top + scrollY + (page - i) * r.height);
                } else {
                  scrollTo(x, fraction * Math.max(document.documentElement.scrollHeight - innerHeight, 0));
                }
                twReport();
              };
              let pending = null;
              addEventListener('scroll', () => {
                if (pending) return;
                pending = setTimeout(() => { pending = null; twReport(); }, 120);
              }, { passive: true });
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    /// JavaScript that scrolls to `page` (or null) and otherwise to `fraction`, and sideways to `pan`.
    static let restoreScript = "twRestore(page, fraction, pan);"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let f = (body["f"] as? NSNumber)?.doubleValue else { return }
        let p = (body["p"] as? NSNumber)?.doubleValue ?? -1
        onScroll(f, p >= 0 ? p : nil, (body["x"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// The content controller keeps its handlers alive; this keeps it from keeping the preview alive.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: ScrollReporter?
        init(_ target: ScrollReporter) { self.target = target }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }
}

extension ScrollReporter {
    /// WebKit's own scroll bars take a strip of the page when they always show; these float over it, edge to edge,
    /// appear while scrolling and can be dragged, like AppKit's overlay scrollers.
    static let overlayScrollbars = """
        (() => {
          const style = document.createElement('style');
          style.textContent = `
            html { scrollbar-width: none; }
            html::-webkit-scrollbar { display: none; width: 0; height: 0; }
            .tw-bar { position: fixed; z-index: 2147483647; margin: 0 !important; max-width: none !important; border-radius: 6px; background: rgba(0, 0, 0, 0.42);
              opacity: 0; transition: opacity 0.35s, width 0.15s, height 0.15s; }
            .tw-bar.tw-y { right: 2px; width: 7px; }
            .tw-bar.tw-x { bottom: 2px; height: 7px; }
            .tw-bar.tw-on, .tw-bar:hover, .tw-bar.tw-drag { opacity: 1; transition: opacity 0.1s, width 0.15s, height 0.15s; }
            .tw-bar.tw-y:hover, .tw-bar.tw-y.tw-drag { width: 11px; }
            .tw-bar.tw-x:hover, .tw-bar.tw-x.tw-drag { height: 11px; }
            @media (prefers-color-scheme: dark) { .tw-bar { background: rgba(255, 255, 255, 0.42); } }`;
          document.head.append(style);
          const root = document.documentElement;
          let hide = null;
          const bars = ['y', 'x'].map(axis => {
            const bar = document.createElement('div');
            bar.className = 'tw-bar tw-' + axis;
            document.body.append(bar);
            bar.addEventListener('mousedown', down => {
              down.preventDefault();
              const vertical = axis === 'y';
              const start = vertical ? down.clientY : down.clientX, from = vertical ? scrollY : scrollX;
              const view = vertical ? innerHeight : innerWidth, total = vertical ? root.scrollHeight : root.scrollWidth;
              const ratio = (total - view) / Math.max(view - (vertical ? bar.offsetHeight : bar.offsetWidth), 1);
              bar.classList.add('tw-drag');
              const move = e => {
                const to = from + ((vertical ? e.clientY : e.clientX) - start) * ratio;
                vertical ? scrollTo(scrollX, to) : scrollTo(to, scrollY);
              };
              const up = () => {
                bar.classList.remove('tw-drag');
                removeEventListener('mousemove', move);
                removeEventListener('mouseup', up);
              };
              addEventListener('mousemove', move);
              addEventListener('mouseup', up);
            });
            return bar;
          });
          const update = show => {
            const [y, x] = bars;
            const place = (bar, view, total, offset, vertical) => {
              if (total <= view + 1) return bar.style.display = 'none';
              bar.style.display = '';
              // Each bar leaves the corner to the other one.
              const track = view - 14;
              const size = Math.max(track * view / total, 28);
              const at = 2 + (offset / (total - view)) * (track - size);
              if (vertical) { bar.style.height = size + 'px'; bar.style.top = at + 'px'; }
              else { bar.style.width = size + 'px'; bar.style.left = at + 'px'; }
            };
            place(y, innerHeight, root.scrollHeight, scrollY, true);
            place(x, innerWidth, root.scrollWidth, scrollX, false);
            if (!show) return;
            bars.forEach(b => b.classList.add('tw-on'));
            clearTimeout(hide);
            hide = setTimeout(() => bars.forEach(b => b.classList.remove('tw-on')), 900);
          };
          addEventListener('scroll', () => update(true), { passive: true });
          addEventListener('resize', () => update(false));
          // New output changes the page's length without scrolling.
          new ResizeObserver(() => update(false)).observe(document.body);
          update(false);
        })();
        """
}

extension NSEvent {
    /// How much a ⌘-scroll zooms the previews, like pinching; nil for other events.
    var commandZoomFactor: CGFloat? {
        guard type == .scrollWheel, modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              scrollingDeltaY != 0 else { return nil }
        // Trackpads report points, mouse wheels lines.
        return exp(scrollingDeltaY * (hasPreciseScrollingDeltas ? 0.01 : 0.1))
    }
}
