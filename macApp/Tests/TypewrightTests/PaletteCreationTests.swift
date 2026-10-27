import XCTest
@testable import Typewright

@MainActor
final class PaletteCreationTests: XCTestCase {
    func testNewFileUsesVisibleSpaceRelativePathAndSuggestsFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-create-\(UUID().uuidString)")
        let chapters = root.appendingPathComponent("chapters")
        try FileManager.default.createDirectory(at: chapters.appendingPathComponent("figures"), withIntermediateDirectories: true)
        let workspace = Workspace(url: root)
        defer {
            workspace.close()
            try? FileManager.default.removeItem(at: root)
        }
        await workspace.waitForIndex()
        var created = false
        let page = PalettePage.newFile(in: workspace, folder: chapters) { created = true }
        guard case .input(let initial, let submit) = page.kind else { return XCTFail("Expected a path input") }
        XCTAssertEqual(initial, "chapters/")
        XCTAssertEqual(page.suggestions?("chapters/f"), ["chapters/figures/"])
        XCTAssertEqual(page.inputHint?("chapters/hello-world"), ".typ will be added")
        XCTAssertNil(page.inputHint?("chapters/hello-world.txt"))
        submit("test/hello-world")
        XCTAssertTrue(created)
        XCTAssertEqual(workspace.selectedFile, workspace.root.appendingPathComponent("test/hello-world.typ"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("test/hello-world.typ").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: chapters.appendingPathComponent("test").path))
        await workspace.waitForIndex()
    }
}
