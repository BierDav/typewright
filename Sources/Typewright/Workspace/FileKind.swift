import Foundation

/// How a project file is opened.
enum FileKind {
    /// `document` covers office files Quick Look can show: Word, Excel, PowerPoint, Pages, Numbers, Keynote.
    case folder, typst, text, pdf, font, document, image, binary

    private static let textExtensions: Set<String> = [
        "bib", "yml", "yaml", "toml", "txt", "csv", "tsv", "json", "xml", "md", "svg", "html", "css", "js",
        "tex", "sty", "cls", "csl", "lua", "py", "sh", "swift", "rs", "c", "h", "ini", "cfg", "log", "gitignore",
    ]
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]
    private static let documentExtensions: Set<String> = [
        "doc", "docx", "docm", "dot", "dotx", "xls", "xlsx", "xlsm", "xlt", "xltx", "ppt", "pptx", "pptm", "pot", "potx",
        "pps", "ppsx", "pages", "numbers", "key", "odt", "ods", "odp", "rtf",
    ]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "ico"]
    private static let binaryExtensions: Set<String> = [
        "zip", "gz", "tar", "dmg",
        "mp3", "mp4", "mov", "wav",
    ]

    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "typ" { self = .typst }
        else if ext == "pdf" { self = .pdf }
        else if Self.fontExtensions.contains(ext) { self = .font }
        else if Self.documentExtensions.contains(ext) { self = .document }
        else if Self.textExtensions.contains(ext) { self = .text }
        else if Self.imageExtensions.contains(ext) { self = .image }
        else if Self.binaryExtensions.contains(ext) { self = .binary }
        else { self = Self.sniff(url) }
    }

    var isEditable: Bool { self == .typst || self == .text }
    var isOpenable: Bool { self != .folder && self != .binary }

    /// Unknown extensions count as text if the first bytes are NUL-free UTF-8.
    private static func sniff(_ url: URL) -> FileKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .binary }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return .text }
        if data.contains(0) { return .binary }
        // The sample may end inside a multi-byte character.
        for trim in 0...min(3, data.count) where String(data: data.dropLast(trim), encoding: .utf8) != nil {
            return .text
        }
        return .binary
    }
}
