import Foundation
import QuickLookUI
import TypstBridge
import UniformTypeIdentifiers

/// Finder's previews of Typst files, compiled to PDF in process, and Markdown, rendered like the app's preview.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL.standardizedFileURL
        if MarkdownRenderer.isMarkdown(url) { return try markdown(url) }
        return typst(url)
    }

    // MARK: - Typst

    private func typst(_ url: URL) -> QLPreviewReply {
        // Typst's package cache lives in the real home, not the sandbox container.
        setenv("HOME", FontSearch.home.path, 1)
        let root = Self.root(of: url)
        let main = String(url.path.dropFirst(root.path.count).drop { $0 == "/" })
        let fonts = FontSearch.directories(FontSearch.loadSettings(), from: url.deletingLastPathComponent())

        let world = tw_world_new(root.path)
        defer { tw_world_free(world) }
        let paths = fonts.map { strdup($0.path)! }
        defer { paths.forEach { free($0) } }
        _ = paths.map { UnsafePointer($0) }.withUnsafeBufferPointer { tw_world_set_font_paths(world, $0.baseAddress, $0.count) }
        tw_world_set_main(world, main)
        let result = tw_world_compile(world, TWFormatPDF)
        defer { tw_result_free(result) }

        if let bytes = result.data {
            let data = Data(bytes: bytes, count: result.len)
            return QLPreviewReply(dataOfContentType: .pdf, contentSize: CGSize(width: 595, height: 842)) { _ in data }
        }
        let errors = (try? JSONDecoder().decode([Entry].self, from: Data(String(cString: result.diagnostics).utf8))) ?? []
        return Self.failure(errors.filter { $0.severity == "error" })
    }

    /// The topmost folder above the file that is a typst project or repository, so imports from parent folders resolve.
    private static func root(of file: URL) -> URL {
        let folder = file.deletingLastPathComponent()
        var root = folder
        var dir = folder
        while dir.path != "/", dir.path != FontSearch.home.path {
            let fm = FileManager.default
            if fm.fileExists(atPath: dir.appending(path: "typst.toml").path) || fm.fileExists(atPath: dir.appending(path: ".git").path) {
                root = dir
            }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
        return root
    }

    private struct Entry: Decodable {
        let path: String
        let line: Int
        let column: Int
        let severity: String
        let message: String
    }

    private static func failure(_ errors: [Entry]) -> QLPreviewReply {
        let items = errors.isEmpty ? "<li>The document couldn’t be compiled.</li>" : errors.prefix(20).map { e in
            let place = e.path.isEmpty ? "" : "<code>\(escape(e.path)):\(e.line):\(e.column)</code> "
            return "<li>\(place)\(escape(e.message))</li>"
        }.joined()
        let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><style>
            :root { color-scheme: light dark; }
            body { font: 13px -apple-system, sans-serif; padding: 24px 32px; }
            h1 { font-size: 17px; } li { margin: 6px 0; } code { color: #d1242f; }
            </style></head><body><h1>Compilation failed</h1><ul>\(items)</ul></body></html>
            """
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in Data(html.utf8) }
    }

    // MARK: - Markdown

    private func markdown(_ url: URL) throws -> QLPreviewReply {
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = Self.inlineImages(MarkdownRenderer.html(source), relativeTo: url.deletingLastPathComponent())
        let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>\(MarkdownRenderer.style)\(MarkdownRenderer.codeCSS)"
            + "body { padding-bottom: 32px; }</style></head><body class=\"markdown-body\">\(body)</body></html>"
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 1000)) { _ in Data(html.utf8) }
    }

    /// Quick Look's web view can't read files, so local images travel inside the page.
    private static func inlineImages(_ html: String, relativeTo folder: URL) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<img([^>]*?) src="([^"]+)""#) else { return html }
        var result = html
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let range = Range(match.range(at: 2), in: html) else { continue }
            let src = String(html[range])
            guard !src.contains(":"), let path = src.removingPercentEncoding else { continue }
            let file = folder.appending(path: path).standardizedFileURL
            guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 10_000_000,
                  let data = try? Data(contentsOf: file), let mime = type.preferredMIMEType,
                  let target = Range(match.range(at: 2), in: result) else { continue }
            result.replaceSubrange(target, with: "data:\(mime);base64,\(data.base64EncodedString())")
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
