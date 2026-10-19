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
        XCTAssertEqual(SyncPolicy.shared.mode(isText: pdf.isText, size: pdf.size, lfsThreshold: 1_000_000), .lfs)
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
}
