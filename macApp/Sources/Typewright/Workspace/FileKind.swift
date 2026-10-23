import Darwin
import Foundation
import TypewrightCore

/// How a project file is opened; the extension table lives in the Rust core.
enum FileKind: String, Codable, Sendable {
    /// `document` covers office files Quick Look can show: Word, Excel, PowerPoint, Pages, Numbers, Keynote.
    case folder, typst, text, pdf, font, document, image, binary

    init(url: URL) {
        var info = stat()
        if stat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            self = .binary
            return
        }
        self = fileKindForExtension(ext: url.pathExtension).flatMap { FileKind(rawValue: $0.id()) } ?? Self.sniff(url)
    }

    private var core: TypewrightCore.FileKind { fileKindForId(id: rawValue)! }

    var isEditable: Bool { core.isEditable() }
    var isOpenable: Bool { core.isOpenable() }

    /// Unknown extensions count as text if the first bytes are NUL-free UTF-8.
    private static func sniff(_ url: URL) -> FileKind {
        // Nonblocking open also covers a file replaced by a pipe between stat and open.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return .binary }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .binary }
        guard let data = try? handle.read(upToCount: 4096) else { return .text }
        if data.contains(0) { return .binary }
        // The sample may end inside a multi-byte character.
        for trim in 0...min(3, data.count) where String(data: data.dropLast(trim), encoding: .utf8) != nil {
            return .text
        }
        return .binary
    }
}
