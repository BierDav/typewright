import XCTest
@testable import Typewright

@MainActor
final class PackageLibraryTests: XCTestCase {
    func testFindsOutdatedUniversePackages() {
        let text = """
        #import "@preview/foo:1.0.0"
        #import "@preview/bar:2.0.0"
        #import "@local/lib:1.0.0"
        """
        let latest = ["foo": "1.2.0", "bar": "2.0.0"]
        let upgrades = PackageLibrary.upgrades(in: text) { latest[$0] }
        XCTAssertEqual(upgrades.map(\.spec), ["@preview/foo:1.0.0"])
        XCTAssertEqual(upgrades.first?.latest, "1.2.0")
        XCTAssertEqual(upgrades.first?.updatedSpec, "@preview/foo:1.2.0")
        XCTAssertEqual((text as NSString).substring(with: upgrades[0].range), "@preview/foo:1.0.0")
    }

    func testCompletionLabelsNamePackageSpecs() {
        XCTAssertEqual(PackageLibrary.spec(in: "\"@preview/cetz:0.3.1\""), "@preview/cetz:0.3.1")
        XCTAssertEqual(PackageLibrary.spec(in: "@preview/cetz:0.3.1"), "@preview/cetz:0.3.1")
        XCTAssertNil(PackageLibrary.spec(in: "grid"))
        XCTAssertNil(PackageLibrary.spec(in: "\"local\""))
    }

    func testManifestFeedsDocsWhenTheRegistryIsOffline() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tw-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        [package]
        name = "demo"
        version = "0.1.0"
        description = "A small demo"
        authors = ["A <a@example.com>", "B"]
        license = "MIT"
        repository = "https://example.com/demo"

        [template]
        path = "template"
        """.write(to: folder.appendingPathComponent("typst.toml"), atomically: true, encoding: .utf8)

        let manifest = try XCTUnwrap(PackageLibrary.manifest(at: folder))
        XCTAssertEqual(manifest.name, "demo")
        XCTAssertEqual(manifest.version, "0.1.0")
        XCTAssertEqual(manifest.description, "A small demo")
        XCTAssertEqual(manifest.authors, ["A <a@example.com>", "B"])
        XCTAssertEqual(manifest.license, "MIT")
        XCTAssertEqual(manifest.repository, "https://example.com/demo")
    }

    func testDocsComeFromTheInstalledPackage() throws {
        let library = PackageLibrary.shared
        let namespace = "twdocs\(Int.random(in: 1000...9999))"
        let folder = library.dataDirectory.appending(path: "\(namespace)/demo/0.1.0", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: library.dataDirectory.appending(path: namespace))
            library.refresh()
        }
        try """
        [package]
        name = "demo"
        version = "0.1.0"
        description = "A small demo"
        authors = ["A <a@example.com>"]
        """.write(to: folder.appendingPathComponent("typst.toml"), atomically: true, encoding: .utf8)
        library.refresh()

        let docs = try XCTUnwrap(library.documentation(for: "@\(namespace)/demo:0.1.0"))
        XCTAssertTrue(docs.contains("**Package:** `@\(namespace)/demo:0.1.0`"), docs)
        XCTAssertTrue(docs.contains("**Description:** A small demo"), docs)
        XCTAssertTrue(docs.contains("**Authors:** A <a@example.com>"), docs)
        XCTAssertEqual(library.latestVersion(namespace: namespace, name: "demo"), "0.1.0")
    }

    func testVersionsSortNumerically() {
        XCTAssertEqual("0.10.0".compare("0.9.0", options: .numeric), .orderedDescending)
    }
}
