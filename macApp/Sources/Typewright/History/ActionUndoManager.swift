import AppKit
import Observation

/// Mirrors native undo groups for browsing without executing them to make a preview.
@MainActor @Observable
final class UndoJournal {
    struct Entry: Identifiable {
        let id = UUID()
        var name: String
        var before: String?
        var after: String?
        var detail: String?
        let target: ObjectIdentifier?
        var order = ProcessInfo.processInfo.systemUptime
    }

    var undo: [Entry] = []
    var redo: [Entry] = []
}

@MainActor
final class ActionUndoManager: UndoManager {
    let journal = UndoJournal()
    var text: (() -> String?)?
    var finishEditing: (() -> Void)?
    private var pending: UndoJournal.Entry?
    private var replaying = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(closeGroup),
                                               name: .NSUndoManagerWillCloseUndoGroup, object: self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func prepare(text: String? = nil, after: String? = nil, detail: String? = nil, target: AnyObject? = nil) {
        guard !replaying, isUndoRegistrationEnabled, !isUndoing, !isRedoing else { return }
        if pending == nil {
            pending = .init(name: "Edit", before: text, after: after, detail: detail,
                            target: target.map(ObjectIdentifier.init))
        }
    }

    @objc private func closeGroup() {
        guard groupingLevel == 1, !replaying, var entry = pending else { return }
        pending = nil
        guard canUndo else { return }
        entry.name = undoActionName.isEmpty ? "Edit" : undoActionName
        entry.after = text?() ?? entry.after
        journal.undo.append(entry)
        journal.redo = []
        if levelsOfUndo > 0, journal.undo.count > levelsOfUndo {
            journal.undo.removeFirst(journal.undo.count - levelsOfUndo)
        }
    }

    func refreshPreview() {
        guard pending == nil, !replaying, !journal.undo.isEmpty else { return }
        journal.undo[journal.undo.count - 1].after = text?()
    }

    override func setActionName(_ actionName: String) {
        super.setActionName(actionName)
        if groupingLevel == 0, !replaying, !journal.undo.isEmpty {
            journal.undo[journal.undo.count - 1].name = actionName
        }
    }

    func checkpoint() {
        guard isUndoRegistrationEnabled else { return }
        finishEditing?()
        if groupingLevel == 1 { endUndoGrouping() }
    }

    override func undo() {
        checkpoint()
        guard canUndo else { return }
        replaying = true
        super.undo()
        replaying = false
        if var entry = journal.undo.popLast() {
            entry.order = ProcessInfo.processInfo.systemUptime
            journal.redo.append(entry)
        }
    }

    override func redo() {
        guard canRedo else { return }
        replaying = true
        super.redo()
        replaying = false
        if var entry = journal.redo.popLast() {
            entry.order = ProcessInfo.processInfo.systemUptime
            journal.undo.append(entry)
        }
    }

    static func preferred(_ managers: [UndoManager?], redo: Bool) -> UndoManager? {
        managers.compactMap { $0 }.filter { redo ? $0.canRedo : $0.canUndo }.max { a, b in
            @MainActor func order(_ manager: UndoManager) -> Double {
                guard let manager = manager as? ActionUndoManager else { return 0 }
                return (redo ? manager.journal.redo.last : manager.journal.undo.last)?.order ?? 0
            }
            return order(a) < order(b)
        }
    }

    override func removeAllActions() {
        super.removeAllActions()
        pending = nil
        journal.undo = []
        journal.redo = []
    }

    override func removeAllActions(withTarget target: Any) {
        super.removeAllActions(withTarget: target)
        let id = ObjectIdentifier(target as AnyObject)
        journal.undo.removeAll { $0.target == id }
        journal.redo.removeAll { $0.target == id }
        if pending?.target == id { pending = nil }
    }
}
