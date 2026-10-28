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
    case deleteCreated(URL, [URL])
    case restoreCreated([DeletedItem], [URL])
    /// Deleted items back at their own paths.
    case restore([DeletedItem])
    case restoreExternal([FileOp.Move])
    case recover(URL, Data)
    case write(URL, Data)
    case listSpace(URL, Bool)
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
    private var queued = 0
    private var repository: SpaceRepository { .shared }

    init(workspace: Workspace?) { self.workspace = workspace }

    /// Space-level ops (rename and delete spaces) of a window, without a space of their own.
    static let spaces = FileOperations(workspace: nil)

    /// Runs `op` and registers its undo as `name` (the Edit menu's "Undo <name>").
    func perform(_ op: FileOp, name: String, message: String, undoManager: UndoManager? = nil) {
        let manager = undoManager ?? self.undoManager
        if case .write(let url, let data) = op, !data.contains(0), let after = String(data: data, encoding: .utf8) {
            (manager as? ActionUndoManager)?.prepare(text: try? String(contentsOf: url, encoding: .utf8),
                                                   after: after, detail: message, target: self)
        }
        run(FileOpBox(op), name: name, message: message, undoMessage: "Undo \(message)", manager: manager)
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
    func settle() async {
        while true {
            let generation = queued
            await chain?.value
            if generation == queued { return }
        }
    }

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
        (manager as? ActionUndoManager)?.prepare(detail: undoMessage, target: self)
        manager.registerUndo(withTarget: self) { ops in
            ops.run(box, name: name, message: message, undoMessage: undoMessage, manager: manager)
        }
        manager.setActionName(name)
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        queued += 1
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
                    PaletteDialog.error(error)
                }
            }
            guard !done.isEmpty else { return nil }
            Workspace.movedExternally(done.map { FileMove(from: $0.from, to: $0.to) })
            workspace?.forgetRemoved(done.map(\.from))
            Workspace.filesChangedExternally(in: repository.root, paths: done.flatMap { [$0.from, $0.to] })
            await commit(message)
            return .moveExternal(done.reversed().map(\.reversed))
        case .deleteCreated(let file, let folders):
            guard case .restore(let items)? = await execute(.delete([file]), message: message) else { return nil }
            for folder in folders where (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: folder)
            }
            await commit(message)
            workspace?.reloadTree()
            return .restoreCreated(items, folders)
        case .restoreCreated(let items, let folders):
            guard case .delete(let files)? = await execute(.restore(items), message: message), let file = files.first else { return nil }
            return .deleteCreated(file, folders)
        case .delete(let urls):
            workspace?.flushSaves()
            let urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) || SpaceFolders.isLink($0) }
            guard !urls.isEmpty else { return nil }
            if let workspace, !SpaceList.isInRepository(workspace.root) {
                var moves: [FileOp.Move] = []
                for url in urls {
                    do {
                        let trashed = try await FileTrash.recycle(url)
                        moves.append(.init(from: trashed, to: url))
                    } catch { PaletteDialog.error(error) }
                }
                workspace.forgetRemoved(moves.map(\.to))
                Workspace.filesChangedExternally(in: workspace.root, paths: moves.map(\.to))
                return moves.isEmpty ? nil : .restoreExternal(moves)
            }
            guard let items = await repository.delete(urls, message: message) else {
                alert("Couldn't delete “\(urls[0].lastPathComponent)”", repository.lastError)
                return nil
            }
            workspace?.forgetRemoved(urls)
            Workspace.filesChangedExternally(in: repository.root, paths: urls)
            return .restore(items)
        case .restoreExternal(let moves):
            var restored: [URL] = []
            for move in moves {
                guard !FileManager.default.fileExists(atPath: move.to.path) else { _ = failMove(move); continue }
                do {
                    try FileManager.default.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let from = move.from, to = move.to
                    try await Task.detached(priority: .userInitiated) { try FileTrash.move(from, to: to) }.value
                    restored.append(move.to)
                } catch { PaletteDialog.error(error) }
            }
            workspace?.reloadTree()
            return restored.isEmpty ? nil : .delete(restored)
        case .write(let url, let data):
            workspace?.flushSaves()
            switch await repository.commit("Edit") {
            case .committed: break
            case .busy, .failed:
                alert("Couldn't save the current version", "Try restoring again in a moment.")
                return nil
            }
            do {
                let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                await commit(message)
                workspace?.refreshFromDisk()
                if let previous { return .write(url, previous) }
                return .delete([url])
            } catch { PaletteDialog.error(error); return nil }
        case .recover(let url, let data):
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .withoutOverwriting)
                await commit(message)
                workspace?.reloadTree()
                workspace?.select(url)
                return .delete([url])
            } catch { PaletteDialog.error(error); return nil }
        case .listSpace(let url, let listed):
            if listed { SpaceList.add(url) } else { SpaceList.remove(url) }
            return .listSpace(url, !listed)
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
        PaletteDialog.message(title, detail: text)
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
    var removed: FileOp?
    var pending = false
    var referencePresent = true
}

extension Workspace {
    /// Undo in the text took a pasted image's reference out: the file goes too; redo brings both back.
    func editorDidUndo(redo: Bool, text: String) {
        guard let document = selectedFile else { return }
        for index in pastedImages.indices where pastedImages[index].document == document {
            pastedImages[index].referencePresent = text.contains(pastedImages[index].reference)
            reconcilePastedImage(at: index)
        }
    }

    private func reconcilePastedImage(at index: Int) {
        let image = pastedImages[index]
        guard !image.pending else { return }
        let message = SpaceRepository.shared.messagePath(image.file)
        if !image.referencePresent, image.removed == nil, FileManager.default.fileExists(atPath: image.file.path) {
            pastedImages[index].pending = true
            fileOps.apply(.delete([image.file]), message: "Undo Add \(message)") { [weak self] inverse in
                guard let self, let i = self.pastedImages.firstIndex(where: { $0.file == image.file }) else { return }
                self.pastedImages[i].pending = false
                self.pastedImages[i].removed = inverse
                if inverse != nil { self.reconcilePastedImage(at: i) }
            }
        } else if image.referencePresent, let restore = image.removed {
            pastedImages[index].pending = true
            fileOps.apply(restore, message: "Add \(message)") { [weak self] inverse in
                guard let self, let i = self.pastedImages.firstIndex(where: { $0.file == image.file }) else { return }
                self.pastedImages[i].pending = false
                if inverse != nil {
                    self.pastedImages[i].removed = nil
                    self.reconcilePastedImage(at: i)
                }
            }
        }
    }
}

extension SpaceRepository {
    /// "Space/dir/file" for messages; the bare name outside the repository.
    func messagePath(_ url: URL) -> String { pathAllowingMissing(url) ?? url.lastPathComponent }
}
