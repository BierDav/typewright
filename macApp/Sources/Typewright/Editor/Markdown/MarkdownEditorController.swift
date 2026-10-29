import AppKit
import SwiftUI
import TypstBridge
import TypewrightCore
import WebKit

/// The Markdown editor: Notion-like blocks (`MarkdownEditor.js`) editing the shown file in a web view. solveng
/// cells are calculated by the built-in typst in order, like a notebook, and show their typeset results.
@MainActor
final class MarkdownEditorController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let view: MarkdownWebView
    private weak var workspace: Workspace?
    private var file: URL?
    private var folder: URL?
    private var loading: WKNavigation?
    private var isReady = false
    /// The text the page shows, as far as this side knows.
    private var shown: String?
    private var pending: String?
    private var notebookTask: Task<Void, Never>?
    private var notebookCompiler: BuiltinCompiler?
    nonisolated(unsafe) private var magnifyMonitor: Any?
    nonisolated(unsafe) private var textSizeObserver: NSObjectProtocol?

    init(workspace: Workspace) {
        self.workspace = workspace
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        let proxy = WeakMessageHandler()
        config.userContentController.add(proxy, name: "tw")
        view = NSScroller.overlaid { MarkdownWebView(frame: .zero, configuration: config) }
        super.init()
        proxy.target = self
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = self
        view.onUndo = { [weak self] redo in self?.undo(redo: redo) }
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.view.window,
                      self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)),
                      let factor = event.type == .magnify ? 1 + event.magnification : event.commandZoomFactor else { return false }
                PreviewTextSize.shared.set(PreviewTextSize.shared.size * factor, animated: false)
                return true
            }
            return handled ? nil : event
        }
        textSizeObserver = NotificationCenter.default.addObserver(forName: PreviewTextSize.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTextSize() }
        }
    }

    deinit {
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        if let textSizeObserver { NotificationCenter.default.removeObserver(textSizeObserver) }
    }

    /// Shows `text` of `file`; the page keeps what didn't change, so typing elsewhere never moves its caret.
    func show(_ file: URL, text: String) {
        if file != self.file {
            self.file = file
            shown = nil
            notebookTask?.cancel()
            let folder = file.deletingLastPathComponent()
            // Relative images and links resolve against the file's folder.
            if folder != self.folder || loading != nil {
                self.folder = folder
                isReady = false
                loading = NSScroller.overlaid { view.loadHTMLString(Self.shell, baseURL: LocalFileSchemeHandler.url(for: folder)) }
            } else {
                view.callAsyncJavaScript("ed.reset()", arguments: [:], in: nil, in: .page)
            }
        }
        guard text != shown else { return }
        pending = text
        if isReady { flush() }
    }

    /// Puts the caret in the page, for a newly selected file.
    func focus() {
        view.window?.makeFirstResponder(view)
        view.callAsyncJavaScript("ed.focus()", arguments: [:], in: nil, in: .page)
    }

    private func flush() {
        guard let text = pending else { return }
        pending = nil
        push(text)
    }

    private func push(_ text: String) {
        shown = text
        view.callAsyncJavaScript("ed.load(text, JSON.parse(blocks))", arguments: ["text": text, "blocks": Self.blocks(text)],
                                 in: nil, in: .page)
    }

    private func applyTextSize() {
        guard isReady else { return }
        view.callAsyncJavaScript("ed.setTextSize(px)", arguments: ["px": PreviewTextSize.shared.size], in: nil, in: .page)
    }

    // MARK: - Messages

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "change": didChange(body)
        case "render": render(id: body["id"] ?? 0, markdown: body["markdown"] as? String ?? "")
        case "notebook": calculate(cells: body["cells"] as? [String] ?? [], key: body["key"] as? String ?? "")
        case "undo": undo(redo: false)
        case "redo": undo(redo: true)
        case "open": open(body["href"] as? String ?? "")
        case "pasteImage": pasteImage()
        default: break
        }
    }

    private func didChange(_ body: [String: Any]) {
        guard let workspace, let file, workspace.selectedFile == file, let text = body["text"] as? String else { return }
        let base = body["base"] as? String ?? text
        var new = text
        var reply = body["reparse"] as? Bool == true
        if base != workspace.text, text != workspace.text {
            // Edits from the source editor or another device crossed this one.
            let merged = merge3(base: base, local: text, remote: workspace.text)
            new = merged.conflicts == 0 ? merged.text : text
            reply = true
        }
        shown = new
        workspace.markdownEditorDidChange(new)
        if reply { push(new) }
    }

    private func render(id: Any, markdown: String) {
        view.callAsyncJavaScript("ed.rendered(id, html)", arguments: ["id": id, "html": Self.blockHTML(markdown)], in: nil, in: .page)
    }

    /// The live session's undo when the file is shared, else the page's own; the window's file operations last.
    private func undo(redo: Bool) {
        guard let workspace else { return }
        if workspace.live.undo(redo: redo) { return }
        view.callAsyncJavaScript("return ed.undo(redo)", arguments: ["redo": redo], in: nil, in: .page) { [weak self] result in
            guard case .success(let done) = result, done as? Bool != true else { return }
            guard let state = (self?.view.window?.windowController as? MainWindowController)?.state else { return }
            if redo {
                state.undoManager.redo()
            } else if !state.undoDeletion() {
                state.undoManager.undo()
            }
        }
    }

    /// Web links open in the browser; files in the space open here, others in their app.
    private func open(_ href: String) {
        guard let workspace, let file, !href.isEmpty, !href.hasPrefix("#") else { return }
        if let url = URL(string: href), let scheme = url.scheme, scheme != "file", scheme != LocalFileSchemeHandler.scheme {
            NSWorkspace.shared.open(url)
            return
        }
        let path = (href.components(separatedBy: "#").first ?? href).removingPercentEncoding ?? href
        let target = URL(fileURLWithPath: path, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
        if workspace.isInSpace(target), FileManager.default.fileExists(atPath: target.path), FileKind(url: target).isOpenable {
            workspace.select(target)
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    private func pasteImage() {
        guard let markdown = workspace?.pasteImage(from: .general) else { return }
        view.callAsyncJavaScript("ed.insertMarkdown(text)", arguments: ["text": markdown], in: nil, in: .page)
    }

    // MARK: - solveng

    /// Runs the cells as one typst document next to the file, so `#import "defs.typ"` finds its files.
    private func calculate(cells: [String], key: String) {
        guard let workspace, let file, let path = workspace.relative(file) else { return }
        notebookTask?.cancel()
        let compiler = notebookCompiler ?? BuiltinCompiler(root: workspace.root)
        if notebookCompiler == nil {
            compiler.setFontPaths(workspace.fontDirectories) {}
            notebookCompiler = compiler
        }
        let main = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".\((path as NSString).lastPathComponent).solveng.typ")
        let source = Self.notebook(cells: cells, package: Self.solvengPackage)
        var buffers: [String: String] = [main: source]
        for (url, text) in workspace.unsavedBuffers where url != file {
            if let path = workspace.relative(url) { buffers[path] = text }
        }
        notebookTask = Task { [weak self] in
            let (pages, diagnostics) = await compiler.svg(main: main, buffers: buffers)
            guard !Task.isCancelled, let self else { return }
            let lines = source.components(separatedBy: "\n")
            let cellOfLine = { (line: Int) in lines.prefix(max(line - 1, 0)).filter { $0 == "#pagebreak()" }.count }
            var errors: [[String: Any]] = []
            for d in diagnostics {
                if d.path == main {
                    errors.append(["cell": cellOfLine(d.line), "message": d.message])
                } else if pages == nil, d.severity == .error {
                    // Not in a cell, like a missing package: every cell failed.
                    errors += cells.indices.map { ["cell": $0, "message": d.message] }
                }
            }
            // Glyphs take the page's text color, so results follow dark mode.
            let svgs: [Any] = (pages ?? []).prefix(cells.count).map {
                $0.replacingOccurrences(of: "fill=\"#000000\"", with: "fill=\"currentColor\"")
                    .replacingOccurrences(of: "stroke=\"#000000\"", with: "stroke=\"currentColor\"")
            }
            view.callAsyncJavaScript("ed.notebook(key, pages, errors)",
                                     arguments: ["key": key, "pages": pages == nil ? [] : svgs, "errors": errors],
                                     in: nil, in: .page)
        }
    }

    /// The installed solveng when there is one (`@solveng/solveng`), else the published package.
    private static var solvengPackage: String {
        let version = SolvengSupport.version
        let local = URL.applicationSupportDirectory.appending(path: "typst/packages/solveng/solveng/\(version)")
        return FileManager.default.fileExists(atPath: local.path) ? "@solveng/solveng:\(version)" : "@preview/solveng:\(version)"
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation == loading else { return }
        loading = nil
        isReady = true
        applyTextSize()
        if pending == nil, let shown { pending = shown }
        flush()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation == loading else { return }
        loading = nil
        folder = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated else { return .allow }
        if let href = action.request.url?.absoluteString { open(href) }
        return .cancel
    }

    // MARK: - Page

    private static let shell: String = {
        func resource(_ name: String, _ ext: String) -> String {
            Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>\(MarkdownRenderer.codeCSS)\n"
            + "\(resource("MarkdownEditor", "css"))</style></head><body><div id=\"doc\"></div>"
            + "<script>\(resource("MarkdownEditor", "js"))</script></body></html>"
    }()

    private static func blocks(_ text: String) -> String {
        call(text) { tw_markdown_blocks($0, $1) }
    }

    private static func blockHTML(_ markdown: String) -> String {
        call(markdown) { tw_markdown_block_html($0, $1) }
    }

    private static func notebook(cells: [String], package: String) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: cells)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return call(json) { tw_markdown_notebook($0, $1, package) }
    }

    private static func call(_ text: String, _ body: (UnsafePointer<UInt8>?, Int) -> UnsafeMutablePointer<CChar>) -> String {
        var text = text
        let raw = text.withUTF8 { body($0.baseAddress, $0.count) }
        defer { tw_string_free(raw) }
        return String(cString: raw)
    }
}

/// The page's message handler without the page keeping the controller alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Sends the Edit menu's Undo and Redo to the editor instead of WebKit's own history.
final class MarkdownWebView: WKWebView {
    var onUndo: ((Bool) -> Void)?

    @objc func undo(_ sender: Any?) { onUndo?(false) }
    @objc func redo(_ sender: Any?) { onUndo?(true) }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}

struct MarkdownEditorView: NSViewRepresentable {
    let controller: MarkdownEditorController
    let file: URL
    let text: String

    func makeNSView(context: Context) -> MarkdownWebView {
        controller.show(file, text: text)
        return controller.view
    }

    func updateNSView(_ view: MarkdownWebView, context: Context) {
        controller.show(file, text: text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }
}
