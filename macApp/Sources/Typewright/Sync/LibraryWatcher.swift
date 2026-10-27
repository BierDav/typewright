import AppKit

/// FSEvents triggers an immediate jj snapshot; history commits keep their idle delay.
@MainActor
final class LibraryWatcher {
    static let shared = LibraryWatcher()
    private var library: FolderWatcher?
    private var external: [URL: (watcher: FolderWatcher, users: Int)] = [:]
    private var refreshTask: Task<Void, Never>?
    private var pending = false
    private var knownMoves: [FileMove] = []
    private var moveObserver: (any NSObjectProtocol)?

    func start() {
        guard library == nil else { return }
        SpaceFolders.prepareRepository(SpaceList.repository)
        moveObserver = NotificationCenter.default.addObserver(forName: SpaceRepository.didMove, object: nil, queue: .main) { [weak self] note in
            guard let from = note.userInfo?["from"] as? URL, let to = note.userInfo?["to"] as? URL else { return }
            MainActor.assumeIsolated { self?.knownMoves.append(FileMove(from: from, to: to)) }
        }
        library = FolderWatcher(SpaceList.repository, onPaths: { [weak self] paths in
            let root = SpaceList.repository.resolvingSymlinksInPath().path
            guard paths.contains(where: { CommitTiming.counts(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path, root: root) }) else { return }
            self?.refresh()
        })
        refresh()
    }

    func observe(_ root: URL) {
        if SpaceList.isInRepository(root) { return start() }
        if let entry = external[root] {
            external[root] = (entry.watcher, entry.users + 1)
        } else {
            let watcher = FolderWatcher(root, contentChangesOnly: true, onPaths: { paths in
                Workspace.filesChangedExternally(in: root, paths: paths.map { URL(fileURLWithPath: $0) })
            })
            external[root] = (watcher, 1)
        }
    }

    func stopObserving(_ root: URL) {
        guard let entry = external[root] else { return }
        if entry.users == 1 { external[root] = nil } else { external[root] = (entry.watcher, entry.users - 1) }
    }

    func refresh() {
        pending = true
        guard refreshTask == nil else { return }
        refreshTask = Task { await drainChanges() }
    }

    func refreshNow() async {
        refresh()
        await refreshTask?.value
    }

    private func drainChanges() async {
        defer { refreshTask = nil }
        repeat {
            pending = false
            // Folder listings need no history commit, even while the CLI holds jj's lock.
            NotificationCenter.default.post(name: SpaceList.didChange, object: nil)
            guard let changes = await SpaceRepository.shared.workingCopyChanges() else {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.refresh()
                }
                return
            }
            let moves = changes.renamed.map { FileMove(from: SpaceList.repository.appendingPathComponent($0.from),
                                                       to: SpaceList.repository.appendingPathComponent($0.to)) }
                .filter { !knownMoves.contains($0) }
            knownMoves.removeAll()
            var itemMoves: [FileMove] = []
            for move in moves {
                let isDirectory = (try? move.to.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory && move.from.deletingLastPathComponent().path == SpaceList.repository.path {
                    Opener.shared.spaceMovedExternally(from: move.from, to: move.to)
                } else {
                    itemMoves.append(move)
                }
            }
            Workspace.movedExternally(itemMoves)
            for move in moves { SpaceRepository.shared.noteMoved(from: move.from, to: move.to) }
            Workspace.filesChangedExternally(in: SpaceList.repository, paths: [SpaceList.repository])
        } while pending
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }
}
