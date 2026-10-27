import IrohBridge
import TypewrightCore
import XCTest
@testable import Typewright

/// Shares on one device, without the network.
@MainActor
final class SyncTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "typewright-test-\(UUID().uuidString)")!
    }

    func testSpacesSyncedBeforeSharesKeepSyncing() throws {
        let repository = SpaceRepository(root: dir.appendingPathComponent("Library"))
        let thesis = repository.url(of: "Thesis")
        try FileManager.default.createDirectory(at: thesis, withIntermediateDirectories: true)
        let outside = dir.appendingPathComponent("Elsewhere/Paper", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let store = defaults()
        store.set(["thesis-id": thesis.path, "paper-id": outside.path], forKey: "syncedSpaces")

        // Only library spaces carry over; external ones no longer sync.
        let sync = SyncService(defaults: store, repository: repository, deviceName: "Test")
        XCTAssertEqual(sync.shares["thesis-id"], LocalShare(path: "Thesis", kind: .space))
        XCTAssertEqual(sync.shareID(for: thesis), "thesis-id")
        XCTAssertNil(sync.shareID(for: outside))
        XCTAssertNil(store.dictionary(forKey: "syncedSpaces"))

        // It survives a relaunch.
        let again = SyncService(defaults: store, repository: repository, deviceName: "Test")
        XCTAssertEqual(again.shares.count, 1)
        XCTAssertEqual(again.shares["thesis-id"], LocalShare(path: "Thesis", kind: .space))
    }

    func testSharePathsFollowRenames() throws {
        let repository = SpaceRepository(root: dir.appendingPathComponent("Library"))
        let store = defaults()
        let thesis = repository.url(of: "Thesis")
        try FileManager.default.createDirectory(at: thesis.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        store.set(["s": thesis.path, "c": thesis.appendingPathComponent("chapters").path], forKey: "syncedSpaces")
        let sync = SyncService(defaults: store, repository: repository, deviceName: "Test")
        XCTAssertEqual(sync.shares["c"]?.kind, .folder)
        XCTAssertTrue(sync.syncsAnything(in: thesis))
        XCTAssertFalse(sync.syncsAnything(in: repository.url(of: "Other")))

        sync.moved(from: thesis, to: repository.url(of: "Dissertation"))
        XCTAssertEqual(sync.shares["s"]?.path, "Dissertation")
        XCTAssertEqual(sync.shares["c"]?.path, "Dissertation/chapters")
    }

    func testSharesFollowMovesAndComeBackWithRestoredFolders() async throws {
        let repository = SpaceRepository(root: dir.appendingPathComponent("Library"))
        let store = defaults()
        let thesis = repository.url(of: "Thesis")
        let chapters = thesis.appendingPathComponent("chapters")
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        try "= One".write(to: chapters.appendingPathComponent("one.typ"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repository.url(of: "Other"), withIntermediateDirectories: true)
        try "x".write(to: repository.url(of: "Other/main.typ"), atomically: true, encoding: .utf8)
        await repository.commit()
        store.set(["s": thesis.path, "c": chapters.path, "o": repository.url(of: "Other").path], forKey: "syncedSpaces")
        let sync = SyncService(defaults: store, repository: repository, deviceName: "Test")

        // A move in the file tree (or its undo) takes the nested share along.
        let parts = thesis.appendingPathComponent("parts")
        try FileManager.default.moveItem(at: chapters, to: parts)
        repository.noteMoved(from: chapters, to: parts)
        XCTAssertEqual(sync.shares["c"]?.path, "Thesis/parts")

        // Deleting the space parks both of its shares; the other one keeps syncing.
        let deletedSpace = await repository.delete([thesis], message: "Delete space Thesis")
        let items = try XCTUnwrap(deletedSpace)
        XCTAssertEqual(Set(sync.shares.keys), ["o"])
        XCTAssertEqual(Set(sync.parked.keys), ["s", "c"])
        XCTAssertEqual(SyncService(defaults: store, repository: repository, deviceName: "Test").parked.count, 2, "survives a relaunch")

        // Undo (or Recently Deleted) brings them back where the space comes back.
        let outcome = await repository.restore(items[0], to: thesis)
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(sync.shares["s"]?.path, "Thesis")
        XCTAssertEqual(sync.shares["c"]?.path, "Thesis/parts")
        XCTAssertTrue(sync.parked.isEmpty)

        // Deleting a file inside a share parks nothing.
        _ = await repository.delete([parts.appendingPathComponent("one.typ")], message: "Delete")
        XCTAssertEqual(sync.shares.count, 3)
    }

    func testSharesLeavingTheLibraryStopAndComeBackWithIt() throws {
        let repository = SpaceRepository(root: dir.appendingPathComponent("Library"))
        let store = defaults()
        let paper = repository.url(of: "Paper")
        try FileManager.default.createDirectory(at: paper.appendingPathComponent("notes"), withIntermediateDirectories: true)
        store.set(["p": paper.path, "n": paper.appendingPathComponent("notes").path], forKey: "syncedSpaces")
        let sync = SyncService(defaults: store, repository: repository, deviceName: "Test")

        // Undoing an import moves the folder back out; its shares stop instead of reporting it missing.
        let outside = dir.appendingPathComponent("Desktop/Paper", isDirectory: true)
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: paper, to: outside)
        repository.noteMoved(from: paper, to: outside)
        XCTAssertTrue(sync.shares.isEmpty)
        XCTAssertEqual(sync.parked["n"]?.outside, outside.appendingPathComponent("notes").standardizedFileURL.path)
        XCTAssertTrue(sync.problems.isEmpty)

        // Redoing the import picks them back up.
        let back = repository.url(of: "Paper")
        try FileManager.default.moveItem(at: outside, to: back)
        repository.noteMoved(from: outside, to: back)
        XCTAssertEqual(sync.shares["p"], LocalShare(path: "Paper", kind: .space))
        XCTAssertEqual(sync.shares["n"], LocalShare(path: "Paper/notes", kind: .folder))
        XCTAssertTrue(sync.parked.isEmpty)

        // Parked shares can be forgotten from Devices settings.
        try FileManager.default.moveItem(at: back, to: outside)
        repository.noteMoved(from: back, to: outside)
        sync.forgetParked("p")
        sync.forgetParked("n")
        XCTAssertTrue(SyncService(defaults: store, repository: repository, deviceName: "Test").parked.isEmpty)
    }

    func testFindsTheShareOfAFile() {
        let shares = [SharePath(id: "s", path: "Thesis", file: false), SharePath(id: "f", path: "Thesis/notes.typ", file: true)]
        XCTAssertEqual(sharePlace(shares: shares, path: "Thesis/main.typ"), SharePlace(id: "s", inside: "main.typ"))
        XCTAssertEqual(sharePlace(shares: shares, path: "Thesis/notes.typ"), SharePlace(id: "f", inside: "@file"))
        XCTAssertNil(sharePlace(shares: shares, path: "Other/main.typ"))
        XCTAssertEqual(sharesTouched(shares: shares, changed: ["Thesis/notes.typ"]), ["f", "s"])
    }
}

/// Two devices in this process, each with its own library, over the real n0 relays.
/// Run with `TEST_RUNNER_TYPEWRIGHT_NETWORK_TESTS=1 xcodebuild … test`.
@MainActor
final class SyncNetworkTests: XCTestCase {
    private var dir: URL!
    private var devices: [SyncService] = []

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TYPEWRIGHT_NETWORK_TESTS"] != nil, "needs network")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        devices.forEach { $0.stop() }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func device(_ name: String, account: Data) async throws -> SyncService {
        let repository = SpaceRepository(root: dir.appendingPathComponent("\(name)-library", isDirectory: true))
        let service = SyncService(defaults: UserDefaults(suiteName: "typewright-test-\(UUID().uuidString)")!,
                                  repository: repository, deviceName: name.uppercased())
        let ok = await service.start(account: account, in: dir.appendingPathComponent("\(name)-data"))
        XCTAssertTrue(ok)
        devices.append(service)
        return service
    }

    private func account() -> Data { Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }) }

    private func eventually(_ what: String, timeout: Double = 120, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// What the app's commit scheduler does a few seconds after an edit.
    private func commit(_ devices: SyncService...) async {
        for device in devices { await device.repository.commit() }
    }

    /// A space of `a` with `main.typ`, downloaded by a second device `b` of the same account.
    private func sharedSpace(_ text: String) async throws -> (SyncService, URL, SyncService, URL) {
        let account = account()
        let a = try await device("a", account: account)
        let b = try await device("b", account: account)
        let rootA = a.repository.url(of: "Notes")
        try write(text, to: rootA.appendingPathComponent("main.typ"))
        await commit(a)
        XCTAssertNotNil(a.share(rootA))
        try await eventually("space listed on b") { !b.elsewhere.isEmpty }
        let share = b.elsewhere[0]
        XCTAssertEqual(share.kind, .space)
        let rootB = try XCTUnwrap(b.join(share, at: b.suggestedDestination(for: share)))
        try await eventually("file on b") { read(rootB.appendingPathComponent("main.typ")) == text }
        return (a, rootA, b, rootB)
    }

    func testSyncsASpaceBetweenTwoDevices() async throws {
        let account = account()
        let a = try await device("a", account: account)
        let b = try await device("b", account: account)

        let rootA = a.repository.url(of: "Thesis")
        try write("one\ntwo\nthree\nfour\nfive\n", to: rootA.appendingPathComponent("main.typ"))
        try FileManager.default.createDirectory(at: rootA.appendingPathComponent("figures"), withIntermediateDirectories: true)
        // Binary, so an LFS file that travels as its own blob.
        try Data([0x25, 0x50, 0x44, 0x46, 0, 1, 2]).write(to: rootA.appendingPathComponent("figures/plot.pdf"))
        await commit(a)
        a.share(rootA)

        try await eventually("space listed on b") { !b.elsewhere.isEmpty }
        let share = b.elsewhere[0]
        let rootB = try XCTUnwrap(b.join(share, at: b.suggestedDestination(for: share)))
        XCTAssertEqual(rootB.lastPathComponent, "Thesis")
        try await eventually("files on b") {
            read(rootB.appendingPathComponent("main.typ")) == "one\ntwo\nthree\nfour\nfive\n"
                && (try? Data(contentsOf: rootB.appendingPathComponent("figures/plot.pdf"))) == Data([0x25, 0x50, 0x44, 0x46, 0, 1, 2])
        }

        // Edits on both devices at once merge line by line.
        try write("ONE\ntwo\nthree\nfour\nfive\n", to: rootA.appendingPathComponent("main.typ"))
        try write("one\ntwo\nthree\nfour\nFIVE\n", to: rootB.appendingPathComponent("main.typ"))
        await commit(a, b)
        let merged = "ONE\ntwo\nthree\nfour\nFIVE\n"
        try await eventually("merge on both") {
            read(rootA.appendingPathComponent("main.typ")) == merged && read(rootB.appendingPathComponent("main.typ")) == merged
        }

        // Deletions follow.
        try FileManager.default.removeItem(at: rootB.appendingPathComponent("figures/plot.pdf"))
        await commit(b)
        try await eventually("deletion on a") {
            !FileManager.default.fileExists(atPath: rootA.appendingPathComponent("figures/plot.pdf").path)
        }
        try await eventually("both synced") { a.status(for: rootA) == .synced && b.status(for: rootB) == .synced }
    }

    func testResolvesAConflictOnceForBothDevices() async throws {
        let (a, rootA, b, rootB) = try await sharedSpace("one\ntwo\n")
        try write("one (a)\ntwo\n", to: rootA.appendingPathComponent("main.typ"))
        try write("one (b)\ntwo\n", to: rootB.appendingPathComponent("main.typ"))
        await commit(a, b)
        try await eventually("conflict") { !a.repository.conflicted.isEmpty || !b.repository.conflicted.isEmpty }
        try await eventually("conflicts status") { a.status(for: rootA) == .conflicts || b.status(for: rootB) == .conflicts }

        let (resolver, root) = a.repository.conflicted.isEmpty ? (b, rootB) : (a, rootA)
        let found = await resolver.repository.conflict(at: root.appendingPathComponent("main.typ"))
        let conflict = try XCTUnwrap(found)
        XCTAssertEqual(conflict.sides.count, 2)
        let resolved = await resolver.repository.resolve(root.appendingPathComponent("main.typ"), text: "one (a and b)\ntwo\n")
        XCTAssertTrue(resolved)
        await commit(resolver)
        try await eventually("resolution on both") {
            read(rootA.appendingPathComponent("main.typ")) == "one (a and b)\ntwo\n"
                && read(rootB.appendingPathComponent("main.typ")) == "one (a and b)\ntwo\n"
                && a.repository.conflicted.isEmpty && b.repository.conflicted.isEmpty
        }
    }

    func testKeepsBothVersionsOfAnLFSFileChangedOnBoth() async throws {
        let (a, rootA, b, rootB) = try await sharedSpace("x\n")
        try Data([0, 1, 2, 3]).write(to: rootA.appendingPathComponent("image.png"))
        await commit(a)
        try await eventually("image on b") { FileManager.default.fileExists(atPath: rootB.appendingPathComponent("image.png").path) }

        try Data([0, 0xA]).write(to: rootA.appendingPathComponent("image.png"))
        try Data([0, 0xB]).write(to: rootB.appendingPathComponent("image.png"))
        // b's change is the newer one.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: rootB.appendingPathComponent("image.png").path)
        await commit(a, b)
        try await eventually("newest wins, the other is kept") {
            [rootA, rootB].allSatisfy { root in
                (try? Data(contentsOf: root.appendingPathComponent("image.png"))) == Data([0, 0xB])
                    && (try? Data(contentsOf: root.appendingPathComponent("image (conflict).png"))) == Data([0, 0xA])
            }
        }
    }

    func testSharesAFileWithAnotherAccountAtItsOwnPlace() async throws {
        let a = try await device("a", account: account())
        let b = try await device("b", account: account())
        let file = a.repository.url(of: "Notes/todo.typ")
        try write("- milk\n", to: file)
        await commit(a)
        a.share(file)
        let link = try XCTUnwrap(a.inviteLink(for: file))
        let invite = try XCTUnwrap(parseInvite(link: link))
        XCTAssertTrue(invite.file)
        XCTAssertEqual(invite.name, "todo.typ")
        XCTAssertTrue(b.elsewhere.isEmpty)

        let destination = b.repository.url(of: "Inbox/shopping.typ")
        XCTAssertNotNil(b.join(invite, at: destination))
        try await eventually("file on b") { read(destination) == "- milk\n" }

        try write("- milk\n- eggs\n", to: destination)
        await commit(b)
        try await eventually("edit on a") { read(file) == "- milk\n- eggs\n" }
        // Nothing else of a's space travels.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.repository.url(of: "Inbox").path), ["shopping.typ"])
        try await eventually("shared on both") { a.isShared(file) && b.isShared(destination) }
    }

    func testDeviceSyncCanBeUnlinkedWhileSharingContinues() async throws {
        let (a, rootA, b, rootB) = try await sharedSpace("initial\n")
        let guest = try await device("guest", account: account())
        let link = try XCTUnwrap(a.inviteLink(for: rootA))
        let invite = try XCTUnwrap(parseInvite(link: link))
        let rootGuest = guest.repository.url(of: "Shared")
        XCTAssertNotNil(guest.join(invite, at: rootGuest))
        try await eventually("guest joined") { read(rootGuest.appendingPathComponent("main.typ")) == "initial\n" }

        let unlinked = await a.configure(rootA, devices: false, shared: true)
        XCTAssertTrue(unlinked)
        try await eventually("device sync unlinked") { !a.isSynced(rootA) && !b.isSynced(rootB) && !b.isShared(rootB) }
        XCTAssertTrue(a.isShared(rootA))
        try write("still shared\n", to: rootA.appendingPathComponent("main.typ"))
        await commit(a)
        try await eventually("guest still receives edits") { read(rootGuest.appendingPathComponent("main.typ")) == "still shared\n" }
        XCTAssertEqual(read(rootB.appendingPathComponent("main.typ")), "initial\n")

        let linked = await a.configure(rootA, devices: true, shared: true)
        XCTAssertTrue(linked)
        try await eventually("own device rejoins") { b.isSynced(rootB) && read(rootB.appendingPathComponent("main.typ")) == "still shared\n" }
    }

    func testRevokingALinkDisconnectsParticipantsAndKeepsDeviceSync() async throws {
        let (a, rootA, b, rootB) = try await sharedSpace("before revocation\n")
        let guest = try await device("guest", account: account())
        let invite = try XCTUnwrap(parseInvite(link: try XCTUnwrap(a.inviteLink(for: rootA))))
        let rootGuest = guest.repository.url(of: "Shared")
        XCTAssertNotNil(guest.join(invite, at: rootGuest))
        try await eventually("guest joined") { read(rootGuest.appendingPathComponent("main.typ")) == "before revocation\n" }

        let revoked = await a.configure(rootA, devices: true, shared: false)
        XCTAssertTrue(revoked)
        try await eventually("revoked on own devices") { !a.isShared(rootA) && !b.isShared(rootB) }
        XCTAssertTrue(a.isSynced(rootA))
        XCTAssertTrue(b.isSynced(rootB))
        try write("after revocation\n", to: rootA.appendingPathComponent("main.typ"))
        await commit(a)
        try await eventually("private edits reach own device") { read(rootB.appendingPathComponent("main.typ")) == "after revocation\n" }
        XCTAssertEqual(read(rootGuest.appendingPathComponent("main.typ")), "before revocation\n")
        try write("revoked guest edit\n", to: rootGuest.appendingPathComponent("main.typ"))
        await commit(guest)

        try await eventually("revoked guest has published locally") { guest.status(for: rootGuest) != .syncing }
        XCTAssertEqual(read(rootA.appendingPathComponent("main.typ")), "after revocation\n")
        let replacement = try XCTUnwrap(parseInvite(link: try XCTUnwrap(a.inviteLink(for: rootA))))
        XCTAssertNotEqual(replacement.secret, invite.secret)
        XCTAssertFalse(a.accountShare(for: rootA)?.joined ?? true)
        XCTAssertNotNil(guest.join(replacement, at: rootGuest))
        try await eventually("replacement link reopens sharing") { guest.accountShare(for: rootGuest)?.shared == true && !guest.repository.conflicted.isEmpty }
        let merged = read(rootGuest.appendingPathComponent("main.typ")) ?? ""
        XCTAssertTrue(merged.contains("after revocation"))
        XCTAssertTrue(merged.contains("revoked guest edit"))
    }

    func testRevocationSurvivesDeletingAndRestoringTheLastOwnerCopy() async throws {
        let a = try await device("a", account: account())
        let guest = try await device("guest", account: account())
        let rootA = a.repository.url(of: "Notes")
        try write("original\n", to: rootA.appendingPathComponent("main.typ"))
        await commit(a)
        XCTAssertNotNil(a.share(rootA))
        let invite = try XCTUnwrap(parseInvite(link: try XCTUnwrap(a.inviteLink(for: rootA))))
        let rootGuest = guest.repository.url(of: "Shared")
        XCTAssertNotNil(guest.join(invite, at: rootGuest))
        try await eventually("guest joined") { read(rootGuest.appendingPathComponent("main.typ")) == "original\n" }
        let revoked = await a.configure(rootA, devices: true, shared: false)
        XCTAssertTrue(revoked)
        let deletion = await a.repository.delete([rootA], message: "Delete Notes")
        let item = try XCTUnwrap(deletion?.first)
        try await eventually("last owner leaves") { a.accountShares.isEmpty }
        let restored = await a.repository.restore(item, to: rootA)
        XCTAssertEqual(restored, .restored)
        try await eventually("owner resumes privately") { a.accountShare(for: rootA) != nil && a.isSynced(rootA) }
        XCTAssertFalse(a.accountShare(for: rootA)?.joined ?? true)
        XCTAssertFalse(a.isShared(rootA))
        try write("restored privately\n", to: rootA.appendingPathComponent("main.typ"))
        await commit(a)
        try await eventually("private edit published") { a.status(for: rootA) != .syncing }
        XCTAssertEqual(read(rootGuest.appendingPathComponent("main.typ")), "original\n")
        let replacement = try XCTUnwrap(parseInvite(link: try XCTUnwrap(a.inviteLink(for: rootA))))
        XCTAssertNotEqual(replacement.secret, invite.secret)
    }

    func testRelinksADeviceShareToAnExistingSpaceAndMerges() async throws {
        let (a, rootA, b, rootB) = try await sharedSpace("common\n")
        let id = try XCTUnwrap(b.shareID(for: rootB))
        b.stopSyncing(rootB)
        try await eventually("space can be linked again") { b.elsewhere.contains { $0.id == id } }
        try write("remote file\n", to: rootA.appendingPathComponent("remote.typ"))
        try write("local file\n", to: rootB.appendingPathComponent("local.typ"))
        await commit(a, b)
        let share = try XCTUnwrap(b.elsewhere.first { $0.id == id })
        XCTAssertNotNil(b.join(share, at: rootB, merge: true))
        try await eventually("both sets of files merge") {
            read(rootA.appendingPathComponent("local.typ")) == "local file\n" && read(rootB.appendingPathComponent("remote.typ")) == "remote file\n"
        }
        XCTAssertEqual(read(rootA.appendingPathComponent("main.typ")), "common\n")
        XCTAssertEqual(read(rootB.appendingPathComponent("main.typ")), "common\n")
    }

    /// An editor's side of a live session, as `LiveEditing` does it.
    @MainActor private final class Editor {
        let service: SyncService
        let root: URL
        var text: String
        var selection = NSRange(location: 0, length: 0)
        var cursors: [LiveResult.Cursor] = []

        init(_ service: SyncService, _ root: URL, _ text: String) {
            self.service = service
            self.root = root
            self.text = text
            service.liveOpen(root: root, path: "main.typ", text: text)
        }

        func sync() {
            guard let result = service.liveSync(root: root, path: "main.typ", text: text, selection: selection) else { return }
            if let adopted = result.adopted {
                let merged = merge3(base: adopted.base, local: text, remote: adopted.theirs)
                text = merged.conflicts == 0 ? merged.text : adopted.theirs
                return sync()
            }
            let buffer = NSMutableString(string: text)
            for edit in result.edits {
                buffer.replaceCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.text)
            }
            text = buffer as String
            cursors = result.cursors
        }

        func save() throws { try text.write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8) }
    }

    func testEditsLiveWithCursorsWhileNodesSync() async throws {
        let (a, rootA, b, rootB) = try await sharedSpace("hello\n")
        XCTAssertTrue(a.canEditLive(root: rootA, path: "main.typ"))
        let editorA = Editor(a, rootA, "hello\n")
        let editorB = Editor(b, rootB, "hello\n")
        try await eventually("sessions meet") {
            editorA.sync()
            editorB.sync()
            return !editorA.cursors.isEmpty && !editorB.cursors.isEmpty
        }

        editorA.text = "hello world\n"
        editorA.selection = NSRange(location: 11, length: 0)
        let start = Date()
        editorA.sync()
        try await eventually("edit on b", timeout: 10) {
            editorB.sync()
            return editorB.text == "hello world\n" && editorB.cursors.first?.location == 11
        }
        print("live edit arrived after \(Int(Date().timeIntervalSince(start) * 1000)) ms")

        // Typing at once on both sides merges without losing either.
        editorA.text = "Oh, hello world\n"
        editorB.text = "hello world!\n"
        editorA.sync()
        editorB.sync()
        try await eventually("both edits on both", timeout: 10) {
            editorA.sync()
            editorB.sync()
            return editorA.text == "Oh, hello world!\n" && editorB.text == editorA.text
        }

        // Saving and committing on both while live: node merges leave the open file alone and settle.
        editorA.text = "Oh, hello world! A\n"
        editorA.sync()
        try editorA.save()
        await commit(a)
        try await eventually("typed text on b", timeout: 10) {
            editorB.sync()
            return editorB.text == "Oh, hello world! A\n"
        }
        try editorB.save()
        await commit(b)
        try await eventually("nodes settle without conflicts") {
            editorA.sync()
            editorB.sync()
            return a.status(for: rootA) == .synced && b.status(for: rootB) == .synced
                && a.repository.conflicted.isEmpty && b.repository.conflicted.isEmpty
        }
        XCTAssertEqual(read(rootB.appendingPathComponent("main.typ")), "Oh, hello world! A\n")
        XCTAssertEqual(editorA.text, editorB.text)
    }

    func testKeepsSyncingAFolderRenamedDeletedAndRestored() async throws {
        let account = account()
        let a = try await device("a", account: account)
        let b = try await device("b", account: account)
        let chaptersA = a.repository.url(of: "Thesis/chapters")
        try write("one\n", to: chaptersA.appendingPathComponent("one.typ"))
        try write("two\n", to: chaptersA.appendingPathComponent("two.typ"))
        await commit(a)
        XCTAssertNotNil(a.share(chaptersA))
        try await eventually("folder listed on b") { !b.elsewhere.isEmpty }
        let share = b.elsewhere[0]
        XCTAssertEqual(share.kind, .folder)
        let rootB = try XCTUnwrap(b.join(share, at: b.repository.url(of: "Chapters")))
        try await eventually("files on b") { read(rootB.appendingPathComponent("one.typ")) == "one\n" }

        // A renames the shared folder, as the file tree does, and keeps editing: b keeps getting the edits.
        let partsA = a.repository.url(of: "Thesis/parts")
        try FileManager.default.moveItem(at: chaptersA, to: partsA)
        a.repository.noteMoved(from: chaptersA, to: partsA)
        await a.repository.commit("Rename Thesis/chapters to Thesis/parts")
        XCTAssertEqual(a.shares.values.first?.path, "Thesis/parts")
        try write("one, renamed\n", to: partsA.appendingPathComponent("one.typ"))
        await commit(a)
        try await eventually("edit after the rename on b") { read(rootB.appendingPathComponent("one.typ")) == "one, renamed\n" }
        XCTAssertNil(a.problems.values.first, "the share didn't lose its folder")

        // Undoing a file deletion (a restore) publishes like any commit.
        let deletedFile = await a.repository.delete([partsA.appendingPathComponent("two.typ")], message: "Delete Thesis/parts/two.typ")
        let deleted = try XCTUnwrap(deletedFile)
        try await eventually("deletion on b") { !FileManager.default.fileExists(atPath: rootB.appendingPathComponent("two.typ").path) }
        let restoredFile = await a.repository.restore(deleted[0], to: partsA.appendingPathComponent("two.typ"))
        XCTAssertEqual(restoredFile, .restored)
        try await eventually("undone deletion on b") { read(rootB.appendingPathComponent("two.typ")) == "two\n" }

        // Deleting the shared folder stops it on a only; b keeps it, and restoring it on a syncs again.
        let deletedFolder = await a.repository.delete([partsA], message: "Delete Thesis/parts")
        let folder = try XCTUnwrap(deletedFolder)
        XCTAssertTrue(a.shares.isEmpty)
        XCTAssertEqual(a.parked.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootB.appendingPathComponent("one.typ").path), "b keeps its files")
        let restoredFolder = await a.repository.restore(folder[0], to: partsA)
        XCTAssertEqual(restoredFolder, .restored)
        XCTAssertEqual(a.shares.values.first?.path, "Thesis/parts")
        try write("one, from b\n", to: rootB.appendingPathComponent("one.typ"))
        await commit(b)
        try await eventually("b's edit on a after the restore") { read(partsA.appendingPathComponent("one.typ")) == "one, from b\n" }
    }

    func testSharesNobodySyncsLeaveTheAccount() async throws {
        let (a, rootA, b, rootB) = try await sharedSpace("x\n")
        b.stopSyncing(rootB)
        // A still syncs it, so b can join again.
        try await eventually("listed on b") { b.elsewhere.count == 1 }
        a.stopSyncing(rootA)
        try await eventually("gone on b") { b.elsewhere.isEmpty }
        // a hears of b leaving through the account replica, maybe after b does.
        try await eventually("gone on a") { a.elsewhere.isEmpty }
    }
}
