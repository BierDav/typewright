import XCTest
@testable import Typewright

final class DocumentPreviewTests: XCTestCase {
    func testCopyKeepsExtensionAndSurvivesSourceChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Übung.docx")
        let before = Data([0x50, 0x4b, 0, 1])
        try before.write(to: source)
        var copy: DocumentPreviewCopy? = try await Task.detached { try DocumentPreviewCopy.prepare(source) }.value
        let target = try XCTUnwrap(copy?.url)
        XCTAssertEqual(target.lastPathComponent, source.lastPathComponent)
        XCTAssertNotEqual(target, source)
        try Data([0x50, 0x4b, 2, 3]).write(to: source)
        XCTAssertEqual(try Data(contentsOf: target), before)
        let changed = try await Task.detached { try DocumentPreviewCopy.prepare(source) }.value
        XCTAssertNotEqual(copy?.digest, changed.digest)
        copy = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testMissingDocumentReportsAnError() async {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).docx")
        do {
            _ = try await Task.detached { try DocumentPreviewCopy.prepare(source) }.value
            XCTFail("Missing provider files must not become empty previews")
        } catch {}
    }

    func testPackageDocumentsKeepTheirContentsAndStableFingerprint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("Slides.key")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("Data/content"))
        let first = try await Task.detached { try DocumentPreviewCopy.prepare(source) }.value
        let second = try await Task.detached { try DocumentPreviewCopy.prepare(source) }.value
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertEqual(try Data(contentsOf: first.url.appendingPathComponent("Data/content")), Data([1, 2, 3]))
    }
}
