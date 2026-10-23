import AppKit
import XCTest
@testable import Typewright

@MainActor
final class FileWatcherTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var workspace: Workspace?

    override func setUp() async throws {
        root = SpaceList.repository.appendingPathComponent("Watch \(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        try "= Main".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        try "= One".write(to: root.appendingPathComponent("chapters/one.typ"), atomically: true, encoding: .utf8)
        await SpaceRepository.shared.commit("Add watcher test space")
        LibraryWatcher.shared.start()
        await LibraryWatcher.shared.refreshNow()
        workspace = Workspace(url: root)
    }

    override func tearDown() async throws {
        workspace?.close()
        workspace = nil
        SpaceList.remove(root)
        try? fm.removeItem(at: root)
        await SpaceRepository.shared.commit("Remove watcher test space")
        await LibraryWatcher.shared.refreshNow()
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testExternalFolderRenamePreservesUnsavedTextPreviewAndSelection() async throws {
        let ws = try XCTUnwrap(workspace)
        let from = root.appendingPathComponent("chapters"), to = root.appendingPathComponent("sections")
        let file = from.appendingPathComponent("one.typ"), moved = to.appendingPathComponent("one.typ")
        ws.select(file)
        ws.setPreview(file)
        ws.expanded.insert(from)
        ws.editorStateDidChange(EditorState(selection: 2, top: 1))
        ws.textDidChange("= Unsaved", live: false)
        try fm.moveItem(at: from, to: to)
        // A save before jj reports the move must not recreate the old file.
        ws.flushSaves()
        XCTAssertFalse(fm.fileExists(atPath: from.path))
        await LibraryWatcher.shared.refreshNow()
        XCTAssertEqual(ws.selectedFile, moved)
        XCTAssertEqual(ws.previewFile, moved)
        XCTAssertEqual(ws.previewMode, .pinned)
        XCTAssertEqual(ws.text, "= Unsaved")
        XCTAssertEqual(ws.editorState(for: moved)?.selection, 2)
        XCTAssertTrue(ws.expanded.contains { $0.path == to.path })
        ws.flushSaves()
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "= Unsaved")
    }

    func testLiveEventsFollowRenamesNewFilesAndEdits() async throws {
        let ws = try XCTUnwrap(workspace)
        let file = root.appendingPathComponent("main.typ"), renamed = root.appendingPathComponent("renamed.typ")
        ws.setPreview(file)
        try fm.moveItem(at: file, to: renamed)
        try await waitFor { ws.selectedFile == renamed && ws.previewFile == renamed }
        let added = root.appendingPathComponent("extra.typ")
        try "= Extra".write(to: added, atomically: true, encoding: .utf8)
        try await waitFor { ws.tree.contains { $0.url == added } }
        try "= Externally edited".write(to: renamed, atomically: true, encoding: .utf8)
        try await waitFor { ws.text == "= Externally edited" }
    }

    func testInternalRenameIsNotReportedAgain() async throws {
        let ws = try XCTUnwrap(workspace)
        let file = root.appendingPathComponent("main.typ")
        var count = 0
        let observer = NotificationCenter.default.addObserver(forName: SpaceRepository.didMove, object: nil, queue: .main) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        ws.rename(file, to: "renamed.typ")
        await LibraryWatcher.shared.refreshNow()
        XCTAssertEqual(count, 1)
    }

    func testExternalSpaceRenameKeepsWindowAndUnsavedText() async throws {
        workspace?.close()
        workspace = nil
        let old = root!
        let renamed = old.deletingLastPathComponent().appendingPathComponent("Renamed \(UUID().uuidString)")
        let controller = Opener.shared.newWindow()
        let state = controller.state
        state.pendingSession = nil
        Opener.shared.open(old, in: state)
        defer {
            state.workspace?.close()
            controller.close()
        }
        try await waitFor { state.workspace?.root.path == old.path }
        state.workspace?.textDidChange("= Unsaved", live: false)
        try fm.moveItem(at: old, to: renamed)
        root = renamed
        try await waitFor { state.workspace?.root.path == renamed.path }
        XCTAssertEqual(state.workspace?.selectedFile, renamed.appendingPathComponent("main.typ"))
        XCTAssertEqual(state.workspace?.text, "= Unsaved")
        state.workspace?.flushSaves()
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: renamed.appendingPathComponent("main.typ"), encoding: .utf8), "= Unsaved")
    }

    func testRefreshPreservesUnsavedEditsInOtherWindows() async throws {
        let ws = try XCTUnwrap(workspace)
        let other = Workspace(url: root)
        defer { other.close() }
        ws.textDidChange("= Shared unsaved text", live: false)
        await LibraryWatcher.shared.refreshNow()
        XCTAssertEqual(other.text, "= Shared unsaved text")
        let file = root.appendingPathComponent("main.typ"), renamed = root.appendingPathComponent("renamed.typ")
        try fm.moveItem(at: file, to: renamed)
        await LibraryWatcher.shared.refreshNow()
        XCTAssertEqual(ws.selectedFile, renamed)
        XCTAssertEqual(other.selectedFile, renamed)
        XCTAssertEqual(other.text, "= Shared unsaved text")
    }
}
