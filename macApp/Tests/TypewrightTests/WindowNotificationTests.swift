import XCTest
@testable import Typewright

@MainActor
final class WindowNotificationTests: XCTestCase {
    func testIndexingAndUndoShareNotificationsAcrossSidebarChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-notifications-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace(url: root)
        defer {
            workspace.close()
            try? FileManager.default.removeItem(at: root)
        }
        let state = WindowState(space: root)
        let notice = FileNotice(text: "Deleted a file", folder: root)
        var undos = 0
        state.showDeletion(notice) { undos += 1 }
        let visible = WindowNotification.current(state: state, workspace: workspace)
        XCTAssertEqual(visible.count, 2)
        state.sidebarVisible = false
        XCTAssertEqual(WindowNotification.current(state: state, workspace: workspace).map(\.id), visible.map(\.id))
        await workspace.waitForIndex()
        XCTAssertEqual(WindowNotification.current(state: state, workspace: workspace).map(\.id), [notice.id.uuidString])
        XCTAssertTrue(state.undoDeletion())
        XCTAssertEqual(undos, 1)
        XCTAssertTrue(WindowNotification.current(state: state, workspace: workspace).isEmpty)
    }
}
