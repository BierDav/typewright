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

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}
