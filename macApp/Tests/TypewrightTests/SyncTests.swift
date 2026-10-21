import IrohBridge
import TypewrightCore
import XCTest
@testable import Typewright

final class SyncTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("chapters/.git"), withIntermediateDirectories: true)
        try "build/\n*.pdf\n!keep.pdf\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "= Hi".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("build/out.typ"), atomically: true, encoding: .utf8)
        try "%PDF".write(to: root.appendingPathComponent("draft.pdf"), atomically: true, encoding: .utf8)
        try "%PDF".write(to: root.appendingPathComponent("keep.pdf"), atomically: true, encoding: .utf8)
        try "ref".write(to: root.appendingPathComponent("chapters/.git/HEAD"), atomically: true, encoding: .utf8)
        try "intro".write(to: root.appendingPathComponent("chapters/intro.typ"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScanFollowsGitignoreAndMarksBinariesForLFS() {
        let result = FolderScanner().scan(root)
        XCTAssertEqual(Set(result.files.keys), [".gitignore", "main.typ", "keep.pdf", "chapters/intro.typ"])
        XCTAssertEqual(result.files["main.typ"]?.isText, true)
        let pdf = result.files["keep.pdf"]!
        XCTAssertFalse(pdf.isText)
        XCTAssertEqual(syncMode(isText: pdf.isText, size: pdf.size, lfsThreshold: 1_000_000), .lfs)
        XCTAssertTrue(result.ignore.isIgnored(path: "build/new.typ", isDir: false))
    }

    func testHashesMatchBlobHashes() throws {
        try Data().write(to: root.appendingPathComponent("empty.typ"))
        // BLAKE3 of nothing, which iroh-blobs also uses as the empty blob's hash.
        XCTAssertEqual(FolderScanner().file(root, path: "empty.typ")?.hash,
                       "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
        XCTAssertNil(FolderScanner().file(root, path: "missing.typ"))
    }
}

/// Two devices of one account in this process, over the real n0 relays.
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
        let suite = "typewright-test-\(UUID().uuidString)"
        let service = SyncService(defaults: UserDefaults(suiteName: suite)!)
        let ok = await service.start(account: account, in: dir.appendingPathComponent("\(name)-data"))
        XCTAssertTrue(ok)
        devices.append(service)
        return service
    }

    private func eventually(_ what: String, timeout: Double = 120, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func testSyncsAFolderBetweenTwoDevices() async throws {
        let account = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let a = try await device("a", account: account)
        let b = try await device("b", account: account)

        let rootA = dir.appendingPathComponent("A/Thesis", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA.appendingPathComponent("figures"), withIntermediateDirectories: true)
        try "out/\n".write(to: rootA.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "one\ntwo\nthree\nfour\nfive\n".write(to: rootA.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        try Data([0x25, 0x50, 0x44, 0x46, 0, 1, 2]).write(to: rootA.appendingPathComponent("figures/plot.pdf"))
        try FileManager.default.createDirectory(at: rootA.appendingPathComponent("out"), withIntermediateDirectories: true)
        try "ignored".write(to: rootA.appendingPathComponent("out/build.typ"), atomically: true, encoding: .utf8)
        a.share(rootA)

        try await eventually("space listed on b") { !b.elsewhere.isEmpty }
        let parentB = dir.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: parentB, withIntermediateDirectories: true)
        let rootB = try XCTUnwrap(b.join(b.elsewhere[0], in: parentB))
        XCTAssertEqual(rootB.lastPathComponent, "Thesis")

        try await eventually("files on b") {
            read(rootB.appendingPathComponent("main.typ")) == "one\ntwo\nthree\nfour\nfive\n"
                && FileManager.default.fileExists(atPath: rootB.appendingPathComponent("figures/plot.pdf").path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootB.appendingPathComponent("out").path))

        // Edits on both devices at once merge line by line.
        try "ONE\ntwo\nthree\nfour\nfive\n".write(to: rootA.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        try "one\ntwo\nthree\nfour\nFIVE\n".write(to: rootB.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        let merged = "ONE\ntwo\nthree\nfour\nFIVE\n"
        try await eventually("merge on both") {
            read(rootA.appendingPathComponent("main.typ")) == merged && read(rootB.appendingPathComponent("main.typ")) == merged
        }

        // Deletions follow.
        try FileManager.default.removeItem(at: rootB.appendingPathComponent("figures/plot.pdf"))
        try await eventually("deletion on a") {
            !FileManager.default.fileExists(atPath: rootA.appendingPathComponent("figures/plot.pdf").path)
        }
    }

    /// Shares a one-file space from a new device `a` and joins it on `b`.
    private func sharedSpace(_ text: String) async throws -> (SyncService, URL, SyncService, URL) {
        let account = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let a = try await device("a", account: account)
        let b = try await device("b", account: account)
        let rootA = dir.appendingPathComponent("A/Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try text.write(to: rootA.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        a.share(rootA)
        try await eventually("space listed on b") { !b.elsewhere.isEmpty }
        let parentB = dir.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: parentB, withIntermediateDirectories: true)
        let rootB = try XCTUnwrap(b.join(b.elsewhere[0], in: parentB))
        try await eventually("file on b") { read(rootB.appendingPathComponent("main.typ")) == text }
        return (a, rootA, b, rootB)
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
    }

    func testEditsLiveWithCursors() async throws {
        let (a, rootA, b, rootB) = try await sharedSpace("hello\n")
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
    }

    func testSharesASpaceWithAnotherAccountByLink() async throws {
        let a = try await device("a", account: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        let b = try await device("b", account: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        let rootA = dir.appendingPathComponent("A/Paper", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try "= Draft\n".write(to: rootA.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        a.share(rootA)

        let link = try XCTUnwrap(a.inviteLink(for: rootA))
        let invite = try XCTUnwrap(parseInvite(link: link))
        XCTAssertEqual(invite.name, "Paper")
        XCTAssertTrue(b.elsewhere.isEmpty)
        let parentB = dir.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: parentB, withIntermediateDirectories: true)
        let rootB = try XCTUnwrap(b.join(invite, in: parentB))
        XCTAssertEqual(rootB.lastPathComponent, "Paper")

        try await eventually("file on b") { read(rootB.appendingPathComponent("main.typ")) == "= Draft\n" }
        try "notes".write(to: rootB.appendingPathComponent("notes.typ"), atomically: true, encoding: .utf8)
        try await eventually("file from b on a") { read(rootA.appendingPathComponent("notes.typ")) == "notes" }
        try await eventually("shared on both") { a.isShared(rootA) && b.isShared(rootB) }

        // Leaving only stops b; a keeps syncing.
        b.stopSyncing(rootB)
        XCTAssertTrue(a.isSynced(rootA))
    }

    func testSpacesNobodySyncsLeaveTheAccount() async throws {
        let (a, rootA, b, rootB) = try await sharedSpace("x\n")
        b.stopSyncing(rootB)
        // A still syncs it, so b can join again.
        try await eventually("listed on b") { b.elsewhere.count == 1 }
        a.stopSyncing(rootA)
        try await eventually("gone on b") { b.elsewhere.isEmpty }
        XCTAssertTrue(a.elsewhere.isEmpty)
    }
}
