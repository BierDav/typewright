import XCTest
@testable import Typewright

@MainActor
final class PreviewStateTests: XCTestCase {
    func testFontFoldersAreFoundInEveryFolderAbove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-fonts-\(UUID().uuidString)")
        let deep = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b/fonts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let found = FontSearch.directories(FontSearch.Settings(space: ["fonts"], machine: []), from: deep)
            .filter { $0.path.hasPrefix(root.standardizedFileURL.path) }
        XCTAssertEqual(found.map(\.path), [
            root.appendingPathComponent("a/b/fonts").standardizedFileURL.path,
            root.appendingPathComponent("fonts").standardizedFileURL.path,
        ], "nearest first")
    }

    func testPositionsSavedBeforeFormatsAndPanStillLoad() throws {
        let old = #"{"page": 2.5, "zoom": 1.5, "flow": 0.25}"#
        let position = try JSONDecoder().decode(DocumentPosition.self, from: Data(old.utf8))
        XCTAssertEqual(position, DocumentPosition(page: 2.5, zoom: 1.5, flow: 0.25))

        let saved = DocumentPosition(page: 1, pan: 0.5, mode: .svg)
        let decoded = try JSONDecoder().decode(DocumentPosition.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
    }

    func testEachFileKeepsItsFormat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.typ"), b = root.appendingPathComponent("b.typ")
        try "= A".write(to: a, atomically: true, encoding: .utf8)
        try "= B".write(to: b, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard.string(forKey: "renderMode")
        defer { UserDefaults.standard.set(defaults, forKey: "renderMode") }

        let ws = Workspace(url: root)
        defer { ws.close() }
        ws.setPreview(a)
        ws.renderMode = .html
        ws.setPreview(b)
        ws.renderMode = .svg
        ws.setPreview(a)
        XCTAssertEqual(ws.renderMode, .html)
        ws.setPreview(b)
        XCTAssertEqual(ws.renderMode, .svg)
    }
}
