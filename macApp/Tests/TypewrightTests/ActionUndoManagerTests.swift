import AppKit
import XCTest
@testable import Typewright

@MainActor
final class ActionUndoManagerTests: XCTestCase {
    @MainActor private final class Counter {
        var value = 0

        func change(to value: Int, using manager: ActionUndoManager) {
            let previous = self.value
            manager.prepare(text: String(previous), target: self)
            manager.registerUndo(withTarget: self) { $0.change(to: previous, using: manager) }
            self.value = value
        }
    }

    func testRoutingFollowsChangesAndTheOrderTheyWereUndone() {
        let editor = ActionUndoManager(), files = ActionUndoManager()
        let text = Counter(), tree = Counter()
        for manager in [editor, files] { manager.groupsByEvent = false }
        editor.text = { String(text.value) }
        files.text = { String(tree.value) }
        editor.beginUndoGrouping()
        text.change(to: 1, using: editor)
        editor.endUndoGrouping()
        files.beginUndoGrouping()
        tree.change(to: 1, using: files)
        files.endUndoGrouping()
        let managers: [UndoManager?] = [editor, files]
        XCTAssertTrue(ActionUndoManager.preferred(managers, redo: false) === files)
        files.undo()
        editor.undo()
        XCTAssertTrue(ActionUndoManager.preferred(managers, redo: true) === editor)
        editor.redo()
        XCTAssertTrue(ActionUndoManager.preferred(managers, redo: true) === files)
        files.redo()
        XCTAssertTrue(ActionUndoManager.preferred(managers, redo: false) === files)
        XCTAssertEqual(text.value, 1)
        XCTAssertEqual(tree.value, 1)
    }

    func testRemovingATargetRemovesItsJournalEntries() {
        let manager = ActionUndoManager()
        manager.groupsByEvent = false
        let target = Counter()
        manager.beginUndoGrouping()
        target.change(to: 1, using: manager)
        manager.endUndoGrouping()
        manager.undo()
        manager.removeAllActions(withTarget: target)
        XCTAssertFalse(manager.canRedo)
        XCTAssertTrue(manager.journal.redo.isEmpty)
    }
}
