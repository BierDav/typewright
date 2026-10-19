import WebKit

/// Reports a web preview's scroll position as a fraction, so it can be saved without asking the page.
@MainActor
final class ScrollReporter: NSObject, WKScriptMessageHandler {
    private static let name = "twScroll"
    var onScroll: (Double) -> Void = { _ in }

    /// Installs the reporting script; it survives reloads of the page.
    func install(in controller: WKUserContentController) {
        controller.add(WeakHandler(self), name: Self.name)
        controller.addUserScript(WKUserScript(source: """
            (() => {
              let pending = null;
              addEventListener('scroll', () => {
                if (pending) return;
                pending = setTimeout(() => {
                  pending = null;
                  const max = document.documentElement.scrollHeight - innerHeight;
                  webkit.messageHandlers.\(Self.name).postMessage(max > 0 ? scrollY / max : 0);
                }, 120);
              }, { passive: true });
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    /// JavaScript that scrolls to `fraction` of the page.
    static let restoreScript = "const max = document.documentElement.scrollHeight - innerHeight; scrollTo(0, fraction * Math.max(max, 0));"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? Double { onScroll(value) } else if let value = message.body as? Int { onScroll(Double(value)) }
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
