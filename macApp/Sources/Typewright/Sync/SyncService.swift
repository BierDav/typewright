import AppKit
import IrohBridge
import Observation
import TypewrightCore

/// A space listed by the account, possibly not on this device yet.
struct AccountSpace: Identifiable, Hashable {
    let id: String
    let name: String
    /// Devices syncing it.
    var members: [String] = []
}

/// What `liveSync` reports about a file being edited on several devices.
struct LiveResult: Decodable {
    struct Edit: Decodable {
        let location: Int
        let length: Int
        let text: String
    }

    struct Adopted: Decodable {
        let base: String
        let theirs: String
    }

    struct Cursor: Decodable {
        let device: String
        let name: String
        let location: Int
        let length: Int
    }

    var edits: [Edit] = []
    var adopted: Adopted?
    var cursors: [Cursor] = []
    var peers = 0
    var undone = false
}

/// Syncs the spaces the user picked across all devices of their account: `irohBridge` moves the
/// data, `SpaceSync` from the Kotlin core decides what to do, and this applies it to the folders.
@MainActor @Observable
final class SyncService {
    static let shared = SyncService()

    /// Posted with the space root before sync replaces files, so editors save their edits first.
    static let willChangeFiles = Notification.Name("SyncWillChangeFiles")
    /// Posted with the space root after sync wrote, merged or trashed files.
    static let didChangeFiles = Notification.Name("SyncDidChangeFiles")
    /// Posted with the space root and the `path` in `userInfo` when another device edited an open file.
    static let liveDidChange = Notification.Name("SyncLiveDidChange")
    /// Posted when spaces start or stop syncing here, or the node starts or stops.
    static let syncedSpacesDidChange = Notification.Name("SyncSyncedSpacesDidChange")
    /// Live files above this size sync on save only.
    static let liveLimit = 512 * 1024

    private(set) var deviceID: String?
    /// Devices of the account this one is connected to right now.
    private(set) var connected: Set<String> = []
    /// Every device listed for the account, this one included.
    private(set) var devices: [String] = []
    private(set) var accountSpaces: [AccountSpace] = []
    /// Synced spaces on this device by id.
    private(set) var spaces: [String: URL] = [:]
    private(set) var lastError: String?

    /// Files above this size, in megabytes, sync whole without merging.
    var lfsThresholdMB: Double {
        didSet {
            defaults.set(lfsThresholdMB, forKey: Self.thresholdKey)
            engines.values.forEach { $0.lfsThreshold = lfsThresholdBytes }
        }
    }

    var isRunning: Bool { node != nil }
    /// Account spaces that another device syncs and this one doesn't.
    var elsewhere: [AccountSpace] {
        accountSpaces.filter { space in spaces[space.id] == nil && space.members.contains { $0 != deviceID } }
    }

    @ObservationIgnored private var node: OpaquePointer?
    @ObservationIgnored private var dataDir: URL?
    @ObservationIgnored private var engines: [String: SpaceSync] = [:]
    @ObservationIgnored private var ignores: [String: IgnoreRules] = [:]
    @ObservationIgnored private var watchers: [String: FolderWatcher] = [:]
    @ObservationIgnored private var scanning: Set<String> = []
    @ObservationIgnored private var scanPending: Set<String> = []
    /// Remote changes of a space apply one after another.
    @ObservationIgnored private var queues: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var exports: [Int64: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var nextRequest: Int64 = 1
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let scanner = FolderScanner()
    /// `space/path` of files open here and on another device; file sync leaves them to the live session.
    @ObservationIgnored private var livePaths: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults

    private static let spacesKey = "syncedSpaces"
    private static let thresholdKey = "syncLFSThresholdMB"

    /// Tests run several devices in one process, each with its own defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: Self.thresholdKey)
        lfsThresholdMB = saved > 0 ? saved : SyncPolicy.shared.DEFAULT_LFS_THRESHOLD / 1_048_576
        let stored = defaults.dictionary(forKey: Self.spacesKey) as? [String: String] ?? [:]
        spaces = stored.mapValues { URL(fileURLWithPath: $0) }
    }

    private var lfsThresholdBytes: Double { lfsThresholdMB * 1_048_576 }

    func isSynced(_ root: URL) -> Bool { spaceID(for: root) != nil }

    func spaceID(for root: URL) -> String? {
        spaces.first { $0.value.standardizedFileURL.path == root.standardizedFileURL.path }?.key
    }

    // MARK: - Lifecycle

    /// Starts with the signed-in account, or stops after signing out.
    func restart() {
        stop()
        guard let account = SyncIdentity.shared.account, let fingerprint = SyncIdentity.shared.fingerprint else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typewright/sync/\(fingerprint)", isDirectory: true)
        Task { await start(account: account, in: dir) }
    }

    /// Starts the node for `account` with its blobs, replicas and state in `dir`; true once running.
    @discardableResult
    func start(account: Data, in dir: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("state"), withIntermediateDirectories: true)
        dataDir = dir
        // Events find their service through the context; it outlives the node, which `stop` ends.
        let context = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        let address = await Task.detached {
            account.withUnsafeBytes { bytes in
                tws_start(dir.path, bytes.bindMemory(to: UInt8.self).baseAddress!, { context, event in
                    let text = String(cString: event)
                    let address = UInt(bitPattern: context)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
                            Unmanaged<SyncService>.fromOpaque(pointer).takeUnretainedValue().handle(text)
                        }
                    }
                }, UnsafeMutableRawPointer(bitPattern: context))
            }.map { UInt(bitPattern: $0) }
        }.value
        started(address.flatMap { OpaquePointer(bitPattern: $0) })
        return node != nil
    }

    private func started(_ node: OpaquePointer?) {
        guard let node else { return }
        self.node = node
        let raw = tws_device_id(node)
        deviceID = String(cString: raw)
        tws_string_free(raw)
        for (id, root) in spaces { open(id, root: root) }
        NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
    }

    func stop() {
        guard let node else { return }
        self.node = nil
        saveState()
        watchers.removeAll()
        engines.removeAll()
        queues.values.forEach { $0.cancel() }
        queues.removeAll()
        exports.values.forEach { $0.resume(returning: false) }
        exports.removeAll()
        connected = []
        devices = []
        accountSpaces = []
        deviceID = nil
        livePaths = []
        Task.detached { tws_stop(node) }
        NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
    }

    // MARK: - Spaces

    /// Starts syncing a space; the account lists it for the other devices.
    func share(_ root: URL) {
        guard let node, !isSynced(root) else { return }
        let id = UUID().uuidString.lowercased()
        remember(id, root: root)
        tws_share_space(node, id, root.lastPathComponent)
        open(id, root: root, announce: false)
        NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
    }

    /// Stops syncing here; the files stay and the other devices keep syncing.
    /// Once no device syncs the space anymore, it leaves the account.
    func stopSyncing(_ root: URL) {
        guard let id = spaceID(for: root) else { return }
        if let node { tws_close_space(node, id) }
        forget(id)
    }

    /// Stops syncing a space on every device; each keeps its files.
    func removeEverywhere(_ id: String) {
        guard let node else { return }
        tws_remove_space(node, id)
        accountSpaces.removeAll { $0.id == id }
        forget(id)
    }

    private func forget(_ id: String) {
        defer { NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil) }
        watchers[id] = nil
        engines[id] = nil
        spaces[id] = nil
        persistSpaces()
        if let file = stateFile(id) { try? FileManager.default.removeItem(at: file) }
    }

    /// Downloads a space from the other devices into a new folder inside `parent`.
    func join(_ space: AccountSpace, in parent: URL) -> URL? {
        guard node != nil else { return nil }
        let name = Paths.shared.uniqueName(name: space.name, ext: nil) {
            KotlinBoolean(bool: FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path))
        }
        let root = parent.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        remember(space.id, root: root)
        open(space.id, root: root)
        return root
    }

    private func remember(_ id: String, root: URL) {
        spaces[id] = root.standardizedFileURL
        persistSpaces()
    }

    private func persistSpaces() {
        defaults.set(spaces.mapValues(\.path), forKey: Self.spacesKey)
    }

    private func open(_ id: String, root: URL, announce: Bool = true) {
        guard let node else { return }
        let engine = SpaceSync(lfsThreshold: lfsThresholdBytes)
        if let file = stateFile(id), let state = try? String(contentsOf: file, encoding: .utf8) { engine.load(state: state) }
        engines[id] = engine
        watchers[id] = FolderWatcher(root) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan(id) }
        }
        // The first scan has to finish before replica entries are compared with the folder.
        scheduleScan(id, delay: 0)
        if announce { tws_open_space(node, id) } else { tws_list_space(node, id) }
    }

    // MARK: - Local changes

    private func scheduleScan(_ id: String, delay: Double = 0.5) {
        scanPending.insert(id)
        guard !scanning.contains(id) else { return }
        scanning.insert(id)
        Task {
            while scanPending.contains(id) {
                try? await Task.sleep(for: .seconds(delay))
                scanPending.remove(id)
                await scan(id)
            }
            scanning.remove(id)
        }
    }

    private func scan(_ id: String) async {
        guard let root = spaces[id] else { return }
        let scanner = scanner
        let result = await Task.detached { scanner.scan(root) }.value
        guard let engine = engines[id] else { return }
        ignores[id] = result.ignore
        let actions = engine.scan(files: Array(result.files.values), ignore: result.ignore)
        for action in actions { await perform(action, space: id) }
        if !actions.isEmpty { scheduleSave() }
    }

    // MARK: - Events

    private struct Event: Decodable {
        let type: String
        var message: String?
        var device: String?
        var peers: [String]?
        var devices: [String]?
        var spaces: [Space]?
        var removed: [String]?
        var space: String?
        var entries: [Entry]?
        var path: String?
        var hash: String?
        var size: Double?
        var deleted: Bool?
        var request: Int64?
        var ok: Bool?

        struct Space: Decodable {
            let id: String
            let name: String?
            let members: [String]?
        }

        struct Entry: Decodable {
            let path: String
            let hash: String
            let size: Double
            let deleted: Bool
        }
    }

    private func handle(_ text: String) {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(text.utf8)) else { return }
        switch event.type {
        case "status":
            connected = Set(event.peers ?? [])
            devices = event.devices ?? []
        case "spaces":
            accountSpaces = (event.spaces ?? []).map { AccountSpace(id: $0.id, name: $0.name ?? "Space", members: $0.members ?? []) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // Removed from all devices elsewhere: stop here too, keeping the files.
            for id in event.removed ?? [] where spaces[id] != nil {
                if let node { tws_close_space(node, id) }
                forget(id)
            }
        case "live":
            guard let id = event.space, let path = event.path, let root = spaces[id] else { return }
            NotificationCenter.default.post(name: Self.liveDidChange, object: root, userInfo: ["path": path])
        case "entries":
            guard let id = event.space else { return }
            for entry in event.entries ?? [] {
                enqueue(id, RemoteEntry(path: entry.path, hash: entry.hash, size: entry.size, deleted: entry.deleted))
            }
        case "remote":
            guard let id = event.space, let path = event.path, let hash = event.hash else { return }
            enqueue(id, RemoteEntry(path: path, hash: hash, size: event.size ?? 0, deleted: event.deleted ?? false))
        case "published":
            guard let id = event.space, let path = event.path, let hash = event.hash else { return }
            engines[id]?.published(path: path, hash: hash, deleted: event.deleted ?? false)
            scheduleSave()
        case "exported":
            guard let request = event.request else { return }
            exports.removeValue(forKey: request)?.resume(returning: event.ok ?? false)
        case "error":
            lastError = event.message
            NSLog("Sync: %@", event.message ?? "")
        default:
            break
        }
    }

    private func enqueue(_ id: String, _ entry: RemoteEntry) {
        let previous = queues[id]
        queues[id] = Task {
            await previous?.value
            await applyRemote(entry, space: id)
        }
    }

    private func applyRemote(_ entry: RemoteEntry, space id: String) async {
        // Wait for the first scan, which knows the ignore rules.
        while scanning.contains(id) && ignores[id] == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let root = spaces[id], let engine = engines[id] else { return }
        NotificationCenter.default.post(name: Self.willChangeFiles, object: root)
        let scanner = scanner
        let path = entry.path
        let local = await Task.detached { scanner.file(root, path: path) }.value
        let ignore = ignores[id] ?? IgnoreRules()
        // The live session already has this version's edits; writing it could undo newer ones.
        if livePaths.contains(id + "/" + path), !entry.deleted, local != nil {
            engine.accepted(path: path, hash: entry.hash)
            scheduleSave()
            return
        }
        let actions = engine.remote(entry: entry, local: local, ignore: ignore) { candidate in
            KotlinBoolean(bool: FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path))
        }
        for action in actions { await perform(action, space: id) }
        if !actions.isEmpty { scheduleSave() }
    }

    // MARK: - Live editing

    func liveOpen(root: URL, path: String, text: String) {
        guard let node, let id = spaceID(for: root) else { return }
        tws_live_open(node, id, path, text, Host.current().localizedName ?? "Mac")
    }

    func liveClose(root: URL, path: String) {
        guard let node, let id = spaceID(for: root) else { return }
        livePaths.remove(id + "/" + path)
        tws_live_close(node, id, path)
    }

    /// `step` 1 undoes and 2 redoes this device's last edit of the file.
    func liveSync(root: URL, path: String, text: String, selection: NSRange, step: Int32 = 0) -> LiveResult? {
        guard let node, let id = spaceID(for: root) else { return nil }
        let raw = tws_live_sync(node, id, path, text, UInt32(clamping: selection.location), UInt32(clamping: selection.length), step)
        defer { tws_string_free(raw) }
        guard let result = try? JSONDecoder().decode(LiveResult.self, from: Data(String(cString: raw).utf8)) else { return nil }
        if result.peers > 0 { livePaths.insert(id + "/" + path) } else { livePaths.remove(id + "/" + path) }
        return result
    }

    // MARK: - Actions

    private func perform(_ action: SyncAction, space id: String) async {
        guard let node, let root = spaces[id], let engine = engines[id] else { return }
        let url = root.appendingPathComponent(action.path)
        switch action {
        case is SyncAction.Publish:
            tws_publish(node, id, action.path, url.path)
        case is SyncAction.Unpublish:
            tws_unpublish(node, id, action.path)
        case let write as SyncAction.Write:
            let ok = await place(write.hash, size: write.size, at: url)
            engine.wrote(path: write.path, hash: write.hash, ok: ok)
            changed(root)
        case is SyncAction.Trash:
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            changed(root)
        case let merge as SyncAction.Merge:
            await performMerge(merge, root: root, space: id, engine: engine)
        case let copy as SyncAction.ConflictCopy:
            _ = await place(copy.hash, size: copy.size, at: root.appendingPathComponent(copy.copyPath))
            changed(root)
        default:
            break
        }
    }

    /// Three-way merge of a small text file both sides edited; leftovers become a conflict copy.
    private func performMerge(_ merge: SyncAction.Merge, root: URL, space id: String, engine: SpaceSync) async {
        let url = root.appendingPathComponent(merge.path)
        let base = await text(of: merge.baseHash)
        let remote = await text(of: merge.remoteHash)
        let local = try? String(contentsOf: url, encoding: .utf8)
        if let base, let remote, let local {
            let result = TextMerge.shared.merge3(base: base, local: local, remote: remote)
            if result.conflicts == 0, (try? result.text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                engine.merged(path: merge.path, remoteHash: merge.remoteHash)
                changed(root)
                scheduleScan(id)
                return
            }
        }
        let size = Double(remote?.utf8.count ?? 0)
        let fallback = engine.mergeFailed(path: merge.path, remoteHash: merge.remoteHash, size: size) { candidate in
            KotlinBoolean(bool: FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path))
        }
        for action in fallback { await perform(action, space: id) }
    }

    /// Exports a blob next to the target first, so the file is replaced in one step.
    private func place(_ hash: String, size: Double, at target: URL) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard size > 0 else {
                try Data().write(to: target, options: .atomic)
                return true
            }
            guard let temp = temporaryFile(), await export(hash, to: temp) else { return false }
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func text(of hash: String) async -> String? {
        guard let temp = temporaryFile(), await export(hash, to: temp) else { return nil }
        defer { try? FileManager.default.removeItem(at: temp) }
        return try? String(contentsOf: temp, encoding: .utf8)
    }

    private func export(_ hash: String, to url: URL) async -> Bool {
        guard let node else { return false }
        let request = nextRequest
        nextRequest += 1
        return await withCheckedContinuation { continuation in
            exports[request] = continuation
            tws_export(node, hash, url.path, request)
        }
    }

    private func temporaryFile() -> URL? {
        dataDir?.appendingPathComponent("tmp/\(UUID().uuidString)")
    }

    private func changed(_ root: URL) {
        NotificationCenter.default.post(name: Self.didChangeFiles, object: root)
    }

    // MARK: - State

    private func stateFile(_ id: String) -> URL? {
        dataDir?.appendingPathComponent("state/\(id).txt")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveState()
        }
    }

    private func saveState() {
        for (id, engine) in engines {
            guard let file = stateFile(id) else { continue }
            try? engine.save().write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
