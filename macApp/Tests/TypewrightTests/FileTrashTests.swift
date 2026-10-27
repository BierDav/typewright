import XCTest
@testable import Typewright

final class FileTrashTests: XCTestCase {
    func testLocalFallbackPreservesFilesWithUndoAndNameCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.docx")
        try Data([1, 2, 3]).write(to: source)
        try Data([4, 5, 6]).write(to: trash.appendingPathComponent("report.docx"))
        let moved = try FileTrash.moveToTrash(source, directory: trash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(moved.pathExtension, "docx")
        XCTAssertEqual(try Data(contentsOf: moved), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("report.docx")), Data([4, 5, 6]))
        try FileTrash.move(moved, to: source)
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    func testTrashingALinkLeavesItsTargetIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.docx"), link = root.appendingPathComponent("link.docx")
        try Data([1, 2, 3]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let trashed = try FileTrash.moveToTrash(link, directory: root.appendingPathComponent("Trash"))
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: trashed.path), target.path)
    }
}
