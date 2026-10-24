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
        controller.addUserScript(WKUserScript(source: """
            (() => {
              const pages = () => document.querySelectorAll('.page');
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
                if (window.tw) tw.pin = null;
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

extension NSEvent {
    /// How much a ⌘-scroll zooms the previews, like pinching; nil for other events.
    var commandZoomFactor: CGFloat? {
        guard type == .scrollWheel, modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              scrollingDeltaY != 0 else { return nil }
        // Trackpads report points, mouse wheels lines.
        return exp(scrollingDeltaY * (hasPreciseScrollingDeltas ? 0.01 : 0.1))
    }
}
