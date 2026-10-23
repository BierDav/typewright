import Darwin
import XCTest
@testable import Typewright

@MainActor
final class SpaceIndexTests: XCTestCase {
    private var root: URL!
    private var cache: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-index-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        cache = root.appendingPathComponent(".cache/index.plist")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String = "= Hello") throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func testDiskCacheSurvivesReloadAndRevalidatesChanges() async throws {
        try write("chapters/one.typ")
        try write("removed.typ")
        try write(".hidden.typ")
        let root = root!, cache = cache!
        let original = try await Task.detached {
            let record = try SpaceIndex.scan(root: root)
            SpaceIndex.save(record, to: cache)
            return record
        }.value
        XCTAssertEqual(original.tree.map(\.name), ["chapters", "removed.typ"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.typ"))
        try write("chapters/two.typ")
        let refreshed = try await Task.detached {
            let loaded = try XCTUnwrap(SpaceIndex.load(root: root, from: cache))
            XCTAssertEqual(loaded.tree, original.tree)
            return try SpaceIndex.scan(root: root, cached: loaded)
        }.value
        XCTAssertEqual(refreshed.tree.map(\.name), ["chapters"])
        XCTAssertEqual(refreshed.tree.first?.children?.map(\.name), ["one.typ", "two.typ"])
    }

    func testIgnoresCorruptAndWrongRootCaches() async throws {
        try write("main.typ")
        let root = root!, cache = cache!
        await Task.detached {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("invalid".utf8).write(to: cache)
            XCTAssertNil(SpaceIndex.load(root: root, from: cache))
            if let record = try? SpaceIndex.scan(root: root) {
                SpaceIndex.save(record, to: cache)
                XCTAssertNil(SpaceIndex.load(root: root.appendingPathComponent("other"), from: cache))
            }
        }.value
    }

    func testNeverOpensPipesOrTraversesDirectoryLinks() async throws {
        try write("main.typ")
        let pipe = root.appendingPathComponent("pipe")
        let typedPipe = root.appendingPathComponent("pipe.typ")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertEqual(mkfifo(typedPipe.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let root = root!
        let record = try await Task.detached {
            XCTAssertEqual(FileKind(url: pipe), .binary)
            XCTAssertEqual(FileKind(url: typedPipe), .binary)
            return try SpaceIndex.scan(root: root)
        }.value
        XCTAssertEqual(record.tree.map(\.name), ["main.typ"])
    }

    func testChangedUnknownFileIsReclassified() async throws {
        try write("unknown", "plain text")
        let root = root!
        let original = try await Task.detached { try SpaceIndex.scan(root: root) }.value
        XCTAssertEqual(original.tree.first?.kind, .text)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("unknown"))
        let refreshed = try await Task.detached { try SpaceIndex.scan(root: root, cached: original) }.value
        XCTAssertEqual(refreshed.tree.first?.kind, .binary)
    }

    func testCancelledScanDoesNotProduceARecord() async throws {
        let root = root!
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SpaceIndex.scan(root: root)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled scan must stop before walking directories")
        } catch is CancellationError {}
    }

    func testWorkspaceFindsDefaultFileAfterBackgroundIndexing() async throws {
        try write("chapters/one.typ")
        let workspace = Workspace(url: root)
        defer { workspace.close() }
        XCTAssertTrue(workspace.isIndexing)
        XCTAssertTrue(workspace.tree.isEmpty)
        await workspace.waitForIndex()
        XCTAssertFalse(workspace.isIndexing)
        XCTAssertEqual(workspace.selectedFile, root.appendingPathComponent("chapters/one.typ"))
        XCTAssertEqual(workspace.previewFile, workspace.selectedFile)
        XCTAssertEqual(workspace.previewMode, .following)
    }

    func testIndexDoesNotOverrideUserSelectionOrRestoreHiddenPreview() async throws {
        try write("one.typ")
        try write("two.typ")
        let workspace = Workspace(url: root, session: WorkspaceSession(state: SpaceState(), buffers: [:]))
        defer { workspace.close() }
        let selected = root.appendingPathComponent("two.typ")
        workspace.select(selected)
        await workspace.waitForIndex()
        XCTAssertEqual(workspace.selectedFile, selected)
        XCTAssertNil(workspace.previewFile)
    }

    func testRefreshesDuringIndexingAreCoalescedAndIncludeLatestChanges() async throws {
        try write("one.typ")
        let workspace = Workspace(url: root)
        defer { workspace.close() }
        for index in 0..<10 {
            try write("new-\(index).typ")
            workspace.reloadTree()
        }
        await workspace.waitForIndex()
        XCTAssertFalse(workspace.isIndexing)
        XCTAssertEqual(workspace.tree.count, 11)
    }

    func testSavedHiddenPreviewStaysHiddenWhenDefaultSelectionArrives() async throws {
        try write("one.typ")
        let workspace = Workspace(url: root, session: WorkspaceSession(state: SpaceState(), buffers: [:]))
        defer { workspace.close() }
        await workspace.waitForIndex()
        XCTAssertEqual(workspace.selectedFile, root.appendingPathComponent("one.typ"))
        XCTAssertNil(workspace.previewFile)
        XCTAssertEqual(workspace.previewMode, .hidden)
    }

    func testScanReportsItemProgressFromTheWorker() async throws {
        try write("chapters/one.typ")
        try write("two.typ")
        let root = root!
        let reports = try await Task.detached {
            var reports: [SpaceIndex.Progress] = []
            _ = try SpaceIndex.scan(root: root) { reports.append($0) }
            return reports
        }.value
        XCTAssertEqual(reports.first?.phase, .scanning)
        XCTAssertEqual(reports.first?.items, 0)
        XCTAssertEqual(reports.last?.items, 3)
        XCTAssertEqual(reports.map(\.items), reports.map(\.items).sorted())
    }

    func testRebuildIgnoresCachedClassificationsAndReplacesDiskIndex() async throws {
        try write("unknown", "plain text")
        let root = root!, directory = cache.deletingLastPathComponent()
        let file = SpaceIndex.cacheFile(for: root, in: directory)
        try await Task.detached {
            let scanned = try SpaceIndex.scan(root: root)
            let entry = try XCTUnwrap(scanned.entries.first)
            let stale = SpaceIndex.Entry(name: entry.name, kind: .binary, modified: entry.modified,
                                         size: entry.size, children: nil)
            SpaceIndex.save(SpaceIndex.Record(version: 1, root: root.path, entries: [stale]), to: file)
        }.value
        var snapshots: [SpaceIndex.Snapshot] = []
        for await update in SpaceIndex.updates(for: root, useCache: true, rebuild: true, cacheDirectory: directory) {
            if case .snapshot(let snapshot) = update { snapshots.append(snapshot) }
        }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.validated, true)
        XCTAssertEqual(snapshots.first?.tree.first?.kind, .text)
        let stored = await Task.detached { SpaceIndex.load(root: root, from: file) }.value
        XCTAssertEqual(stored?.tree.first?.kind, .text)
    }

    func testRebuildRequestedDuringIndexingFinishesAndClearsStatus() async throws {
        try write("one.typ")
        let workspace = Workspace(url: root)
        defer { workspace.close() }
        workspace.rebuildIndex()
        XCTAssertTrue(workspace.isIndexing)
        XCTAssertNotNil(workspace.indexProgress)
        await workspace.waitForIndex()
        workspace.rebuildIndex()
        XCTAssertTrue(workspace.isIndexing)
        await workspace.waitForIndex()
        XCTAssertEqual(workspace.tree.map(\.name), ["one.typ"])
        XCTAssertFalse(workspace.isIndexing)
        XCTAssertFalse(workspace.isRebuildingIndex)
        XCTAssertNil(workspace.indexProgress)
    }

    func testClosingCancelsPendingIndexUpdates() async throws {
        try write("one.typ")
        let workspace = Workspace(url: root)
        workspace.close()
        await Task.yield()
        XCTAssertTrue(workspace.tree.isEmpty)
        XCTAssertFalse(workspace.isIndexing)
        XCTAssertNil(workspace.indexProgress)
    }
}
