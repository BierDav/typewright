import XCTest
@testable import Typewright

final class DiagnosticTests: XCTestCase {
    func testParsesShortFormat() {
        let out = """
        main.typ:2:3: error: cannot access fields on type integer
        @preview/icons:0.1.0/index.typ:8:21: warning: no whitespace before raw text
        garbage line
        """
        let d = Diagnostic.parse(out)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].path, "main.typ")
        XCTAssertEqual(d[0].line, 2)
        XCTAssertEqual(d[0].column, 3)
        XCTAssertEqual(d[0].severity, .error)
        XCTAssertFalse(d[0].isFromPackage)
        XCTAssertTrue(d[1].isFromPackage)
        XCTAssertEqual(d[1].severity, .warning)
    }

    func testPicksNewestPatchPerMinor() {
        func r(_ tag: String, pre: Bool = false) -> CompilerManager.GitHubRelease {
            .init(tag_name: tag, prerelease: pre,
                  assets: [.init(name: CompilerManager.assetName, browser_download_url: URL(string: "https://x/\(tag)")!)])
        }
        let picked = CompilerManager.pickReleases(from: [
            r("v0.15.0-rc.1", pre: true), r("v0.15.1"), r("v0.15.0"), r("v0.14.2"), r("v0.14.10"), r("v0.10.0"),
        ])
        XCTAssertEqual(picked.map(\.version), ["0.15.1", "0.14.10"])
    }
}
