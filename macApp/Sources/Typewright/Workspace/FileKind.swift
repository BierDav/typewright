import Foundation
import TypewrightCore

/// How a project file is opened; the extension table lives in the Kotlin core.
enum FileKind: String {
    /// `document` covers office files Quick Look can show: Word, Excel, PowerPoint, Pages, Numbers, Keynote.
    case folder, typst, text, pdf, font, document, image, binary

    init(url: URL) {
        self = FileKinds.shared.forExtension(ext: url.pathExtension).flatMap { FileKind(rawValue: $0.id) } ?? Self.sniff(url)
    }

    private var core: TypewrightCore.FileKind { TypewrightCore.FileKind.entries.first { $0.id == rawValue }! }

    var isEditable: Bool { core.isEditable }
    var isOpenable: Bool { core.isOpenable }

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
