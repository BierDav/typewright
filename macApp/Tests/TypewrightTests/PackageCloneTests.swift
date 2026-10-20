import XCTest
@testable import Typewright

@MainActor
final class PackageCloneTests: XCTestCase {
    func testClonedRepositoryBecomesAVersionedPackage() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("tw-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "[package]\nname = \"demo\"\nversion = \"0.1.0\"\nentrypoint = \"lib.typ\"\n"
            .write(to: repo.appendingPathComponent("typst.toml"), atomically: true, encoding: .utf8)
        try "#let hi = [Hi]".write(to: repo.appendingPathComponent("lib.typ"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }

        let library = PackageLibrary.shared
        let namespace = "twtest\(Int.random(in: 1000...9999))"
        defer { try? FileManager.default.removeItem(at: library.dataDirectory.appending(path: namespace)) }
        let cloned = await library.clone("file://\(repo.path)", into: namespace)
        XCTAssertTrue(cloned, library.linkError ?? "")
        let package = try XCTUnwrap(library.namespaces.first { $0.name == namespace }?.packages.first)
        XCTAssertEqual(package.spec, "@\(namespace)/demo:0.1.0")
        XCTAssertTrue(package.isCloned)
        let again = await library.clone("file://\(repo.path)", into: namespace)
        XCTAssertFalse(again, "the same version isn't installed twice")
    }
}
