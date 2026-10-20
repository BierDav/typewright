import Foundation
import TypstBridge

/// GitHub flavored Markdown rendered by the bridge.
enum MarkdownRenderer {
    static func html(_ markdown: String) -> String {
        var text = markdown
        let raw = text.withUTF8 { tw_markdown_html($0.baseAddress, $0.count) }
        defer { tw_string_free(raw) }
        return String(cString: raw)
    }

    /// Colors for highlighted code, light and dark.
    static let codeCSS: String = {
        let raw = tw_markdown_code_css()
        defer { tw_string_free(raw) }
        return String(cString: raw)
    }()

    /// After GitHub's Markdown style.
    static let style = """
        :root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --soft: #f6f8fa;
          --link: #0969da; --note: #0969da; --tip: #1a7f37; --important: #8250df; --warning: #9a6700; --caution: #d1242f; }
        @media (prefers-color-scheme: dark) {
          :root { --fg: #f0f6fc; --muted: #9198a1; --border: #3d444d; --soft: #151b23; --link: #4493f8;
            --note: #4493f8; --tip: #3fb950; --important: #ab7df8; --warning: #d29922; --caution: #f85149; }
        }
        html { background: Canvas; }
        body { margin: 0; padding: 24px 32px 88px; color: var(--fg); word-wrap: break-word;
          font: var(--tw-text, 16px)/1.5 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; }
        body > * { max-width: 980px; margin-left: auto; margin-right: auto; }
        body > :first-child { margin-top: 0 !important; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        p, blockquote, ul, ol, dl, table, pre, details, .markdown-alert, .math-display { margin-top: 0; margin-bottom: 16px; }
        h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
        h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
        h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
        h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: var(--muted); }
        ul, ol { padding-left: 2em; } li + li { margin-top: .25em; } li > p { margin-top: 16px; }
        ul.contains-task-list { padding-left: 1.2em; } li.task-list-item { list-style: none; }
        li.task-list-item input { margin: 0 .3em .25em -1.4em; vertical-align: middle; }
        blockquote { margin-left: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
        hr { height: .25em; padding: 0; margin: 24px 0; background: var(--border); border: 0; }
        code, kbd, pre, samp { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 85%; }
        :not(pre) > code { padding: .2em .4em; border-radius: 6px; background: color-mix(in srgb, var(--muted) 20%, transparent); }
        pre { padding: 16px; overflow: auto; line-height: 1.45; border-radius: 6px; background: var(--soft); }
        pre code { font-size: 100%; background: transparent; padding: 0; }
        kbd { padding: 3px 5px; font-size: 11px; border: 1px solid var(--border); border-bottom-width: 2px; border-radius: 6px; background: var(--soft); }
        table { border-spacing: 0; border-collapse: collapse; display: block; width: max-content; max-width: 100%; overflow: auto; }
        th, td { padding: 6px 13px; border: 1px solid var(--border); } th { font-weight: 600; }
        tr:nth-child(2n) { background: var(--soft); }
        img { max-width: 100%; box-sizing: content-box; }
        del { color: var(--muted); }
        .footnotes { font-size: 12px; color: var(--muted); border-top: 1px solid var(--border); padding-top: 8px; }
        .math-display { overflow-x: auto; text-align: center; } math[display="block"] { font-size: 1.15em; }
        pre.mermaid { background: transparent; text-align: center; }
        details summary { cursor: pointer; }
        .markdown-alert { padding: 8px 16px; border-left: .25em solid var(--alert); }
        .markdown-alert > :last-child { margin-bottom: 0; }
        .markdown-alert-title { font-weight: 500; color: var(--alert); }
        .markdown-alert-note { --alert: var(--note); } .markdown-alert-tip { --alert: var(--tip); }
        .markdown-alert-important { --alert: var(--important); } .markdown-alert-warning { --alert: var(--warning); }
        .markdown-alert-caution { --alert: var(--caution); }
        """

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}
