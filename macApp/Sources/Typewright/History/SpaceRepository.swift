import Foundation
import JJBridge
import Observation

/// A version of a file in the local history.
struct FileVersion: Identifiable, Hashable, Decodable {
    enum Kind: String, Decodable { case added, modified, deleted, renamed }

    let commit: String
    let time: Date
    let description: String
    let kind: Kind
    /// The path before a rename.
    let from: String?
    let added: Int
    let removed: Int

    var id: String { commit }

    private enum CodingKeys: String, CodingKey { case commit, time, description, kind, from, added, removed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commit = try c.decode(String.self, forKey: .commit)
        time = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .time))
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .modified
        from = try c.decodeIfPresent(String.self, forKey: .from)
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        removed = try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0
    }
}

/// A deleted file or folder as the history (or the LFS stash) still has it.
struct DeletedItem: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case file, folder }

    let path: String
    let kind: Kind
    let files: Int
    /// The deleting commit and its parent, which still has the item; nil for stashed LFS files only.
    let commit: String?
    let lastCommit: String?
    /// Stashed LFS files, which jj never tracked.
    let stash: String?
    let time: Date
    let description: String

    var id: String { "\(path)@\(time.timeIntervalSince1970)" }
    var name: String { (path as NSString).lastPathComponent }
    /// The space folder it was in.
    var space: String { String(path.split(separator: "/").first ?? "") }

    private enum CodingKeys: String, CodingKey { case path, kind, files, commit, lastCommit, stash, time, description }

    init(path: String, kind: Kind, files: Int, commit: String?, lastCommit: String?, stash: String?, time: Date, description: String) {
        self.path = path
        self.kind = kind
        self.files = files
        self.commit = commit
        self.lastCommit = lastCommit
        self.stash = stash
        self.time = time
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .file
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 1
        commit = try c.decodeIfPresent(String.self, forKey: .commit)
        lastCommit = try c.decodeIfPresent(String.self, forKey: .lastCommit)
        stash = try c.decodeIfPresent(String.self, forKey: .stash)
        time = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .time))
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(kind, forKey: .kind)
        try c.encode(files, forKey: .files)
        try c.encodeIfPresent(commit, forKey: .commit)
        try c.encodeIfPresent(lastCommit, forKey: .lastCommit)
        try c.encodeIfPresent(stash, forKey: .stash)
        try c.encode(time.timeIntervalSince1970, forKey: .time)
        try c.encode(description, forKey: .description)
    }

    var json: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }
}

/// A file's content in some commit.
enum FileContent: Equatable {
    case text(String)
    case data(Data)
    case missing
}

/// A conflicted file, split into agreed text and conflicting hunks.
struct FileConflict: Equatable {
    enum Hunk: Equatable {
        case text(String)
        case conflict(base: String, sides: [String])
    }

    let path: String
    let binary: Bool
    /// Labels of the sides, like the devices they came from.
    let sides: [String]
    let hunks: [Hunk]
}

/// The one internal jj repository: every space is a top-level folder in it. jj calls block, so they run one after
/// another on a background queue.
@MainActor @Observable
final class SpaceRepository {
    static let shared = SpaceRepository()

    /// Posted after a commit with `changed` (repo-relative paths) in `userInfo`, and `wrote: true` when files on disk
    /// were rewritten (restore, resolve, a repaired stale working copy), so editors reload.
    static let didCommit = Notification.Name("SpaceRepositoryDidCommit")
    /// Posted when the set of conflicted files changed.
    static let conflictsDidChange = Notification.Name("SpaceRepositoryConflictsDidChange")
    /// Posted after a file, folder or space moved on disk, with `from` and `to` URLs in `userInfo`; shares follow.
    static let didMove = Notification.Name("SpaceRepositoryDidMove")
    /// Posted with the deleted repository `paths` in `userInfo`, before the commit's `didCommit`.
    static let didDelete = Notification.Name("SpaceRepositoryDidDelete")
    /// Posted with `from` (the deleted path) and `to` (where it came back) in `userInfo`.
    static let didRestore = Notification.Name("SpaceRepositoryDidRestore")

    /// `~/Library/Application Support/Typewright/Spaces` in the real home, so links to it work for other apps.
    let root: URL
    /// Conflicted files, as file URLs inside `root`.
    private(set) var conflicted: Set<URL> = []
    /// The last error the bridge reported, cleared by the next call that works.
    private(set) var lastError: String?

    /// What a commit did; `busy` means the jj CLI held the repository, so try again shortly.
    enum CommitOutcome: Equatable {
        case committed([String])
        case busy
        case failed
    }

    @ObservationIgnored private let queue = DispatchQueue(label: "Typewright.SpaceRepository")
    @ObservationIgnored nonisolated(unsafe) private var handle: OpaquePointer?

    init(root: URL = SpaceRepository.defaultRoot) {
        self.root = root.standardizedFileURL
        if Self.isTestHost {
            // The bridge writes jj's repo config under XDG_CONFIG_HOME; keep tests out of the real ~/.config.
            let config = FileManager.default.temporaryDirectory.appendingPathComponent("TypewrightTests/config")
            setenv("XDG_CONFIG_HOME", config.path, 1)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        handle = twj_open(root.path)
    }

    nonisolated static var defaultRoot: URL {
        // The test host must never open the real library; a fixed path keeps it one repo across runs.
        if isTestHost {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TypewrightTests/Spaces", isDirectory: true)
        }
        #if DEBUG
        // Lets a dev run use a scratch library instead of the real one.
        if let path = ProcessInfo.processInfo.environment["TYPEWRIGHT_SPACES_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        // The sandbox's home is the container; links into it would need other apps to pass App Data protection.
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Typewright/Spaces", isDirectory: true)
    }

    nonisolated static var isTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    var isOpen: Bool { handle != nil }

    /// Whether `url` lies inside the repository (after resolving links into it).
    func contains(_ url: URL) -> Bool { relativePath(of: url) != nil }

    /// `Space/dir/file.typ` for a URL in the repository.
    func relativePath(of url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// Tells observers (the sync of shares) that `from` moved to `to` on disk; call right after moving.
    func noteMoved(from: URL, to: URL) {
        NotificationCenter.default.post(name: Self.didMove, object: self, userInfo: ["from": from, "to": to])
    }

    func url(of relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    /// Like `relativePath(of:)` for a path that may not exist yet, where links can't be resolved.
    func pathAllowingMissing(_ url: URL) -> String? {
        if let path = relativePath(of: url) { return path }
        let path = url.standardizedFileURL.path
        for base in [root.path, root.resolvingSymlinksInPath().path] where path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return nil
    }

    func setLFSLimit(bytes: UInt64) {
        run { twj_set_lfs_limit($0, bytes) }
    }

    /// The Devices setting is in megabytes.
    func setLFSLimit(megabytes: Double) {
        setLFSLimit(bytes: UInt64(max(megabytes, 0) * 1_048_576))
    }

    // MARK: - History

    /// Commits whatever changed on disk.
    @discardableResult
    func commit(_ message: String = "Edit") async -> CommitOutcome {
        struct Result: Decodable { let commit: String?; let changed: [String] }
        switch await reply({ twj_commit($0, message) }) as Reply<Result> {
        case .busy: return .busy
        case .failed: return .failed
        case .ok(let result):
            if !result.changed.isEmpty {
                postDidCommit(result.changed, wrote: false)
                await refreshConflicts()
            }
            return .committed(result.changed)
        }
    }

    /// Whether the squash ran (false when it failed or the CLI held the repository).
    @discardableResult
    func squash(policy: RetentionPolicy) async -> Bool {
        struct Result: Decodable { let squashed: Int }
        let json = policy.json
        let result: Result? = await call { twj_squash($0, json) }
        return result != nil
    }

    func history(of url: URL, limit: Int = 500) async -> [FileVersion] {
        guard let path = pathAllowingMissing(url) else { return [] }
        return await call({ twj_file_history($0, path, UInt32(clamping: limit)) }) ?? []
    }

    func content(of url: URL, at commit: String) async -> FileContent {
        struct Result: Decodable { let text: String?; let data: String?; let missing: Bool? }
        guard let path = pathAllowingMissing(url), let result: Result = await call({ twj_file_at($0, commit, path) })
        else { return .missing }
        if let text = result.text { return .text(text) }
        if let data = result.data.flatMap({ Data(base64Encoded: $0) }) { return .data(data) }
        return .missing
    }

    /// Puts the file back as it was in `commit`; editors reload through `didCommit`.
    func restore(_ url: URL, from commit: String) async -> Bool {
        struct Result: Decodable { let commit: String? }
        guard let path = pathAllowingMissing(url), let _: Result = await call({ twj_restore_file($0, commit, path) })
        else { return false }
        postDidCommit([path], wrote: true)
        return true
    }

    // MARK: - Deleting

    /// Deletes files and folders and commits `message` at once; there's no trash, the history keeps them.
    /// Returns what was deleted, for undo; nil when it failed.
    func delete(_ urls: [URL], message: String) async -> [DeletedItem]? {
        struct Result: Decodable { let deleted: [DeletedItem] }
        let paths = urls.compactMap(pathAllowingMissing)
        guard paths.count == urls.count, let data = try? JSONEncoder().encode(paths) else { return nil }
        let json = String(decoding: data, as: UTF8.self)
        guard let result: Result = await call({ twj_delete($0, json, message) }) else { return nil }
        NotificationCenter.default.post(name: Self.didDelete, object: self, userInfo: ["paths": paths])
        postDidCommit(paths, wrote: false)
        return result.deleted
    }

    /// Deleted items under `folder` (a space or folder in the repository; nil for all), newest first.
    func deleted(in folder: URL? = nil, limit: Int = 500) async -> [DeletedItem] {
        let prefix = folder.flatMap(relativePath(of:)) ?? ""
        if folder != nil, prefix.isEmpty, folder?.standardizedFileURL != root { return [] }
        return await call({ twj_deleted($0, prefix, UInt32(clamping: limit)) }) ?? []
    }

    enum RestoreOutcome: Equatable {
        case restored
        /// Something else is at the destination now.
        case exists
        case failed
    }

    /// Puts a deleted item back at `url` (its own path, or another name for "Keep Both").
    func restore(_ item: DeletedItem, to url: URL) async -> RestoreOutcome {
        struct Result: Decodable { let commit: String?; let files: Int? }
        struct Exists: Decodable { let exists: Bool? }
        guard let dest = pathAllowingMissing(url) else { return .failed }
        let entry = item.json
        guard let data = await json({ twj_restore_deleted($0, entry, dest) }) else { return .failed }
        if (try? JSONDecoder().decode(Exists.self, from: data))?.exists == true { return .exists }
        guard case .ok = decode(data) as Reply<Result> else { return .failed }
        NotificationCenter.default.post(name: Self.didRestore, object: self, userInfo: ["from": item.path, "to": dest])
        postDidCommit([dest], wrote: true)
        return .restored
    }

    // MARK: - Conflicts

    func refreshConflicts() async {
        let paths: [String] = await call({ twj_conflicts($0, "") }) ?? []
        let urls = Set(paths.map(url(of:)))
        guard urls != conflicted else { return }
        conflicted = urls
        NotificationCenter.default.post(name: Self.conflictsDidChange, object: self)
    }

    func isConflicted(_ url: URL) -> Bool { conflicted.contains(url.standardizedFileURL) }

    func conflict(at url: URL) async -> FileConflict? {
        struct Raw: Decodable {
            struct Hunk: Decodable {
                struct Conflict: Decodable { let base: String; let sides: [String] }
                let text: String?
                let conflict: Conflict?
            }
            let path: String
            let binary: Bool
            let sides: [String]
            let hunks: [Hunk]
        }
        guard let path = relativePath(of: url), let raw: Raw = await call({ twj_conflict($0, path) }) else { return nil }
        let hunks: [FileConflict.Hunk] = raw.hunks.map { hunk in
            if let c = hunk.conflict { return .conflict(base: c.base, sides: c.sides) }
            return .text(hunk.text ?? "")
        }
        return FileConflict(path: raw.path, binary: raw.binary, sides: raw.sides, hunks: hunks)
    }

    /// Resolves with `text`, or for binary files by keeping side `side`.
    func resolve(_ url: URL, text: String?, side: Int = 0) async -> Bool {
        struct Result: Decodable { let commit: String? }
        guard let path = relativePath(of: url) else { return false }
        let result: Result? = await call { repo in
            if let text { return twj_resolve(repo, path, text, Int32(side)) }
            return twj_resolve(repo, path, nil, Int32(side))
        }
        guard result != nil else { return false }
        postDidCommit([path], wrote: true)
        await refreshConflicts()
        return true
    }

    // MARK: - Bridge

    /// Raw JSON call for the sync engine.
    func json(_ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> Data? {
        guard let handle else { return nil }
        let handleBits = UInt(bitPattern: handle)
        return await withCheckedContinuation { continuation in
            queue.async {
                let repo = OpaquePointer(bitPattern: handleBits)!
                guard let raw = body(repo) else { return continuation.resume(returning: nil) }
                let data = Data(String(cString: raw).utf8)
                twj_string_free(raw)
                continuation.resume(returning: data)
            }
        }
    }

    private func postDidCommit(_ changed: [String], wrote: Bool) {
        NotificationCenter.default.post(name: Self.didCommit, object: self, userInfo: ["changed": changed, "wrote": wrote])
    }

    /// The fields the bridge may add to any object result.
    private struct Meta: Decodable {
        let error: String?
        let busy: Bool?
        let staleWorkspaces: [String]?
        let wrote: Bool?
    }

    private enum Reply<T> {
        case ok(T)
        case busy
        case failed
    }

    private func reply<T: Decodable>(_ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> Reply<T> {
        guard let data = await json(body) else { return .failed }
        return decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) -> Reply<T> {
        let meta = try? JSONDecoder().decode(Meta.self, from: data)
        if let stale = meta?.staleWorkspaces, !stale.isEmpty {
            NSLog("jj: left stale, run `jj workspace update-stale` there: %@", stale.joined(separator: ", "))
        }
        if meta?.wrote == true { postDidCommit([], wrote: true) }
        if let error = meta?.error {
            NSLog("jj: %@", error)
            if meta?.busy == true { return .busy }
            lastError = error
            return .failed
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { return .failed }
        lastError = nil
        return .ok(value)
    }

    private func call<T: Decodable>(_ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> T? {
        if case .ok(let value) = await reply(body) as Reply<T> { return value }
        return nil
    }

    private func run(_ body: @escaping @Sendable (OpaquePointer) -> Void) {
        guard let handle else { return }
        let handleBits = UInt(bitPattern: handle)
        queue.async { body(OpaquePointer(bitPattern: handleBits)!) }
    }
}
