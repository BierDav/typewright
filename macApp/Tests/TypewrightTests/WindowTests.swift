import AppKit
import PDFKit
import XCTest
@testable import Typewright
import TypewrightCore

@MainActor
final class WindowTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func windows(in opener: Opener) -> [NSWindow] {
        NSApp.windows.filter { opener.state(for: $0) != nil }
    }

    private func closeWindows(in opener: Opener) {
        for window in windows(in: opener) {
            opener.state(for: window)?.workspace?.close()
            window.close()
        }
    }

    func testOpenInNewWindowSelectsRequestedFileOnFirstLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-open-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "= Main".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("other.typ")
        try "= Other".write(to: file, atomically: true, encoding: .utf8)
        let opener = Opener()
        defer { closeWindows(in: opener) }
        opener.openInNewWindow(root, file: file)
        try await waitFor { self.windows(in: opener).first.flatMap { opener.state(for: $0)?.workspace?.selectedFile } == file }
    }

    func testQuitRestoresIndependentWindowsSidebarsAndPreviewPositions() async throws {
        let compiler = CompilerManager.shared.selection
        let mode = UserDefaults.standard.object(forKey: "renderMode")
        CompilerManager.shared.selection = CompilerManager.builtin
        UserDefaults.standard.set(RenderMode.pdf.rawValue, forKey: "renderMode")
        defer {
            CompilerManager.shared.selection = compiler
            UserDefaults.standard.set(mode, forKey: "renderMode")
        }
        let suite = "TypewrightTests.windows.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-restore-windows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("chapters")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let main = root.appendingPathComponent("main.typ"), other = root.appendingPathComponent("other.typ")
        let text = "#set page(width: 400pt, height: 900pt)\nOne\n#pagebreak()\nTwo"
        try text.write(to: main, atomically: true, encoding: .utf8)
        try text.write(to: other, atomically: true, encoding: .utf8)
        let opener = Opener(defaults: defaults)
        let restored = Opener(defaults: defaults)
        defer { closeWindows(in: opener); closeWindows(in: restored) }
        opener.openInNewWindow(root, file: main)
        opener.openInNewWindow(root, file: other)
        try await waitFor {
            let states = self.windows(in: opener).compactMap { opener.state(for: $0)?.workspace }
            return states.count == 2 && states.allSatisfy { $0.document != nil }
        }
        let original = windows(in: opener).compactMap { opener.state(for: $0) }
        for state in original {
            let ws = try XCTUnwrap(state.workspace)
            state.sidebarVisible = ws.selectedFile == main
            ws.setPreview(main)
            ws.expanded = ws.selectedFile == main ? [folder] : []
            ws.editorStateDidChange(EditorState(selection: ws.selectedFile == main ? 3 : 7))
        }
        try await waitFor { original.allSatisfy { $0.workspace?.document != nil } }
        for state in original {
            let ws = try XCTUnwrap(state.workspace)
            let position = DocumentPosition(page: ws.selectedFile == main ? 0.2 : 1.1, zoom: 2, pan: 0.3)
            ws.preview.clear()
            ws.preview.pendingPosition = position
            ws.preview.show(try XCTUnwrap(ws.document))
        }
        try await Task.sleep(for: .milliseconds(200))
        opener.prepareToQuit()
        let savedData = try XCTUnwrap(defaults.data(forKey: "openWindows"))
        let saved = try JSONDecoder().decode([WindowSession].self, from: savedData)
        XCTAssertEqual(saved.count, 2)
        closeWindows(in: opener)
        XCTAssertEqual(defaults.data(forKey: "openWindows"), savedData)
        restored.restoreSession()
        try await waitFor { self.windows(in: restored).compactMap { restored.state(for: $0)?.workspace }.count == 2 }
        for window in windows(in: restored) {
            let state = try XCTUnwrap(restored.state(for: window))
            let ws = try XCTUnwrap(state.workspace)
            let expected = try XCTUnwrap(saved.first { $0.workspace?.selected == ws.selectedFile?.lastPathComponent })
            XCTAssertEqual(state.sidebarVisible, expected.sidebarVisible)
            XCTAssertEqual(ws.previewFile, main)
            let selected = try XCTUnwrap(ws.selectedFile)
            XCTAssertEqual(ws.editorState(for: selected), expected.workspace?.editors[selected.lastPathComponent])
            XCTAssertEqual(Set(ws.expanded.map(\.path)), ws.selectedFile == main ? [folder.path] : [])
            let position = try XCTUnwrap(expected.workspace?.positions["main.typ"])
            XCTAssertEqual(position.zoom, 2)
            XCTAssertEqual(ws.session().state.positions["main.typ"], position)
        }
        XCTAssertEqual(Set(windows(in: restored).compactMap { restored.state(for: $0)?.workspace?.selectedFile }), [main, other])
    }

    func testRestoresLegacySessionAndEmptyWindows() async throws {
        let suite = "TypewrightTests.legacy-windows.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-legacy-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set([root.path, root.path], forKey: "openProjects")
        let opener = Opener(defaults: defaults)
        defer { closeWindows(in: opener) }
        opener.restoreSession()
        XCTAssertEqual(windows(in: opener).count, 2)
        closeWindows(in: opener)
        defaults.set(try JSONEncoder().encode([WindowSession(space: nil), WindowSession(space: root.appendingPathComponent("missing"))]),
                     forKey: "openWindows")
        opener.restoreSession()
        XCTAssertEqual(windows(in: opener).count, 1)
        XCTAssertNil(windows(in: opener).first.flatMap { opener.state(for: $0)?.space })
    }

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
        XCTAssertEqual(fork.preview.pendingPosition, position)
        XCTAssertEqual(fork.renderMode, .pdf)
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
