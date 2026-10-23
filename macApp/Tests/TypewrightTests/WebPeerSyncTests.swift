import IrohBridge
import TypewrightCore
import XCTest
@testable import Typewright

/// This Mac against the web app in a browser, over the real n0 relays. Skipped unless
/// `TEST_RUNNER_TYPEWRIGHT_WEB_PEER_DIR` names a folder that a browser driver watches too: this side writes the
/// account (`account.hex`), an invite (`invite.txt`) and `mac-<step>` marks; the browser answers with `web-<step>`
/// marks and its own edits, signed in through its stored identity with the same account.
@MainActor
final class WebPeerSyncTests: XCTestCase {
    private var dir: URL!
    private var talk: URL!
    private var service: SyncService?

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["TYPEWRIGHT_WEB_PEER_DIR"]
        try XCTSkipUnless(path != nil, "needs a browser peer")
        talk = URL(fileURLWithPath: path!, isDirectory: true)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("webpeer-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        service?.stop()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func signal(_ step: String) throws {
        try Data().write(to: talk.appendingPathComponent("mac-\(step)"))
        print("mac: \(step)")
    }

    private func eventually(_ what: String, timeout: Double = 180, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func browser(_ step: String) async throws {
        let mark = talk.appendingPathComponent("web-\(step)")
        try await eventually("browser step \(step)", timeout: 300) { FileManager.default.fileExists(atPath: mark.path) }
    }

    func testSyncsWithTheWebApp() async throws {
        let account = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let repository = SpaceRepository(root: dir.appendingPathComponent("library", isDirectory: true))
        let mac = SyncService(defaults: UserDefaults(suiteName: "typewright-test-\(UUID().uuidString)")!,
                              repository: repository, deviceName: "MAC")
        service = mac
        let started = await mac.start(account: account, in: dir.appendingPathComponent("data"))
        XCTAssertTrue(started)

        // 1. A space with a text file and an LFS file, downloaded by the browser.
        let root = repository.url(of: "Thesis")
        let main = root.appendingPathComponent("main.typ")
        try write("one\ntwo\nthree\nfour\nfive\n", to: main)
        try Data([0x25, 0x50, 0x44, 0x46, 0, 1, 2]).write(to: root.appendingPathComponent("figures/plot.pdf").creatingFolder())
        await repository.commit()
        XCTAssertNotNil(mac.share(root))
        try account.map { String(format: "%02x", $0) }.joined().write(to: talk.appendingPathComponent("account.hex"), atomically: true, encoding: .utf8)
        try signal("1")
        try await browser("1")

        // 2. Edits on both sides merge line by line (the browser changes the first line).
        try write("one\ntwo\nthree\nfour\nFIVE\n", to: main)
        await repository.commit()
        try signal("2")
        try await eventually("merged on the Mac") { read(main) == "ONE\ntwo\nthree\nfour\nFIVE\n" }
        try await browser("2")
        try await eventually("synced before the browser goes offline") { mac.status(for: root) == .synced }
        try signal("2-merged")

        // 3. A conflict, made while the browser is offline, resolved in the browser.
        try await browser("3-offline")
        try write("ONE (mac)\ntwo\nthree\nfour\nFIVE\n", to: main)
        await repository.commit()
        try signal("3")
        try await eventually("conflict on the Mac") { !repository.conflicted.isEmpty || read(main) == "ONE (both)\ntwo\nthree\nfour\nFIVE\n" }
        try await eventually("the browser's resolution on the Mac") {
            read(main) == "ONE (both)\ntwo\nthree\nfour\nFIVE\n" && repository.conflicted.isEmpty
        }
        try await browser("3")

        // 4. LFS files both ways.
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3]).write(to: root.appendingPathComponent("image.png"))
        await repository.commit()
        try signal("4")
        try await eventually("the browser's LFS file on the Mac") {
            (try? Data(contentsOf: root.appendingPathComponent("figures/web.png"))) == Data([0x89, 0x50, 0x4E, 0x47, 0, 9, 9, 9])
        }
        try await browser("4")

        // 5. A file share, joined in the browser under another name and place.
        let todo = repository.url(of: "Notes/todo.typ")
        try write("- milk\n", to: todo)
        await repository.commit()
        XCTAssertNotNil(mac.share(todo))
        let link = try XCTUnwrap(mac.inviteLink(for: todo))
        try link.write(to: talk.appendingPathComponent("invite.txt"), atomically: true, encoding: .utf8)
        try signal("5")
        try await eventually("the browser's edit of the shared file") { read(todo) == "- milk\n- eggs\n" }
        try await browser("5")

        // 6. Live editing of the open file, with cursors, both ways.
        var text = read(main) ?? ""
        var cursors: [LiveResult.Cursor] = []
        var selection = NSRange(location: 0, length: 0)
        mac.liveOpen(root: root, path: "main.typ", text: text)
        func live() {
            guard let result = mac.liveSync(root: root, path: "main.typ", text: text, selection: selection) else { return }
            if let adopted = result.adopted {
                let merged = merge3(base: adopted.base, local: text, remote: adopted.theirs)
                text = merged.conflicts == 0 ? merged.text : adopted.theirs
                return live()
            }
            let buffer = NSMutableString(string: text)
            for edit in result.edits { buffer.replaceCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.text) }
            text = buffer as String
            cursors = result.cursors
        }
        try signal("6-open")
        try await eventually("live sessions meet", timeout: 120) { live(); return !cursors.isEmpty }
        text = text.replacingOccurrences(of: "two\n", with: "two (live from mac)\n")
        selection = NSRange(location: 4, length: 0)
        live()
        try signal("6")
        try await eventually("the browser's live edit on the Mac", timeout: 60) { live(); return text.contains("three (live from web)") }
        XCTAssertTrue(text.contains("two (live from mac)"))
        try await browser("6")
        try text.write(to: main, atomically: true, encoding: .utf8)
        await repository.commit()
        try await eventually("settled") {
            live()
            return mac.status(for: root) == .synced && repository.conflicted.isEmpty
        }
        try signal("done")
        try await browser("done")
    }
}

private extension URL {
    /// The URL, with its folder made.
    func creatingFolder() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
