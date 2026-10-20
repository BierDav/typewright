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
        let edit = TypewrightCore.TextEdits.shared.difference(old: "let a = 1", new: "let ab = 1")
        XCTAssertEqual(edit.range.location, 5)
        XCTAssertEqual(edit.range.length, 0)
        XCTAssertEqual(edit.newText, "b")
    }
}
