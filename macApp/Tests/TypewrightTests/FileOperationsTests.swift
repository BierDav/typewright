import AppKit
import XCTest
@testable import Typewright

/// File tree changes in a library space: each one commits, undo and redo put the disk back and forth.
@MainActor
final class FileOperationsTests: XCTestCase {
    private var space: URL!
    private var ws: Workspace!
    private var undo: UndoManager!
    private let fm = FileManager.default
    private var repository: SpaceRepository { .shared }

    override func setUp() async throws {
        space = repository.root.appendingPathComponent("Ops \(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: space.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        try "= Main\n#include \"chapters/one.typ\"\n".write(to: space.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        try "One\n".write(to: space.appendingPathComponent("chapters/one.typ"), atomically: true, encoding: .utf8)
        await repository.commit("Add test space")
        ws = Workspace(url: space)
        undo = UndoManager()
        undo.groupsByEvent = false
        ws.fileOps.undoManager = undo
    }

    override func tearDown() async throws {
        await ws.fileOps.settle()
        ws.close()
        try? fm.removeItem(at: space)
        await repository.commit("Remove test space")
    }

    private func url(_ path: String) -> URL { space.appendingPathComponent(path) }
    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }
    private func text(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }

    /// One undo step around `body`, then waits for the queued disk work.
    private func step(_ body: () -> Void) async {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
        await ws.fileOps.settle()
    }

    private func undoStep() async {
        undo.undo()
        await ws.fileOps.settle()
    }

    private func redoStep() async {
        undo.redo()
        await ws.fileOps.settle()
    }

    func testRenameUndoesAndRedoes() async {
        await step { ws.rename(url("chapters/one.typ"), to: "first.typ") }
        XCTAssertTrue(exists("chapters/first.typ"))
        XCTAssertEqual(undo.undoActionName, "Rename “one.typ”")
        // Paths in other files followed the rename.
        XCTAssertEqual(ws.bufferText(url("main.typ")), "= Main\n#include \"chapters/first.typ\"\n")
        await undoStep()
        XCTAssertTrue(exists("chapters/one.typ"))
        XCTAssertFalse(exists("chapters/first.typ"))
        XCTAssertEqual(ws.bufferText(url("main.typ")), "= Main\n#include \"chapters/one.typ\"\n")
        XCTAssertEqual(undo.redoActionName, "Rename “one.typ”")
        await redoStep()
        XCTAssertTrue(exists("chapters/first.typ"))
    }

    func testUndoingARenameKeepsEditsMadeSince() async throws {
        await step { ws.rename(url("chapters/one.typ"), to: "first.typ") }
        try "One, edited\n".write(to: url("chapters/first.typ"), atomically: true, encoding: .utf8)
        await undoStep()
        XCTAssertEqual(text("chapters/one.typ"), "One, edited\n")
    }

    func testUndoFailsGracefullyWhenTheOldPlaceIsTaken() async throws {
        await step { ws.rename(url("chapters/one.typ"), to: "first.typ") }
        try "Someone else\n".write(to: url("chapters/one.typ"), atomically: true, encoding: .utf8)
        await undoStep()
        XCTAssertEqual(text("chapters/one.typ"), "Someone else\n")
        XCTAssertEqual(text("chapters/first.typ"), "One\n")
    }

    func testMoveIntoAFolderUndoes() async throws {
        try fm.createDirectory(at: url("parts"), withIntermediateDirectories: true)
        ws.reloadTree()
        await step { ws.move(url("chapters/one.typ"), into: url("parts")) }
        XCTAssertTrue(exists("parts/one.typ"))
        XCTAssertEqual(undo.undoActionName, "Move “one.typ”")
        await undoStep()
        XCTAssertTrue(exists("chapters/one.typ"))
        XCTAssertFalse(exists("parts/one.typ"))
    }

    func testDeleteCommitsAndUndoRestores() async throws {
        try "One, unsaved edit\n".write(to: url("chapters/one.typ"), atomically: true, encoding: .utf8)
        await step { ws.delete(url("chapters/one.typ")) }
        XCTAssertFalse(exists("chapters/one.typ"))
        XCTAssertEqual(ws.notice?.text, "Deleted “one.typ”")
        let deleted = await repository.deleted(in: space)
        XCTAssertEqual(deleted.map(\.name), ["one.typ"])
        XCTAssertEqual(deleted.first?.description, "Delete \(space.lastPathComponent)/chapters/one.typ")
        await undoStep()
        XCTAssertEqual(text("chapters/one.typ"), "One, unsaved edit\n")
        let after = await repository.deleted(in: space)
        XCTAssertTrue(after.isEmpty)
        await redoStep()
        XCTAssertFalse(exists("chapters/one.typ"))
    }

    func testDeletingAFolderWithAnImageUndoes() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3])
        try png.write(to: url("chapters/plot.png"))
        await step { ws.delete(url("chapters")) }
        XCTAssertFalse(exists("chapters"))
        let deleted = await repository.deleted(in: space)
        XCTAssertEqual(deleted.map(\.name), ["chapters"])
        XCTAssertEqual(deleted.first?.kind, .folder)
        await undoStep()
        XCTAssertEqual(text("chapters/one.typ"), "One\n")
        XCTAssertEqual(try Data(contentsOf: url("chapters/plot.png")), png, "untracked images come back from the stash")
    }

    func testNewFileAndFolderUndo() async throws {
        var file: URL!
        await step { file = ws.createFile(in: space, named: "notes") }
        XCTAssertEqual(file.lastPathComponent, "notes.typ")
        try "Notes\n".write(to: file, atomically: true, encoding: .utf8)
        await undoStep()
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        await redoStep()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Notes\n", "redo brings back what it had")

        var folder: URL!
        await step { folder = ws.createFolder(in: space, named: "Empty") }
        await undoStep()
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
        await redoStep()
        XCTAssertTrue(fm.fileExists(atPath: folder.path), "empty folders come back too")
    }

    func testDuplicateUndoes() async {
        var copy: URL?
        await step { copy = ws.duplicate(url("chapters/one.typ")) }
        XCTAssertEqual(copy?.lastPathComponent, "one copy.typ")
        XCTAssertEqual(text("chapters/one copy.typ"), "One\n")
        await undoStep()
        XCTAssertFalse(exists("chapters/one copy.typ"))
        XCTAssertTrue(exists("chapters/one.typ"))
    }

    func testImportUndoTakesCopiesAwayAndPutsMovedItemsBack() async throws {
        let outside = fm.temporaryDirectory.appendingPathComponent("tw-ops-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let copied = outside.appendingPathComponent("copied.typ"), moved = outside.appendingPathComponent("moved.typ")
        try "c\n".write(to: copied, atomically: true, encoding: .utf8)
        try "m\n".write(to: moved, atomically: true, encoding: .utf8)

        await step { ws.importItems([copied], into: space, copy: true) }
        XCTAssertEqual(text("copied.typ"), "c\n")
        await undoStep()
        XCTAssertFalse(exists("copied.typ"))
        XCTAssertTrue(fm.fileExists(atPath: copied.path))

        await step { ws.importItems([moved], into: space, copy: false) }
        XCTAssertTrue(exists("moved.typ"))
        XCTAssertFalse(fm.fileExists(atPath: moved.path))
        await undoStep()
        XCTAssertFalse(exists("moved.typ"))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "m\n", "undo moves it back where it came from")
    }

    func testUndoingAPastedImageReferenceRemovesTheImage() async throws {
        ws.select(url("main.typ"))
        let pasteboard = NSPasteboard(name: .init("tw-ops-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47, 0, 1]), forType: .png)
        let reference = try XCTUnwrap(ws.pasteImage(from: pasteboard))
        let image = try XCTUnwrap(try fm.contentsOfDirectory(at: space, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "png" })
        let base = "= Main\n#include \"chapters/one.typ\"\n"
        ws.editorDidUndo(redo: false, text: base)
        await ws.fileOps.settle()
        XCTAssertFalse(fm.fileExists(atPath: image.path))
        ws.editorDidUndo(redo: true, text: base + reference)
        await ws.fileOps.settle()
        XCTAssertTrue(fm.fileExists(atPath: image.path))
        // Undo that doesn't touch the reference leaves the image alone.
        ws.editorDidUndo(redo: false, text: base + reference + "x")
        await ws.fileOps.settle()
        XCTAssertTrue(fm.fileExists(atPath: image.path))
    }

    func testDeletingASpaceUndoes() async throws {
        let ops = FileOperations.spaces
        let manager = UndoManager()
        manager.groupsByEvent = false
        let other = repository.root.appendingPathComponent("Gone \(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try "x\n".write(to: other.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: other) }
        manager.beginUndoGrouping()
        ops.perform(.deleteSpace(other), name: "Delete", message: "Delete space \(other.lastPathComponent)", undoManager: manager)
        manager.endUndoGrouping()
        await ops.settle()
        XCTAssertFalse(fm.fileExists(atPath: other.path))
        let deleted = await repository.deleted()
        XCTAssertTrue(deleted.contains { $0.path == other.lastPathComponent && $0.kind == .folder })
        manager.undo()
        await ops.settle()
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("main.typ"), encoding: .utf8), "x\n")
    }

    func testRestoringNextToAnItemThatTookThePlace() async throws {
        await step { ws.delete(url("chapters/one.typ")) }
        try "New one\n".write(to: url("chapters/one.typ"), atomically: true, encoding: .utf8)
        await repository.commit("Edit")
        // It exists again, so it's not listed; with another name it's not listed either way.
        let listed = await repository.deleted(in: space)
        XCTAssertTrue(listed.isEmpty)
        // Undo can't overwrite the new file.
        await undoStep()
        XCTAssertEqual(text("chapters/one.typ"), "New one\n")
        // Recently Deleted's "Keep Both" restores under a free name.
        try fm.removeItem(at: url("chapters/one.typ"))
        await repository.commit("Delete again")
        let model = RecentlyDeletedModel(scope: space)
        await model.load()
        let item = try XCTUnwrap(model.items.first)
        try "Newest\n".write(to: url("chapters/one.typ"), atomically: true, encoding: .utf8)
        guard case .exists = await model.restore(item) else { return XCTFail("expected a clash") }
        guard case .restored(let restored) = await model.restore(item, keepBoth: true) else { return XCTFail("expected restore") }
        XCTAssertEqual(restored.lastPathComponent, "one-2.typ")
        XCTAssertEqual(text("chapters/one-2.typ"), "New one\n")
        XCTAssertEqual(text("chapters/one.typ"), "Newest\n")
    }
}
