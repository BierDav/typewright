import AppKit

/// When to commit: `idle` after the last change, but no later than `limit` after the first uncommitted one.
struct CommitTiming: Equatable {
    var idle: TimeInterval = 5
    var limit: TimeInterval = 60
    /// The first change not committed yet.
    private(set) var firstChange: Date?
    private(set) var lastChange: Date?

    /// When the pending changes are due, if any.
    var deadline: Date? {
        guard let firstChange, let lastChange else { return nil }
        return min(lastChange.addingTimeInterval(idle), firstChange.addingTimeInterval(limit))
    }

    mutating func change(at date: Date) {
        if firstChange == nil { firstChange = date }
        lastChange = date
    }

    func isDue(at date: Date) -> Bool { deadline.map { date >= $0 } ?? false }

    mutating func committed() {
        firstChange = nil
        lastChange = nil
    }

    /// Whether a changed path counts: jj's own store and Finder's metadata don't.
    static func counts(_ path: String, root: String) -> Bool {
        guard path.hasPrefix(root + "/") else { return path == root }
        let relative = path.dropFirst(root.count + 1)
        if relative == ".jj" || relative.hasPrefix(".jj/") { return false }
        return !relative.hasSuffix(".DS_Store")
    }
}

/// Commits the repository after edits settle: saves inside the app and changes from other apps alike.
@MainActor
final class CommitScheduler {
    static let shared = CommitScheduler()

    private var timing = CommitTiming()
    private var watcher: FolderWatcher?
    private var timer: Task<Void, Never>?
    private var committing = false
    private var squashTimer: Timer?
    private let now: () -> Date
    private let repository: () -> SpaceRepository

    init(now: @escaping () -> Date = Date.init, repository: @escaping () -> SpaceRepository = { .shared }) {
        self.now = now
        self.repository = repository
    }

    /// Watches the repository folder; anything already changed gets committed after the first pause.
    func start() {
        let repo = repository()
        guard watcher == nil, repo.isOpen else { return }
        SpaceFolders.prepareRepository(repo.root)
        let root = repo.root.resolvingSymlinksInPath().path
        watcher = FolderWatcher(repo.root) { [weak self] paths in
            guard paths.contains(where: { CommitTiming.counts($0, root: root) }) else { return }
            self?.noteChange()
        }
        noteChange()
        squashIfDue()
        squashTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.squashIfDue() }
        }
    }

    /// Once a day: history older than the setting collapses to one commit per day.
    private func squashIfDue(defaults: UserDefaults = .standard) {
        let last = defaults.object(forKey: HistorySettings.lastSquashKey) as? Date
        guard HistorySettings.squashIsDue(last: last, now: now()) else { return }
        guard let days = HistorySettings.squashDays(defaults) else { return }
        defaults.set(now(), forKey: HistorySettings.lastSquashKey)
        Task { await repository().squash(olderThan: days) }
    }

    /// Internal saves report here too, since FSEvents may coalesce them late.
    func noteChange() {
        timing.change(at: now())
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        guard let deadline = timing.deadline else { return }
        let delay = max(deadline.timeIntervalSince(now()), 0)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    private func fire() async {
        guard timing.isDue(at: now()) else { return schedule() }
        // Changes during the commit arm the next one.
        guard !committing else { return }
        committing = true
        timing.committed()
        await repository().commit()
        committing = false
        schedule()
    }

    /// Before quitting: saves land on disk first, then one last commit.
    func commitNow() async {
        timer?.cancel()
        timing.committed()
        await repository().commit()
    }
}
