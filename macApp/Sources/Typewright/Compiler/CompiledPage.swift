import Foundation
@preconcurrency import PDFKit

/// Retains the source PDF so cached pages keep their fonts and images alive.
final class CompiledPage: @unchecked Sendable, Equatable {
    let document: PDFDocument
    let page: PDFPage
    let byteCount: Int

    init?(data: Data) {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        self.document = document
        self.page = page
        byteCount = data.count
    }

    static func == (lhs: CompiledPage, rhs: CompiledPage) -> Bool { lhs === rhs }
}
