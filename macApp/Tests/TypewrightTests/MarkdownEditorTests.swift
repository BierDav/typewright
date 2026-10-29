import AppKit
import WebKit
import XCTest
@testable import Typewright

@MainActor
final class MarkdownEditorTests: XCTestCase {
    private func evaluate(_ view: WKWebView, _ script: String, until done: (Any?) -> Bool) async throws -> Any? {
        var result: Any?
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            result = try? await view.evaluateJavaScript(script)
            if done(result) { break }
        }
        return result
    }

    func testEditsBlocksAndKeepsTheRest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tw-markdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Resources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 8, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: root.appending(path: "Resources/logo.png"))
        let file = root.appending(path: "notes.md")
        let source = "# Hi\n\n![](Resources/logo.png)\n\n| a |\n|---|\n| 1 |\n\nLast  line.\n"
        try source.write(to: file, atomically: true, encoding: .utf8)

        let workspace = Workspace(url: file)
        defer { workspace.close() }
        XCTAssertTrue(workspace.showsMarkdown)
        XCTAssertFalse(Workspace.isPreviewable(file))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = workspace.markdownEditor
        window.contentView = editor.view
        editor.show(file, text: workspace.text)

        // Relative images load through the file's folder.
        let widths = try await evaluate(editor.view, "[...document.images].map(i => i.complete ? i.naturalWidth : -1)") {
            ($0 as? [Int]) == [8]
        }
        XCTAssertEqual(widths as? [Int], [8])
        let kinds = try await evaluate(editor.view, "[...document.querySelectorAll('.blk')].map(b => b.className.split(' ')[1]).join()") { _ in true }
        XCTAssertEqual(kinds as? String, "k-heading,k-paragraph,k-raw,k-paragraph")

        // An edit in one block changes only its lines.
        _ = try await editor.view.evaluateJavaScript("""
            const h = document.querySelector('h1.t'); h.focus(); h.textContent = 'Hello';
            h.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'o' })); true
            """)
        _ = try await evaluate(editor.view, "1") { _ in workspace.text != source }
        XCTAssertEqual(workspace.text, source.replacingOccurrences(of: "# Hi", with: "# Hello"))

        // A change from the source editor reaches the page.
        workspace.markdownEditorDidChange(workspace.text.replacingOccurrences(of: "Last  line.", with: "Last line, changed."))
        editor.show(file, text: workspace.text)
        let last = try await evaluate(editor.view, "[...document.querySelectorAll('.k-paragraph .t')].map(t => t.textContent).join('|')") {
            ($0 as? String)?.contains("changed") == true
        }
        XCTAssertEqual(last as? String, "|Last line, changed.")
    }
}
