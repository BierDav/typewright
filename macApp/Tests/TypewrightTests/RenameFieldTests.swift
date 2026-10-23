import AppKit
import SwiftUI
import XCTest
@testable import Typewright

@MainActor
final class RenameFieldTests: XCTestCase {
    func testNameIsSelectedAndTypingCommitsOnFocusLoss() async throws {
        var submitted: [String?] = []
        let host = NSHostingView(rootView: RenameField(name: "chapter.typ", base: "chapter") { submitted.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 7))
        editor.insertText("renamed", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted.first!, "renamed.typ")
    }

    func testEscapeCancelsWithoutSubmitting() async throws {
        var submitted: [String?] = []
        let host = NSHostingView(rootView: RenameField(name: "Untitled Space", base: "Untitled Space") { submitted.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(editor.selectedRange().length, 14)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        window.makeFirstResponder(nil)
        XCTAssertEqual(submitted.count, 1)
        XCTAssertNil(submitted.first!)
    }
    func testNewSpaceWindowSelectsItsName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("New Space \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MainWindowController(space: root, renameNewSpace: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        defer {
            controller.state.workspace?.close()
            controller.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertEqual(editor.string, root.lastPathComponent)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (root.lastPathComponent as NSString).length))
    }

}
