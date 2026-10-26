import AppKit
import TypstBridge
import WebKit
import XCTest
@testable import Typewright

@MainActor
final class CLITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "#include \"/heading.typ\"".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        try "= Hello from the CLI".write(to: root.appendingPathComponent("heading.typ"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func run(_ args: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = Bundle.main.executableURL!
        process.arguments = ["--cli"] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }

    func testHeadlessHelpAndVersion() throws {
        let help = try run(["compile", "--help"])
        XCTAssertEqual(help.0, 0, help.2)
        XCTAssertTrue(help.1.contains("--dark"))
        let version = try run(["--version"])
        XCTAssertEqual(version.0, 0, version.2)
        XCTAssertTrue(version.1.contains(String(cString: tw_version())))
    }

    func testPDFHTMLAndDiagnosticsThroughTheAppExecutable() throws {
        let main = root.appendingPathComponent("main.typ").path
        for format in ["pdf", "html"] {
            let output = root.appendingPathComponent("output.\(format)")
            let result = try run(["compile", main, output.path, "--json"])
            XCTAssertEqual(result.0, 0, result.1 + result.2)
            let data = try Data(contentsOf: output)
            if format == "pdf" {
                XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
            } else {
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Hello from the CLI"))
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("twimage:"))
            }
            let check = try run(["check", main, "--format", format, "--json"])
            XCTAssertEqual(check.0, 0, check.1 + check.2)
        }
        try "#notDefined".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        let failed = try run(["check", main, "--json"])
        XCTAssertEqual(failed.0, 1)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(failed.1.utf8)) as? [String: Any])
        XCTAssertEqual(report["success"] as? Bool, false)
        XCTAssertEqual((report["diagnostics"] as? [[String: Any]])?.first?["path"] as? String, "main.typ")
    }

    func testSpaceRootInferenceAndInvalidUsage() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".jj/typewright"), withIntermediateDirectories: true)
        let space = root.appendingPathComponent("My Space", isDirectory: true)
        try FileManager.default.createDirectory(at: space.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        let main = space.appendingPathComponent("chapters/document.typ")
        try "Hello".write(to: main, atomically: true, encoding: .utf8)
        let info = try run(["info", main.path, "--json"])
        XCTAssertEqual(info.0, 0, info.2)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(info.1.utf8)) as? [String: Any])
        XCTAssertEqual(report["root"] as? String, space.resolvingSymlinksInPath().path)
        XCTAssertEqual(report["source"] as? String, "disk")
        XCTAssertEqual(try run(["check", main.path, "--root", space.appendingPathComponent("chapters/other").path]).0, 2)
        XCTAssertEqual(try run(["compile", main.path, main.path]).0, 2)
        XCTAssertEqual(try run(["check", main.path, "--dark"]).0, 2)
    }

    func testHTMLExpandsLargePreviewImages() throws {
        let payload = Data(repeating: 42, count: 150_000)
        let source = "<img src=\"data:image/png;base64,\(payload.base64EncodedString())\">"
        let images = tw_preview_images_new()
        defer { tw_preview_images_free(images) }
        let bytes = Data(source.utf8)
        var count = 0
        let rewritten = bytes.withUnsafeBytes {
            tw_preview_images_rewrite(images, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count, &count)
        }
        defer { tw_bytes_free(rewritten, count) }
        let preview = String(decoding: Data(bytes: rewritten, count: count), as: UTF8.self)
        XCTAssertTrue(preview.contains("twimage:"))
        let exported = try HTMLExport.document(preview, root: root, fontDirectories: [], dark: false)
        XCTAssertTrue(exported.contains(payload.base64EncodedString()))
        XCTAssertFalse(exported.contains("twimage:"))
    }

    func testExportedCustomFontsLoadWithoutThePreviewFontHandler() async throws {
        let systemFont = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Georgia.ttf")
        guard FileManager.default.fileExists(atPath: systemFont.path) else { throw XCTSkip("Georgia is not installed") }
        try FileManager.default.copyItem(at: systemFont, to: root.appendingPathComponent("custom.ttf"))
        let source = "<!doctype html><html><head></head><body style='font-family:Georgia'>Hello</body></html>"
        let html = try HTMLExport.document(source, root: root, fontDirectories: [root], dark: false)
        XCTAssertTrue(html.contains("data:application/octet-stream;base64,"))
        let web = WKWebView()
        web.loadHTMLString(html, baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("[...document.fonts].some(f => f.family === 'Georgia' && f.status === 'loaded')")) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The embedded custom font did not load without Typewright's URL scheme handler")
    }

    func testDarkHTMLActivatesMediaQueriesWithLightBrowserAppearance() async throws {
        let input = root.appendingPathComponent("main.typ")
        try """
        #html.elem("style", "body { color: rgb(0, 0, 0); } @media (prefers-color-scheme: dark) { body { color: rgb(1, 2, 3); } }")
        Hello
        """.write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("dark.html")
        let result = try run(["compile", input.path, output.path, "--dark", "--json"])
        XCTAssertEqual(result.0, 0, result.1 + result.2)
        let web = WKWebView()
        web.appearance = NSAppearance(named: .aqua)
        web.loadHTMLString(try String(contentsOf: output, encoding: .utf8), baseURL: root)
        let condition = """
        (() => {
          const frame = document.querySelector('iframe');
          return !matchMedia('(prefers-color-scheme: dark)').matches &&
            frame?.contentWindow.matchMedia('(prefers-color-scheme: dark)').matches &&
            frame.contentDocument.body?.textContent.includes('Hello') &&
            frame.contentWindow.getComputedStyle(frame.contentDocument.body).color === 'rgb(1, 2, 3)';
        })()
        """
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Exported HTML did not force dark media queries in a light browser")
    }
}
