import WebKit

/// Reports a web preview's scroll position, so it can be saved without asking the page.
@MainActor
final class ScrollReporter: NSObject, WKScriptMessageHandler {
    private static let name = "twScroll"
    /// Scroll fraction (0 top, 1 bottom) and, for paged previews, the page position like `DocumentPosition.page`.
    var onScroll: (Double, Double?) -> Void = { _, _ in }

    /// Installs the reporting script; it survives reloads of the page.
    func install(in controller: WKUserContentController) {
        controller.add(WeakHandler(self), name: Self.name)
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
                webkit.messageHandlers.\(Self.name).postMessage({ f: max > 0 ? scrollY / max : 0, p: page });
              };
              // Scrolls to a page position, or to a fraction when the page has no pages.
              window.twRestore = (page, fraction) => {
                const all = pages();
                if (page !== null && all.length) {
                  const i = Math.min(Math.floor(page), all.length - 1);
                  const r = all[i].getBoundingClientRect();
                  scrollTo(0, r.top + scrollY + (page - i) * r.height);
                } else {
                  scrollTo(0, fraction * Math.max(document.documentElement.scrollHeight - innerHeight, 0));
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

    /// JavaScript that scrolls to `page` (or null) and otherwise to `fraction`.
    static let restoreScript = "twRestore(page, fraction);"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let f = (body["f"] as? NSNumber)?.doubleValue else { return }
        let p = (body["p"] as? NSNumber)?.doubleValue ?? -1
        onScroll(f, p >= 0 ? p : nil)
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
