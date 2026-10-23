import XCTest
@testable import Typewright

@MainActor
final class SpaceStorageTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-storage-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func defaults() -> UserDefaults {
        let name = "tw-storage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - Commit timing

    func testCommitsFiveSecondsAfterTheLastChange() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var timing = CommitTiming()
        XCTAssertNil(timing.deadline)
        timing.change(at: t0)
        XCTAssertEqual(timing.deadline, t0.addingTimeInterval(5))
        timing.change(at: t0.addingTimeInterval(3))
        XCTAssertEqual(timing.deadline, t0.addingTimeInterval(8))
        XCTAssertFalse(timing.isDue(at: t0.addingTimeInterval(7)))
        XCTAssertTrue(timing.isDue(at: t0.addingTimeInterval(8)))
        timing.committed()
        XCTAssertNil(timing.deadline)
        XCTAssertFalse(timing.isDue(at: t0.addingTimeInterval(100)))
    }

    func testKeepsCommittingEveryMinuteWhileChangesKeepComing() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var timing = CommitTiming()
        for second in stride(from: 0.0, through: 70, by: 2) {
            let now = t0.addingTimeInterval(second)
            if timing.isDue(at: now) {
                XCTAssertEqual(second, 60, "the first commit lands at the limit")
                timing.committed()
            }
            timing.change(at: now)
        }
        XCTAssertEqual(timing.firstChange, t0.addingTimeInterval(60))
        XCTAssertEqual(timing.deadline, t0.addingTimeInterval(75))
    }

    func testRetriesWhenTheRepositoryIsBusy() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var timing = CommitTiming()
        timing.retry(at: t0.addingTimeInterval(2))
        XCTAssertEqual(timing.deadline, t0.addingTimeInterval(2))
        XCTAssertFalse(timing.isDue(at: t0.addingTimeInterval(1)))
        timing.change(at: t0.addingTimeInterval(1))
        XCTAssertEqual(timing.deadline, t0.addingTimeInterval(6))
    }

    func testIgnoresJJAndFinderMetadata() {
        let root = "/repo"
        XCTAssertTrue(CommitTiming.counts("/repo/Thesis/main.typ", root: root))
        XCTAssertTrue(CommitTiming.counts("/repo", root: root))
        XCTAssertFalse(CommitTiming.counts("/repo/.jj", root: root))
        XCTAssertFalse(CommitTiming.counts("/repo/.jj/repo/op_store/x", root: root))
        XCTAssertFalse(CommitTiming.counts("/repo/Thesis/.DS_Store", root: root))
        XCTAssertTrue(CommitTiming.counts("/repo/.jjx/file", root: root))
        XCTAssertFalse(CommitTiming.counts("/elsewhere/file", root: root))
    }

    func testSquashesAtMostHourly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(HistorySettings.squashIsDue(last: nil, now: now))
        XCTAssertFalse(HistorySettings.squashIsDue(last: now.addingTimeInterval(-600), now: now))
        XCTAssertTrue(HistorySettings.squashIsDue(last: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(HistorySettings.squashIsDue(last: now.addingTimeInterval(3600), now: now), "a clock set back")
    }

    func testRetentionPolicySettings() throws {
        let defaults = defaults()
        XCTAssertEqual(HistorySettings.policy(defaults), .standard)
        XCTAssertEqual(RetentionPolicy.standard, RetentionPolicy(last: 100, hourly: 48, daily: 14, weekly: 8, monthly: 12, yearly: -1))
        defaults.set(7, forKey: HistorySettings.keys.daily)
        defaults.set(5, forKey: HistorySettings.keys.yearly)
        defaults.set(-3, forKey: HistorySettings.keys.last)
        let policy = try XCTUnwrap(HistorySettings.policy(defaults))
        XCTAssertEqual(policy.daily, 7)
        XCTAssertEqual(policy.yearly, 5)
        XCTAssertEqual(policy.last, 0, "only yearly can be unlimited")
        defaults.set(false, forKey: HistorySettings.squashKey)
        XCTAssertNil(HistorySettings.policy(defaults))

        // The old days setting gives way to the new defaults.
        let old = self.defaults()
        old.set(30, forKey: HistorySettings.legacyDaysKey)
        HistorySettings.migrate(old)
        XCTAssertNil(old.object(forKey: HistorySettings.legacyDaysKey))
        XCTAssertEqual(HistorySettings.policy(old), .standard)

        let json = try JSONSerialization.jsonObject(with: Data(RetentionPolicy.standard.json.utf8)) as? [String: Int]
        XCTAssertEqual(json, ["last": 100, "hourly": 48, "daily": 14, "weekly": 8, "monthly": 12, "yearly": -1])
    }

    // MARK: - Space folders

    func testNewSpacesGetUniqueNames() throws {
        let root = dir.appendingPathComponent("Spaces")
        let first = try SpaceFolders.create(named: "Thesis", in: root)
        let second = try SpaceFolders.create(named: "thesis", in: root)
        let untitled = try SpaceFolders.create(named: "  ", in: root)
        let slashed = try SpaceFolders.create(named: "a/b", in: root)
        XCTAssertEqual(first.lastPathComponent, "Thesis")
        XCTAssertEqual(second.lastPathComponent, "thesis 2")
        XCTAssertEqual(untitled.lastPathComponent, "Untitled Space")
        XCTAssertEqual(slashed.lastPathComponent, "a-b")

        try FileManager.default.createDirectory(at: root.appendingPathComponent(".jj"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("loose.txt").path, contents: Data())
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: first)
        // A workspace added inside the library isn't a space, nor is a `.jj` moved aside.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ws/.jj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".jj.broken-20261023-101010"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(SpaceFolders.spaces(in: root).map(\.lastPathComponent), ["a-b", "Thesis", "thesis 2", "Untitled Space"])
    }

    func testDetectsGitRepositories() throws {
        let root = dir.appendingPathComponent("Spaces")
        let plain = try SpaceFolders.create(named: "Plain", in: root)
        let git = try SpaceFolders.create(named: "Checkout", in: root)
        try FileManager.default.createDirectory(at: git.appendingPathComponent(".git"), withIntermediateDirectories: true)
        // A worktree or submodule has a `.git` file instead of a folder.
        let nested = git.appendingPathComponent("docs/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("vendor"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: plain.appendingPathComponent("vendor/.git").path, contents: Data("gitdir: x".utf8))
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertTrue(SpaceFolders.isGitRepository(git))
        XCTAssertFalse(SpaceFolders.isGitRepository(plain))
        XCTAssertEqual(SpaceFolders.spaces(in: root).map(\.lastPathComponent), ["Checkout", "Plain"], "git checkouts stay spaces")
        XCTAssertEqual(SpaceFolders.gitRepository(containing: nested.appendingPathComponent("a.typ"), below: root)?.path,
                       git.resolvingSymlinksInPath().path)
        XCTAssertEqual(SpaceFolders.gitRepository(containing: plain.appendingPathComponent("vendor/x.typ"), below: root)?.path,
                       plain.appendingPathComponent("vendor").resolvingSymlinksInPath().path)
        XCTAssertNil(SpaceFolders.gitRepository(containing: plain.appendingPathComponent("main.typ"), below: root))
        // The library itself may be a git checkout; only folders below it count.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertNil(SpaceFolders.gitRepository(containing: plain.appendingPathComponent("main.typ"), below: root))
    }

    func testImportKeepingTheOriginal() throws {
        let root = dir.appendingPathComponent("Spaces")
        let source = try folder("Paper", files: ["main.typ": "= Hi", "img/a.svg": "<svg/>"])
        let target = try SpaceFolders.importFolder(source, into: root, mode: .keepOriginal) { _ in XCTFail("no trash") }
        XCTAssertEqual(target, root.appendingPathComponent("Paper", isDirectory: true).standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("img/a.svg"), encoding: .utf8), "<svg/>")
        XCTAssertFalse(SpaceFolders.isLink(source))

        let again = try SpaceFolders.importFolder(source, into: root, mode: .keepOriginal)
        XCTAssertEqual(again.lastPathComponent, "Paper 2")
    }

    func testImportReplacingTheOriginalWithALink() throws {
        let root = dir.appendingPathComponent("Spaces")
        let source = try folder("Paper", files: ["main.typ": "= Hi"])
        let trash = dir.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let target = try SpaceFolders.importFolder(source, into: root, mode: .replaceWithLink) {
            try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent))
        }
        XCTAssertTrue(SpaceFolders.isLink(source))
        XCTAssertEqual(source.resolvingSymlinksInPath().path, target.resolvingSymlinksInPath().path)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("main.typ"), encoding: .utf8), "= Hi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Paper/main.typ").path))
    }

    func testImportDeletingTheOriginal() throws {
        let root = dir.appendingPathComponent("Spaces")
        let source = try folder("Paper", files: ["main.typ": "= Hi"])
        let trash = dir.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let target = try SpaceFolders.importFolder(source, into: root, mode: .deleteOriginal) {
            try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(SpaceFolders.isLink(source))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("main.typ"), encoding: .utf8), "= Hi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Paper/main.typ").path))
    }

    func testFailedTrashLeavesEverythingAsItWas() throws {
        struct Refused: Error {}
        let root = dir.appendingPathComponent("Spaces")
        let source = try folder("Paper", files: ["main.typ": "= Hi"])
        XCTAssertThrowsError(try SpaceFolders.importFolder(source, into: root, mode: .replaceWithLink) { _ in throw Refused() })
        XCTAssertFalse(SpaceFolders.isLink(source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("main.typ").path))
        XCTAssertTrue(SpaceFolders.spaces(in: root).isEmpty)
    }

    func testRefusesToImportTheRepositoryOrWhatsInIt() throws {
        let root = dir.appendingPathComponent("Spaces")
        let space = try SpaceFolders.create(named: "Thesis", in: root)
        XCTAssertThrowsError(try SpaceFolders.importFolder(space, into: root, mode: .keepOriginal)) {
            XCTAssertEqual($0 as? SpaceFolders.ImportError, .insideRepository)
        }
        XCTAssertThrowsError(try SpaceFolders.importFolder(dir, into: root, mode: .keepOriginal)) {
            XCTAssertEqual($0 as? SpaceFolders.ImportError, .containsRepository)
        }
    }

    func testPreparingTheRepositoryIgnoresFinderMetadataOnce() throws {
        SpaceFolders.prepareRepository(dir)
        let ignore = dir.appendingPathComponent(".gitignore")
        XCTAssertEqual(try String(contentsOf: ignore, encoding: .utf8), ".DS_Store\n")
        try "custom\n".write(to: ignore, atomically: true, encoding: .utf8)
        SpaceFolders.prepareRepository(dir)
        XCTAssertEqual(try String(contentsOf: ignore, encoding: .utf8), "custom\n")
    }

    // MARK: - Space list

    func testRepositoryFoldersFollowTheStoredOrder() throws {
        let root = dir.appendingPathComponent("Spaces")
        let a = try SpaceFolders.create(named: "A", in: root)
        let b = try SpaceFolders.create(named: "B", in: root)
        let outside = try folder("Outside", files: [:])
        let gone = dir.appendingPathComponent("Gone/main.typ").path
        let order = SpaceList.order(stored: [b.path, gone, outside.path, b.path], repository: SpaceFolders.spaces(in: root))
        XCTAssertEqual(order.map(\.lastPathComponent), ["B", "Outside", "A"])
        _ = a
    }

    // MARK: - Migration

    func testMigrationAsksOnlyAboutSpacesOutsideTheRepository() throws {
        let root = dir.appendingPathComponent("Spaces")
        let inside = try SpaceFolders.create(named: "Inside", in: root)
        let old = try folder("Old", files: [:])
        let other = try folder("Other", files: [:])
        let defaults = defaults()
        XCTAssertEqual(SpaceMigration.pending([inside, old, other], repository: root, answered: SpaceMigration.answered(in: defaults)),
                       [old, other])
        SpaceMigration.markAnswered(old, in: defaults)
        XCTAssertEqual(SpaceMigration.pending([inside, old, other], repository: root, answered: SpaceMigration.answered(in: defaults)),
                       [other])
    }

    func testGitCheckoutsDefaultToStayingWhereTheyAre() throws {
        let plain = try folder("Essay", files: ["main.typ": "= Essay"])
        let checkout = try folder("Thesis", files: ["main.typ": "= Thesis"])
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertEqual(SpaceMigration.defaultChoice(for: plain), .replaceWithLink)
        XCTAssertEqual(SpaceMigration.defaultChoice(for: checkout), .leaveAsIs)
    }

    // MARK: - Links

    func testLinksFollowRenamesAndGoWithTheItem() throws {
        let root = dir.appendingPathComponent("Spaces")
        let space = try SpaceFolders.create(named: "Thesis", in: root)
        let docs = try folder("Documents", files: [:])
        let links = SpaceLinks(defaults: defaults())
        try links.create(to: space, at: docs.appendingPathComponent("Thesis"))
        let file = space.appendingPathComponent("main.typ")
        FileManager.default.createFile(atPath: file.path, contents: Data("= Hi".utf8))
        try links.create(to: file, at: docs.appendingPathComponent("main.typ"))
        XCTAssertEqual(links.links(to: space).count, 1)

        let renamed = root.appendingPathComponent("Dissertation")
        try FileManager.default.moveItem(at: space, to: renamed)
        links.moved(from: space, to: renamed)
        XCTAssertTrue(SpaceFolders.isLink(docs.appendingPathComponent("Dissertation")), "a link named like the space is renamed too")
        XCTAssertFalse(SpaceFolders.isLink(docs.appendingPathComponent("Thesis")))
        XCTAssertEqual(try String(contentsOf: docs.appendingPathComponent("main.typ"), encoding: .utf8), "= Hi")

        links.removed(renamed)
        XCTAssertTrue(links.links.isEmpty)
        XCTAssertFalse(SpaceFolders.isLink(docs.appendingPathComponent("main.typ")))
    }

    func testFindsLinksThroughAnotherSpellingOfTheTarget() throws {
        let space = try folder("Thesis", files: [:])
        let docs = try folder("Documents", files: [:])
        let links = SpaceLinks(defaults: defaults())
        try links.create(to: space, at: docs.appendingPathComponent("Thesis"))
        // The spaces list holds resolved paths; temporary folders resolve through /private.
        let spelled = URL(fileURLWithPath: "/private" + space.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spelled.path))
        XCTAssertEqual(links.links(to: spelled).count, 1)
    }

    func testForgetsLinksDeletedOutsideTheApp() throws {
        let space = try folder("Thesis", files: [:])
        let docs = try folder("Documents", files: [:])
        let store = defaults()
        let links = SpaceLinks(defaults: store)
        let link = try links.create(to: space, at: docs.appendingPathComponent("Thesis"))
        try FileManager.default.removeItem(at: link.url)
        XCTAssertTrue(SpaceLinks(defaults: store).links.isEmpty)
    }

    private func folder(_ name: String, files: [String: String]) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        for (path, text) in files {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
}
