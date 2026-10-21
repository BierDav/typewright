import XCTest
@testable import Typewright
import TypewrightCore

@MainActor
final class WindowTests: XCTestCase {
    func testWindowsOnOneSpaceShareUnsavedEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-windows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main.typ")
        let other = root.appendingPathComponent("other.typ")
        try "= Hello".write(to: main, atomically: true, encoding: .utf8)
        try "old".write(to: other, atomically: true, encoding: .utf8)

        let a = Workspace(url: root), b = Workspace(url: root)
        defer { a.close(); b.close() }
        a.select(main)
        b.select(main)
        a.textDidChange("= Hello, world", live: false)
        XCTAssertEqual(b.text, "= Hello, world")
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "= Hello", "only autosave writes")

        // A file the other window doesn't show still reaches its buffers.
        a.updateBuffer(other, text: "new")
        XCTAssertEqual(b.bufferText(other), "new")
    }

    func testOneMinimalEditBetweenTexts() {
        let edit = textDifference(old: "let a = 1", new: "let ab = 1")
        XCTAssertEqual(edit.range.location, 5)
        XCTAssertEqual(edit.range.length, 0)
        XCTAssertEqual(edit.newText, "b")
    }

    func testForkRestoresCurrentSessionAndKeepsNavigationIndependent() throws {
        let mode = UserDefaults.standard.string(forKey: "renderMode")
        defer { UserDefaults.standard.set(mode, forKey: "renderMode") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-fork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main.typ")
        let other = root.appendingPathComponent("other.typ")
        try "= Main".write(to: main, atomically: true, encoding: .utf8)
        try "= Other".write(to: other, atomically: true, encoding: .utf8)
        let source = Workspace(url: root)
        defer { source.close() }
        source.select(other)
        source.setPreview(main)
        source.renderMode = .svg
        source.split = 0.65
        source.textDidChange("= Unsaved text", live: false)
        let cursor = EditorState(selection: 5, length: 3, top: 2)
        source.editorStateDidChange(cursor)
        var snapshot = source.session()
        let position = DocumentPosition(page: 2.5, zoom: 1.75, pan: 0.3, mode: .svg)
        snapshot.state.positions["main.typ"] = position
        let fork = Workspace(url: root, session: snapshot)
        defer { fork.close() }

        XCTAssertEqual(fork.selectedFile, other)
        XCTAssertEqual(fork.previewFile, main)
        XCTAssertEqual(fork.text, "= Unsaved text")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "= Other")
        XCTAssertEqual(fork.editorState(for: other), cursor)
        XCTAssertEqual(fork.svgPreview.pendingRestore, position)
        XCTAssertEqual(fork.renderMode, .svg)
        XCTAssertEqual(fork.split, 0.65)

        fork.editorStateDidChange(EditorState(selection: 1))
        fork.select(main)
        fork.setPreview(other)
        XCTAssertEqual(source.selectedFile, other)
        XCTAssertEqual(source.previewFile, main)
        XCTAssertEqual(source.editorState(for: other), cursor)
    }

    func testWindowCopiesTheActiveSessionInsteadOfSavedState() throws {
        let width = UserDefaults.standard.object(forKey: "sidebarWidth")
        defer { UserDefaults.standard.set(width, forKey: "sidebarWidth") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-window-fork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.typ")
        try "= Main".write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace(url: root)
        defer { workspace.close() }
        workspace.setPreview(nil)
        workspace.editorStateDidChange(EditorState(selection: 3, top: 1))
        let source = WindowState(space: root)
        source.workspace = workspace
        source.sidebarVisible = false
        source.sidebarFrame.size.width = 280
        let copied = WindowState(space: root, copying: source)
        let session = try XCTUnwrap(copied.pendingSession)
        XCTAssertEqual(session.state.selected, "main.typ")
        XCTAssertNil(session.state.preview)
        XCTAssertEqual(session.state.editors["main.typ"], EditorState(selection: 3, top: 1))
        XCTAssertFalse(copied.sidebarVisible)
        XCTAssertEqual(copied.initialSidebarWidth, 280)
        let fork = Workspace(url: root, session: session)
        defer { fork.close() }
        XCTAssertNil(fork.previewFile)
    }
}
