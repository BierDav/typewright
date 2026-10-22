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

    /// Posted after a commit with `changed` (repo-relative paths) in `userInfo`.
    static let didCommit = Notification.Name("SpaceRepositoryDidCommit")
    /// Posted when the set of conflicted files changed.
    static let conflictsDidChange = Notification.Name("SpaceRepositoryConflictsDidChange")

    /// `~/Library/Application Support/Typewright/Spaces` in the real home, so links to it work for other apps.
    let root: URL
    /// Conflicted files, as file URLs inside `root`.
    private(set) var conflicted: Set<URL> = []

    @ObservationIgnored private let queue = DispatchQueue(label: "Typewright.SpaceRepository")
    @ObservationIgnored nonisolated(unsafe) private var handle: OpaquePointer?

    init(root: URL = SpaceRepository.defaultRoot) {
        self.root = root.standardizedFileURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        handle = twj_open(root.path)
    }

    nonisolated static var defaultRoot: URL {
        // The sandbox's home is the container; links into it would need other apps to pass App Data protection.
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Typewright/Spaces", isDirectory: true)
    }

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

    func url(of relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    func setLFSLimit(bytes: UInt64) {
        run { twj_set_lfs_limit($0, bytes) }
    }

    // MARK: - History

    /// Commits whatever changed on disk; returns the changed paths.
    @discardableResult
    func commit(_ message: String = "Edit") async -> [String] {
        struct Result: Decodable { let commit: String?; let changed: [String] }
        guard let result: Result = await call({ twj_commit($0, message) }) else { return [] }
        if !result.changed.isEmpty {
            NotificationCenter.default.post(name: Self.didCommit, object: self, userInfo: ["changed": result.changed])
            await refreshConflicts()
        }
        return result.changed
    }

    func squash(olderThan days: Int) async {
        struct Result: Decodable { let squashed: Int }
        let _: Result? = await call { twj_squash($0, UInt32(clamping: days)) }
    }

    func history(of url: URL, limit: Int = 500) async -> [FileVersion] {
        guard let path = relativePath(of: url) else { return [] }
        return await call({ twj_file_history($0, path, UInt32(clamping: limit)) }) ?? []
    }

    func content(of url: URL, at commit: String) async -> FileContent {
        struct Result: Decodable { let text: String?; let data: String?; let missing: Bool? }
        guard let path = relativePath(of: url), let result: Result = await call({ twj_file_at($0, commit, path) })
        else { return .missing }
        if let text = result.text { return .text(text) }
        if let data = result.data.flatMap({ Data(base64Encoded: $0) }) { return .data(data) }
        return .missing
    }

    /// Puts the file back as it was in `commit`; editors reload through `didCommit`.
    func restore(_ url: URL, from commit: String) async -> Bool {
        struct Result: Decodable { let commit: String? }
        guard let path = relativePath(of: url), let _: Result = await call({ twj_restore_file($0, commit, path) })
        else { return false }
        NotificationCenter.default.post(name: Self.didCommit, object: self, userInfo: ["changed": [path]])
        return true
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
        NotificationCenter.default.post(name: Self.didCommit, object: self, userInfo: ["changed": [path]])
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

    private struct BridgeError: Decodable { let error: String }

    private func call<T: Decodable>(_ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> T? {
        guard let data = await json(body) else { return nil }
        if let error = try? JSONDecoder().decode(BridgeError.self, from: data) {
            NSLog("jj: %@", error.error)
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func run(_ body: @escaping @Sendable (OpaquePointer) -> Void) {
        guard let handle else { return }
        let handleBits = UInt(bitPattern: handle)
        queue.async { body(OpaquePointer(bitPattern: handleBits)!) }
    }
}
