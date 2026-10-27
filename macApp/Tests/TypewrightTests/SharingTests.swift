import XCTest
@testable import Typewright

@MainActor
final class SharingTests: XCTestCase {
    func testDestinationListsOnlyLibraryFolders() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("Library")
        let space = root.appendingPathComponent("Space")
        let nestedRepo = root.appendingPathComponent("Nested/.jj")
        let outside = base.appendingPathComponent("Outside")
        defer { try? fm.removeItem(at: base) }
        for folder in [space, nestedRepo, outside] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("Escape"), withDestinationURL: outside)
        let page = LibraryDestination.page(at: root, name: "Shared.typ", file: true, root: root) { _ in }
        guard case .list(let list) = page.kind else { return XCTFail("Expected folders") }
        let items = list()
        XCTAssertTrue(items.contains { $0.title == "Space" })
        XCTAssertFalse(items.contains { $0.title == "Escape" || $0.title == "Nested" })
        XCTAssertFalse(items.contains { $0.id == "join.here" }, "Files must join inside a space")
    }

    func testJoiningFileUsesChosenFolderAndRejectsPathTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Space/Chapters")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var destination: URL?
        let page = LibraryDestination.page(at: folder, name: "Shared.typ", file: true, root: root) { destination = $0 }
        guard case .list(let list) = page.kind,
              let item = list().first(where: { $0.id == "join.here" }),
              case .page(let input) = item.action,
              case .input(_, let submit) = input.kind else { return XCTFail("Expected destination name input") }
        for name in ["", ".", "..", "../escape.typ", "bad\0name"] { submit(name) }
        XCTAssertNil(destination)
        submit("Shared.typ")
        XCTAssertEqual(destination, folder.appendingPathComponent("Shared.typ").standardizedFileURL)
    }
}
