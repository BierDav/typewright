import XCTest
@testable import Typewright

@MainActor
final class SearchPreviewTests: XCTestCase {
    func testStandaloneDocumentSavesOnFlush() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let doc = SearchPreviewDocument(url: file, space: dir, workspace: nil, client: nil)
        XCTAssertEqual(doc.text, "hello")
        doc.textDidChange("hello world", live: false)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello", "saving waits for a pause")
        doc.flush()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello world")
        XCTAssertNotEqual(doc.documentID, SearchPreviewDocument(url: file, space: dir, workspace: nil, client: nil).documentID)
    }
}
