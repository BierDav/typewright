import Foundation
import TypstBridge

enum HTMLExport {
    static func document(_ source: String, root: URL, fontDirectories: [URL], dark: Bool) throws -> String {
        var html = source
        let images = try NSRegularExpression(pattern: #"twimage:///([^\s\"'<>]+)/(\d+)"#)
        for match in images.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            let text = html as NSString
            let mime = text.substring(with: match.range(at: 1))
            guard let id = UInt64(text.substring(with: match.range(at: 2))) else { continue }
            var count = 0
            guard let bytes = tw_preview_image(id, &count) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let data = Data(bytes: bytes, count: count)
            tw_bytes_free(bytes, count)
            html = text.replacingCharacters(in: match.range, with: "data:\(mime);base64,\(data.base64EncodedString())")
        }
        var fonts: [URL: String] = [:]
        let css = try HTMLFontFace.scan(fontDirectories).map { face in
            let encoded: String
            if let existing = fonts[face.url] {
                encoded = existing
            } else {
                encoded = try Data(contentsOf: face.url).base64EncodedString()
                fonts[face.url] = encoded
            }
            let family = face.family.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "<", with: "\\3c ")
            return "@font-face { font-family: \"\(family)\"; src: url(\"data:application/octet-stream;base64,\(encoded)\"); "
                + "font-weight: \(face.weight); font-style: \(face.italic ? "italic" : "normal"); }"
        }.joined(separator: "\n")
        let base = root.appendingPathComponent("").absoluteString
        let head = "<base href=\"\(attribute(base))\"><style>\(css)</style>"
        if let end = html.range(of: "</head>", options: .caseInsensitive) {
            html.insert(contentsOf: head, at: end.lowerBound)
        } else {
            html = head + html
        }
        guard dark else { return html }
        // An embedded document inherits its color preference from the frame, independently of the OS theme.
        return """
        <!doctype html><html style="color-scheme:only dark"><head><meta charset="utf-8">
        <title>Typewright</title><style>
        html,body { margin:0; width:100%; height:100%; background:Canvas; color:CanvasText; }
        iframe { display:block; width:100%; height:100%; border:0; color-scheme:only dark; }
        @media print { iframe { height:auto; } }
        </style></head><body><iframe title="Document" srcdoc="\(attribute(html))"></iframe></body></html>
        """
    }

    private static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
