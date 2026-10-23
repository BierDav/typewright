import AppKit

/// A change to the file tree that can be undone by doing its inverse on disk (never `jj undo`, so concurrent edits
/// and sync survive). Each one is committed at once with a descriptive message.
enum FileOp {
    struct Move: Equatable {
        let from: URL
        let to: URL
        var reversed: Move { Move(from: to, to: from) }
    }

    /// Renames and moves inside a space; paths in the space's files follow.
    case move([Move])
    /// Moves across the library's edge, like importing by dragging from Finder.
    case moveExternal([Move])
    case delete([URL])
    /// Deleted items back at their own paths.
    case restore([DeletedItem])
    case renameSpace(Move)
    case deleteSpace(URL)
    case restoreSpace(DeletedItem)
    /// Done in order, undone in reverse.
    case batch([FileOp])
}

/// Holds an op's inverse, known once the op ran; undo and redo register before they run.
final class FileOpBox {
    var op: FileOp?
    init(_ op: FileOp? = nil) { self.op = op }
}

/// Runs file ops one after another and registers their undo on the window's undo manager.
@MainActor
final class FileOperations {
    /// The space whose buffers, selection and tree follow the ops; nil for space-level ops.
    weak var workspace: Workspace?
    /// The window's; set when the space is shown.
    weak var undoManager: UndoManager?
    private var chain: Task<Void, Never>?
    private var repository: SpaceRepository { .shared }

    init(workspace: Workspace?) { self.workspace = workspace }

    /// Space-level ops (rename and delete spaces) of a window, without a space of their own.
    static let spaces = FileOperations(workspace: nil)

    /// Runs `op` and registers its undo as `name` (the Edit menu's "Undo <name>").
    func perform(_ op: FileOp, name: String, message: String, undoManager: UndoManager? = nil) {
        run(FileOpBox(op), name: name, message: message, undoMessage: "Undo \(message)", manager: undoManager ?? self.undoManager)
    }

    /// For ops that already happened synchronously (so the UI could follow at once): commits and registers `inverse`.
    func performed(inverse: FileOp, name: String, message: String, undoManager: UndoManager? = nil) {
        let manager = undoManager ?? self.undoManager
        let box = FileOpBox(inverse)
        register(box, name: name, message: "Undo \(message)", undoMessage: message, manager: manager)
        enqueue { [weak self] in await self?.commit(message) }
    }

    /// Runs `op` without undo (the editor's text undo owns it), handing its inverse to `done`.
    func apply(_ op: FileOp, message: String, done: @escaping @MainActor (FileOp?) -> Void = { _ in }) {
        enqueue { [weak self] in
            guard let self else { return }
            done(await self.execute(op, message: message))
        }
    }

    /// Waits for every queued op, for tests and before quitting.
    func settle() async { await chain?.value }

    private func run(_ box: FileOpBox, name: String, message: String, undoMessage: String, manager: UndoManager?) {
        let inverse = FileOpBox()
        register(inverse, name: name, message: undoMessage, undoMessage: message, manager: manager)
        enqueue { [weak self] in
            guard let self else { return }
            guard let op = box.op else { return NSSound.beep() }
            inverse.op = await self.execute(op, message: message)
        }
    }

    private func register(_ box: FileOpBox, name: String, message: String, undoMessage: String, manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { ops in
            ops.run(box, name: name, message: message, undoMessage: undoMessage, manager: manager)
        }
        manager.setActionName(name)
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func commit(_ message: String) async {
        workspace?.flushSaves()
        await repository.commit(message)
    }

    /// Does `op` and returns its inverse, or nil (after telling the user) when it couldn't.
    private func execute(_ op: FileOp, message: String) async -> FileOp? {
        switch op {
        case .move(let moves):
            var done: [FileOp.Move] = []
            for move in moves {
                guard let workspace, workspace.relocateForUndo(move.from, to: move.to) else {
                    if !failMove(move) { break }
                    continue
                }
                done.append(move)
            }
            guard !done.isEmpty else { return nil }
            await commit(message)
            return .move(done.reversed().map(\.reversed))
        case .moveExternal(let moves):
            workspace?.flushSaves()
            var done: [FileOp.Move] = []
            for move in moves {
                guard !FileManager.default.fileExists(atPath: move.to.path) else {
                    if !failMove(move) { break }
                    continue
                }
                do {
                    try FileManager.default.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: move.from, to: move.to)
                    repository.noteMoved(from: move.from, to: move.to)
                    done.append(move)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
            guard !done.isEmpty else { return nil }
            workspace?.forgetRemoved(done.map(\.from))
            await commit(message)
            return .moveExternal(done.reversed().map(\.reversed))
        case .delete(let urls):
            workspace?.flushSaves()
            let urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) || SpaceFolders.isLink($0) }
            guard !urls.isEmpty else { return nil }
            guard let items = await repository.delete(urls, message: message) else {
                alert("Couldn't delete “\(urls[0].lastPathComponent)”", repository.lastError)
                return nil
            }
            workspace?.forgetRemoved(urls)
            return .restore(items)
        case .restore(let items):
            var restored: [URL] = []
            for item in items {
                let url = repository.url(of: item.path)
                switch await repository.restore(item, to: url) {
                case .restored: restored.append(url)
                case .exists: alert("“\(item.name)” already exists", "Something else is at its place now, so it stays deleted.")
                case .failed: alert("Couldn't restore “\(item.name)”", repository.lastError)
                }
            }
            guard !restored.isEmpty else { return nil }
            workspace?.reloadTree()
            return .delete(restored)
        case .renameSpace(let move):
            guard Opener.shared.rename(space: move.from, to: move.to.lastPathComponent, registersUndo: false) != nil else { return nil }
            await repository.commit(message)
            return .renameSpace(move.reversed)
        case .deleteSpace(let url):
            guard let item = await Opener.shared.deleteSpaceNow(url, message: message) else { return nil }
            return .restoreSpace(item)
        case .restoreSpace(let item):
            let url = repository.url(of: item.path)
            switch await repository.restore(item, to: url) {
            case .restored:
                SpaceList.add(url)
                return .deleteSpace(url)
            case .exists:
                alert("“\(item.name)” already exists", "Rename the other space first.")
            case .failed:
                alert("Couldn't restore “\(item.name)”", repository.lastError)
            }
            return nil
        case .batch(let ops):
            var inverses: [FileOp] = []
            for op in ops {
                if let inverse = await execute(op, message: message) { inverses.append(inverse) }
            }
            return inverses.isEmpty ? nil : .batch(inverses.reversed())
        }
    }

    /// Tells the user a move can't happen; false stops the batch.
    private func failMove(_ move: FileOp.Move) -> Bool {
        if FileManager.default.fileExists(atPath: move.to.path) {
            alert("“\(move.to.lastPathComponent)” already exists", "Another item took its place, so it stays where it is.")
        } else if !FileManager.default.fileExists(atPath: move.from.path) {
            alert("“\(move.from.lastPathComponent)” is gone", "It was moved or deleted in the meantime.")
        }
        return true
    }

    private func alert(_ title: String, _ text: String?) {
        // Tests run without anyone to click.
        guard !SpaceRepository.isTestHost else { return NSLog("%@: %@", title, text ?? "") }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text ?? ""
        alert.runModal()
    }
}

/// "Deleted ‘x’" under the file tree, with Undo and a way to Recently Deleted.
struct FileNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// Where Recently Deleted opens.
    let folder: URL
}

/// An image the editor saved for a paste or drop, with the text that shows it.
struct PastedImage {
    let file: URL
    let document: URL
    let reference: String
    /// Set once undo took the reference out and the file went with it.
    var removed: [DeletedItem]?
    var pending = false
}

extension Workspace {
    /// Undo in the text took a pasted image's reference out: the file goes too; redo brings both back.
    func editorDidUndo(redo: Bool, text: String) {
        guard let document = selectedFile else { return }
        for index in pastedImages.indices where pastedImages[index].document == document && !pastedImages[index].pending {
            let image = pastedImages[index]
            let present = text.contains(image.reference)
            let message = SpaceRepository.shared.messagePath(image.file)
            if !redo, !present, image.removed == nil, FileManager.default.fileExists(atPath: image.file.path) {
                pastedImages[index].pending = true
                fileOps.apply(.delete([image.file]), message: "Undo Add \(message)") { [weak self] inverse in
                    guard let self, let i = self.pastedImages.firstIndex(where: { $0.file == image.file }) else { return }
                    self.pastedImages[i].pending = false
                    if case .restore(let items)? = inverse { self.pastedImages[i].removed = items }
                }
            } else if redo, present, let items = image.removed {
                pastedImages[index].pending = true
                fileOps.apply(.restore(items), message: "Add \(message)") { [weak self] _ in
                    guard let self, let i = self.pastedImages.firstIndex(where: { $0.file == image.file }) else { return }
                    self.pastedImages[i].pending = false
                    self.pastedImages[i].removed = nil
                }
            }
        }
    }
}

extension SpaceRepository {
    /// "Space/dir/file" for messages; the bare name outside the repository.
    func messagePath(_ url: URL) -> String { pathAllowingMissing(url) ?? url.lastPathComponent }
}
