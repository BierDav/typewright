import AppKit
import IrohBridge
import JJBridge
import Observation
import TypewrightCore

/// What a share covers: a whole space, a folder inside one, or a single file.
enum ShareKind: String, Codable, Hashable {
    case space, folder, file
}

/// A share listed by the account, possibly not on this device yet.
struct AccountShare: Identifiable, Hashable {
    let id: String
    let name: String
    var kind: ShareKind = .space
    /// Devices syncing it.
    var members: [String] = []
    /// Shared with other accounts through an invite link.
    var shared = false
}

/// Where a share lives on this device: its path in the space repository.
struct LocalShare: Codable, Hashable {
    var path: String
    var kind: ShareKind
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

/// Syncs shares (spaces, or any folder or file in one) across the devices of the account and with the people they
/// were shared with. Each state of a share travels as a jj node (`jjBridge`): a commit is exported and published as
/// this device's head (`irohBridge`), other devices' heads are fetched and merged 3-way by jj, and a clean merge is
/// published again, until every device holds the same node. Files open on two connected devices sync live through
/// the CRDT instead, so merges leave them alone.
@MainActor @Observable
final class SyncService {
    static let shared = SyncService()

    /// Posted with the space root before sync replaces files, so editors save their edits first.
    static let willChangeFiles = Notification.Name("SyncWillChangeFiles")
    /// Posted with the space root after sync wrote or merged files.
    static let didChangeFiles = Notification.Name("SyncDidChangeFiles")
    /// Posted with the space root and the `path` in `userInfo` when another device edited an open file.
    static let liveDidChange = Notification.Name("SyncLiveDidChange")
    /// Posted when shares start or stop syncing here, or the node starts or stops.
    static let syncedSpacesDidChange = Notification.Name("SyncSyncedSpacesDidChange")
    /// Live files above this size sync on save only.
    static let liveLimit = 512 * 1024

    private(set) var deviceID: String?
    /// Devices this one is connected to right now.
    private(set) var connected: Set<String> = []
    /// Every device listed for the account, this one included.
    private(set) var devices: [String] = []
    private(set) var accountShares: [AccountShare] = []
    /// Shares synced on this device by id.
    private(set) var shares: [String: LocalShare] = [:]
    /// Spaces that synced before shares existed and lie outside the library; they sync again once imported.
    private(set) var unmigrated: [String: URL] = [:]
    private(set) var statuses: [String: ShareStatus] = [:]
    /// Why a share isn't syncing, like its folder having moved away.
    private(set) var problems: [String: String] = [:]
    private(set) var lastError: String?

    /// Files above this size, in megabytes, are LFS files: never in jj's history, synced whole.
    var lfsThresholdMB: Double {
        didSet { defaults.set(lfsThresholdMB, forKey: Self.thresholdKey) }
    }

    var isRunning: Bool { node != nil }
    /// Account shares that another device syncs and this one doesn't.
    var elsewhere: [AccountShare] {
        accountShares.filter { share in shares[share.id] == nil && share.members.contains { $0 != deviceID } }
    }

    let repository: SpaceRepository

    @ObservationIgnored private var node: OpaquePointer?
    @ObservationIgnored private var dataDir: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var runtimes: [String: Runtime] = [:]
    /// Exports and merges of a share run one after another.
    @ObservationIgnored private var queues: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var publishTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var fetches: [Int64: CheckedContinuation<String?, Never>] = [:]
    @ObservationIgnored private var nextRequest: Int64 = 1
    /// `share/inside` of files open here and on another device; merges leave them to the live session.
    @ObservationIgnored private var livePaths: Set<String> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// What this device knows about a share's nodes.
    private struct Runtime {
        /// This device's current node, its ancestors and the LFS files it holds.
        var head: String?
        var ancestry: [String] = []
        var lfs: Set<String> = []
        /// The node last published as this device's head.
        var published: String?
        /// The other devices' heads.
        var heads: [String: Head] = [:]
        var working = 0
    }

    private struct Head {
        let node: String
        let name: String?
    }

    private static let sharesKey = "syncedShares"
    /// Spaces synced path by path before shares; what's left are folders outside the library.
    private static let spacesKey = "syncedSpaces"
    private static let thresholdKey = "syncLFSThresholdMB"

    /// Tests run several devices in one process, each with its own defaults and repository.
    init(defaults: UserDefaults = .standard, repository: SpaceRepository? = nil,
         deviceName: String = Host.current().localizedName ?? "Mac") {
        self.defaults = defaults
        let repository = repository ?? .shared
        self.repository = repository
        self.deviceName = deviceName
        let saved = defaults.double(forKey: Self.thresholdKey)
        lfsThresholdMB = saved > 0 ? saved : defaultLfsThreshold() / 1_048_576
        if let data = defaults.data(forKey: Self.sharesKey),
           let stored = try? JSONDecoder().decode([String: LocalShare].self, from: data) {
            shares = stored
        }
        let spaces = defaults.dictionary(forKey: Self.spacesKey) as? [String: String] ?? [:]
        for (id, path) in spaces where shares[id] == nil {
            migrate(id, from: URL(fileURLWithPath: path))
        }
        persist()
        observers = [
            NotificationCenter.default.addObserver(forName: SpaceRepository.didCommit, object: repository, queue: .main) { [weak self] note in
                let changed = note.userInfo?["changed"] as? [String] ?? []
                MainActor.assumeIsolated { self?.committed(changed) }
            },
            NotificationCenter.default.addObserver(forName: SpaceRepository.conflictsDidChange, object: repository, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatuses() }
            },
        ]
    }

    /// A space synced before shares keeps its id; it syncs as a share once it's in the library.
    private func migrate(_ id: String, from url: URL) {
        if let path = repository.relativePath(of: url) {
            shares[id] = LocalShare(path: path, kind: path.contains("/") ? .folder : .space)
            unmigrated[id] = nil
        } else {
            unmigrated[id] = url.standardizedFileURL
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shares) { defaults.set(data, forKey: Self.sharesKey) }
        defaults.set(unmigrated.mapValues(\.path), forKey: Self.spacesKey)
    }

    // MARK: - Lookups

    private var sharePaths: [SharePath] {
        shares.map { SharePath(id: $0.key, path: $0.value.path, file: $0.value.kind == .file) }
    }

    /// The share whose root is exactly `url`.
    func shareID(for url: URL) -> String? {
        guard let path = repository.relativePath(of: url) else { return nil }
        return shares.first { $0.value.path == path }?.key
    }

    func isSynced(_ url: URL) -> Bool { shareID(for: url) != nil }

    /// Whether anything in or around `root` syncs, so its edits should reach the disk quickly.
    func syncsAnything(in root: URL) -> Bool {
        guard let path = repository.relativePath(of: root) else { return false }
        return shares.values.contains { $0.path == path || $0.path.hasPrefix(path + "/") || path.hasPrefix($0.path + "/") }
    }

    /// Whether other accounts sync the share too.
    func isShared(_ url: URL) -> Bool {
        guard let id = shareID(for: url) else { return false }
        return accountShares.contains { $0.id == id && $0.shared }
    }

    func status(for url: URL) -> ShareStatus? {
        shareID(for: url).flatMap { statuses[$0] }
    }

    func url(of id: String) -> URL? {
        shares[id].map { repository.url(of: $0.path) }
    }

    /// The share holding `url` and the path inside it, as live sessions name files.
    private func place(of url: URL) -> SharePlace? {
        guard let path = repository.relativePath(of: url) else { return nil }
        return sharePlace(shares: sharePaths, path: path)
    }

    /// The space folder holding a share, which editors know as their root.
    private func spaceRoot(of id: String) -> URL? {
        guard let path = shares[id]?.path, let space = path.split(separator: "/").first else { return nil }
        return repository.url(of: String(space)).standardizedFileURL
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
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
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
        for id in shares.keys { open(id) }
        NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
    }

    func stop() {
        guard let node else { return }
        self.node = nil
        queues.values.forEach { $0.cancel() }
        queues.removeAll()
        publishTasks.values.forEach { $0.cancel() }
        publishTasks.removeAll()
        fetches.values.forEach { $0.resume(returning: nil) }
        fetches.removeAll()
        runtimes.removeAll()
        statuses.removeAll()
        connected = []
        devices = []
        accountShares = []
        deviceID = nil
        livePaths = []
        Task.detached { tws_stop(node) }
        NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
    }

    // MARK: - Shares

    /// Starts syncing a space, or any folder or file in one; the account lists it for the other devices.
    @discardableResult
    func share(_ url: URL) -> String? {
        guard let node, let path = repository.relativePath(of: url) else { return nil }
        if let id = shareID(for: url) { return id }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let kind: ShareKind = !isDir.boolValue ? .file : path.contains("/") ? .folder : .space
        let id = UUID().uuidString.lowercased()
        shares[id] = LocalShare(path: path, kind: kind)
        persist()
        tws_add_share(node, id, url.lastPathComponent, kind.rawValue, deviceName)
        schedulePublish(id, delay: 0)
        NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
        return id
    }

    /// Stops syncing here; the files stay and the other devices keep syncing.
    /// Once no device syncs the share anymore, it leaves the account.
    func stopSyncing(_ url: URL) {
        guard let id = shareID(for: url) else { return }
        stopSyncing(id: id)
    }

    func stopSyncing(id: String) {
        if let node { tws_close_share(node, id) }
        forget(id)
    }

    /// Stops a space that hasn't moved into the library yet.
    func forgetUnmigrated(_ id: String) {
        if let node { tws_close_share(node, id) }
        unmigrated[id] = nil
        persist()
    }

    /// Stops syncing a share on every device; each keeps its files.
    func removeEverywhere(_ id: String) {
        guard let node else { return }
        tws_remove_share(node, id)
        accountShares.removeAll { $0.id == id }
        forget(id)
    }

    /// Follows a space folder renamed, or imported into the library, here; nothing syncs for the move itself.
    func moved(from old: URL, to new: URL) {
        if let id = unmigrated.first(where: { $0.value.path == old.standardizedFileURL.path })?.key {
            migrate(id, from: new)
            persist()
            if shares[id] != nil { open(id) }
            NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
            return
        }
        guard let from = repository.relativePath(of: old), let to = repository.relativePath(of: new) else { return }
        var moved = false
        for (id, share) in shares {
            if share.path == from {
                shares[id]?.path = to
            } else if share.path.hasPrefix(from + "/") {
                shares[id]?.path = to + share.path.dropFirst(from.count)
            } else {
                continue
            }
            moved = true
            problems[id] = nil
        }
        guard moved else { return }
        persist()
        NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
    }

    private func forget(_ id: String) {
        defer { NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil) }
        shares[id] = nil
        runtimes[id] = nil
        statuses[id] = nil
        problems[id] = nil
        publishTasks.removeValue(forKey: id)?.cancel()
        livePaths = livePaths.filter { !$0.hasPrefix(id + "/") }
        persist()
    }

    /// Where an own-account share lands by default: spaces next to the others, under their name.
    func suggestedDestination(for share: AccountShare) -> URL {
        let name = SpaceFolders.uniqueName(share.name, in: repository.root)
        return repository.root.appendingPathComponent(name, isDirectory: share.kind != .file)
    }

    /// Starts syncing an account share at `destination` (in the library, not there yet); its files arrive after.
    func join(_ share: AccountShare, at destination: URL) -> URL? {
        guard let node, let path = destinationPath(destination, file: share.kind == .file) else { return nil }
        shares[share.id] = LocalShare(path: path, kind: share.kind == .file ? .file : path.contains("/") ? .folder : .space)
        persist()
        tws_open_share(node, share.id, deviceName)
        NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
        return destination
    }

    /// An invite link to the share; anyone holding it can sync and edit it from their account.
    func inviteLink(for url: URL) -> String? {
        guard let node, let id = shareID(for: url), let share = shares[id] else { return nil }
        let name = url.lastPathComponent
        let raw = tws_share_invite(node, id, name, share.kind.rawValue)
        defer { tws_string_free(raw) }
        // This Mac first: it's online right now, so the first join doesn't wait for the share's record.
        let hints = [deviceID].compactMap { $0 } + devices.filter { $0 != deviceID }
        let invite = SpaceInvite(id: id, name: name, secret: String(cString: raw), hints: hints, file: share.kind == .file)
        return TypewrightCore.inviteLink(invite: invite)
    }

    /// Starts syncing a share from an invite at `destination`; the account lists it for this user's other devices.
    func join(_ invite: SpaceInvite, at destination: URL) -> URL? {
        guard let node else { return nil }
        if let url = url(of: invite.id) { return url }
        guard let path = destinationPath(destination, file: invite.file) else { return nil }
        let kind: ShareKind = invite.file ? .file : path.contains("/") ? .folder : .space
        shares[invite.id] = LocalShare(path: path, kind: kind)
        persist()
        tws_join_share(node, invite.id, invite.name, kind.rawValue, invite.secret, invite.hints.joined(separator: ","), deviceName)
        NotificationCenter.default.post(name: Self.syncedSpacesDidChange, object: nil)
        return destination
    }

    /// A destination's repository path; folders are made right away, so a new space shows up before its files.
    private func destinationPath(_ destination: URL, file: Bool) -> String? {
        guard let path = repository.relativePath(of: destination) else {
            lastError = "Shares sync into Typewright's library."
            return nil
        }
        if file && !path.contains("/") {
            lastError = "A shared file goes into a space."
            return nil
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            lastError = "“\(destination.lastPathComponent)” already exists."
            return nil
        }
        do {
            let folder = file ? destination.deletingLastPathComponent() : destination
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        return path
    }

    private func open(_ id: String) {
        guard let node else { return }
        tws_open_share(node, id, deviceName)
        schedulePublish(id, delay: 0)
    }

    // MARK: - Events

    private struct Event: Decodable {
        let type: String
        var message: String?
        var peers: [String]?
        var devices: [String]?
        var shares: [Share]?
        var removed: [String]?
        var share: String?
        var space: String?
        var device: String?
        var node: String?
        var name: String?
        var path: String?
        var request: Int64?
        var ok: Bool?

        struct Share: Decodable {
            let id: String
            let name: String?
            let kind: String?
            let members: [String]?
            let shared: Bool?
        }
    }

    private func handle(_ text: String) {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(text.utf8)) else { return }
        switch event.type {
        case "status":
            connected = Set(event.peers ?? [])
            devices = event.devices ?? []
            updateStatuses()
        case "shares":
            accountShares = (event.shares ?? []).map {
                AccountShare(id: $0.id, name: $0.name ?? "Space", kind: ShareKind(rawValue: $0.kind ?? "") ?? .space,
                             members: $0.members ?? [], shared: $0.shared ?? false)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // Removed from all devices elsewhere: stop here too, keeping the files.
            for id in event.removed ?? [] where shares[id] != nil {
                if let node { tws_close_share(node, id) }
                forget(id)
            }
            updateStatuses()
        case "head":
            guard let id = event.share, let device = event.device, let node = event.node else { return }
            runtimes[id, default: Runtime()].heads[device] = Head(node: node, name: event.name)
            mergeHeads(id)
            updateStatus(id)
        case "published-node":
            if let id = event.share { updateStatus(id) }
        case "fetched":
            guard let request = event.request else { return }
            if event.ok != true { NSLog("Sync: %@", event.message ?? "fetch failed") }
            fetches.removeValue(forKey: request)?.resume(returning: event.ok == true ? event.node : nil)
        case "live":
            guard let id = event.space, let inside = event.path, let share = shares[id], let root = spaceRoot(of: id) else { return }
            let path = shareFilePath(share: SharePath(id: id, path: share.path, file: share.kind == .file), inside: inside)
            guard let space = repository.relativePath(of: root), path.hasPrefix(space + "/") else { return }
            NotificationCenter.default.post(name: Self.liveDidChange, object: root, userInfo: ["path": String(path.dropFirst(space.count + 1))])
        case "error":
            lastError = event.message
            NSLog("Sync: %@", event.message ?? "")
        default:
            break
        }
    }

    // MARK: - Nodes

    /// Commits reach the shares they touch.
    private func committed(_ changed: [String]) {
        guard isRunning, !changed.isEmpty else { return }
        for id in sharesTouched(shares: sharePaths, changed: changed) { schedulePublish(id) }
    }

    private func schedulePublish(_ id: String, delay: Double = 0.3) {
        publishTasks[id]?.cancel()
        publishTasks[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.publishTasks[id] = nil
            self.enqueue(id) { await self.publish(id) }
        }
    }

    private func enqueue(_ id: String, _ work: @escaping @MainActor () async -> Void) {
        let previous = queues[id]
        runtimes[id, default: Runtime()].working += 1
        updateStatus(id)
        queues[id] = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await work()
            guard let self else { return }
            self.runtimes[id]?.working -= 1
            self.updateStatus(id)
        }
    }

    /// Merges every head this device doesn't have yet.
    private func mergeHeads(_ id: String) {
        guard let runtime = runtimes[id], shares[id] != nil else { return }
        for (device, head) in runtime.heads where needsMerge(head: runtime.head, ancestry: runtime.ancestry, remote: head.node) {
            enqueue(id) { await self.merge(id, from: device) }
        }
    }

    private struct Manifest: Decodable {
        struct File: Decodable {
            let lfs: Bool?
            let blake3: String?
        }

        let node: String?
        let ancestry: [String]?
        let files: [String: File]?
        let unchanged: Bool?
        let error: String?
        let busy: Bool?
    }

    /// Exports the share's content as a node and publishes it unless the devices already have it.
    private func publish(_ id: String) async {
        guard let node, let share = shares[id], let dataDir else { return }
        let url = repository.url(of: share.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue == (share.kind != .file) else {
            // Exporting nothing would delete the share on every device; a moved folder is no reason for that.
            problems[id] = "“\(url.lastPathComponent)” moved or was deleted. Put it back, or stop syncing it."
            return
        }
        problems[id] = nil
        // A share just joined waits for its first node instead of publishing an empty one.
        if runtimes[id]?.head == nil, isDir.boolValue,
           ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).allSatisfy({ $0.hasPrefix(".") }) {
            return
        }
        let path = share.path
        guard let data = await repository.json({ twj_export_node($0, id, path) }),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        if let error = manifest.error {
            if manifest.busy == true { schedulePublish(id, delay: 2) }
            // Conflicts block exports until they're resolved; resolving commits and comes back here.
            else if !error.contains("unresolved conflicts") { problems[id] = error }
            return
        }
        guard let nodeID = manifest.node else { return }
        var runtime = runtimes[id] ?? Runtime()
        runtime.head = nodeID
        runtime.ancestry = manifest.ancestry ?? []
        runtime.lfs = Set((manifest.files ?? [:]).values.compactMap { $0.lfs == true ? $0.blake3 : nil })
        runtimes[id] = runtime
        if runtime.published != nodeID {
            let dir = dataDir.appendingPathComponent("tmp/\(UUID().uuidString)", isDirectory: true)
            let objects = "[\"\(nodeID)\"]"
            guard let written = await repository.json({ twj_write_objects($0, objects, dir.path) }),
                  (try? JSONDecoder().decode(Manifest.self, from: written))?.error == nil else {
                try? FileManager.default.removeItem(at: dir)
                return
            }
            let lfs: [[String: String]] = (manifest.files ?? [:]).compactMap { rel, file in
                guard file.lfs == true, let hash = file.blake3 else { return nil }
                let inside = shareFilePath(share: SharePath(id: id, path: share.path, file: share.kind == .file), inside: rel)
                return ["blake3": hash, "path": repository.url(of: inside).path]
            }
            let lfsJSON = String(data: (try? JSONSerialization.data(withJSONObject: lfs)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            tws_publish_node(node, id, String(decoding: data, as: UTF8.self), dir.path, lfsJSON)
            runtimes[id]?.published = nodeID
        }
        mergeHeads(id)
    }

    /// Fetches another device's head and merges it into the share; a clean merge is published right away.
    private func merge(_ id: String, from device: String) async {
        guard let share = shares[id], let runtime = runtimes[id], let head = runtime.heads[device], let dataDir,
              needsMerge(head: runtime.head, ancestry: runtime.ancestry, remote: head.node) else { return }
        let dir = dataDir.appendingPathComponent("tmp/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let fetched = await fetch(id, device: device, into: dir, skip: Array(runtime.lfs)),
              needsMerge(head: runtimes[id]?.head, ancestry: runtimes[id]?.ancestry ?? [], remote: fetched),
              let manifest = try? String(contentsOf: dir.appendingPathComponent("manifest.json"), encoding: .utf8)
        else { return }
        let root = spaceRoot(of: id)
        if let root { NotificationCenter.default.post(name: Self.willChangeFiles, object: root) }
        let label = head.name ?? "Other Device"
        let objects = dir.appendingPathComponent("objects").path
        guard let imported = await repository.json({ twj_import_node($0, id, manifest, objects, label) }),
              (try? JSONDecoder().decode(Manifest.self, from: imported))?.error == nil else {
            lastError = "Couldn't import a node from \(label)."
            return
        }
        let sharePath = SharePath(id: id, path: share.path, file: share.kind == .file)
        let keep = livePaths.filter { $0.hasPrefix(id + "/") }.map { shareFilePath(share: sharePath, inside: String($0.dropFirst(id.count + 1))) }
        let keepJSON = String(data: (try? JSONSerialization.data(withJSONObject: keep)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let path = share.path
        let lfs = dir.appendingPathComponent("lfs").path
        struct Merged: Decodable {
            let node: String?
            let changed: [String]?
            let conflicts: [String]?
            let error: String?
            let busy: Bool?
        }
        guard let data = await repository.json({ twj_merge_node_keeping($0, id, path, fetched, lfs, keepJSON) }),
              let merged = try? JSONDecoder().decode(Merged.self, from: data) else { return }
        if let error = merged.error {
            if merged.busy == true {
                Task { try? await Task.sleep(for: .seconds(2)); self.mergeHeads(id) }
            } else if !error.contains("unresolved conflicts") {
                // A share waiting on conflicts merges again once they're resolved.
                lastError = error
                NSLog("Sync: %@", error)
            }
            return
        }
        if !(merged.changed ?? []).isEmpty, let root {
            NotificationCenter.default.post(name: Self.didChangeFiles, object: root)
        }
        // New conflicts show up, and a peer's resolution clears them.
        if !(merged.conflicts ?? []).isEmpty || !repository.conflicted.isEmpty { await repository.refreshConflicts() }
        // Publishing exports again, on top of the merge when live files kept their own content.
        if merged.node != nil { await publish(id) }
    }

    private func fetch(_ id: String, device: String, into dir: URL, skip: [String]) async -> String? {
        guard let node else { return nil }
        let request = nextRequest
        nextRequest += 1
        let skipJSON = String(data: (try? JSONSerialization.data(withJSONObject: skip)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        return await withCheckedContinuation { continuation in
            fetches[request] = continuation
            tws_fetch_node(node, id, device, dir.path, skipJSON, request)
        }
    }

    // MARK: - Status

    private func updateStatuses() {
        for id in shares.keys { updateStatus(id) }
    }

    private func updateStatus(_ id: String) {
        guard let share = shares[id] else { return }
        let runtime = runtimes[id] ?? Runtime()
        let peers = runtime.heads.map { PeerHead(device: $0.key, node: $0.value.node, connected: connected.contains($0.key)) }
        let members = Set(accountShares.first { $0.id == id }?.members ?? []).union(runtime.heads.keys)
        let others = members.subtracting([deviceID ?? ""]).count
        let base = repository.url(of: share.path).standardizedFileURL.path
        let conflicted = repository.conflicted.contains { $0.path == base || $0.path.hasPrefix(base + "/") }
        let status = shareStatus(head: runtime.head, peers: peers, others: UInt32(others), conflicted: conflicted,
                                 working: runtime.working > 0 || publishTasks[id] != nil)
        if statuses[id] != status { statuses[id] = status }
    }

    // MARK: - Live editing

    /// Whether a file of a space can be edited live: it's in a share and syncing runs.
    func canEditLive(root: URL, path: String) -> Bool {
        isRunning && place(of: root.appendingPathComponent(path)) != nil
    }

    func liveOpen(root: URL, path: String, text: String) {
        guard let node, let place = place(of: root.appendingPathComponent(path)) else { return }
        tws_live_open(node, place.id, place.inside, text, deviceName)
    }

    func liveClose(root: URL, path: String) {
        guard let node, let place = place(of: root.appendingPathComponent(path)) else { return }
        livePaths.remove(place.id + "/" + place.inside)
        tws_live_close(node, place.id, place.inside)
    }

    /// `step` 1 undoes and 2 redoes this device's last edit of the file.
    func liveSync(root: URL, path: String, text: String, selection: NSRange, step: Int32 = 0) -> LiveResult? {
        guard let node, let place = place(of: root.appendingPathComponent(path)) else { return nil }
        let raw = tws_live_sync(node, place.id, place.inside, text, UInt32(clamping: selection.location),
                                UInt32(clamping: selection.length), step)
        defer { tws_string_free(raw) }
        guard let result = try? JSONDecoder().decode(LiveResult.self, from: Data(String(cString: raw).utf8)) else { return nil }
        let key = place.id + "/" + place.inside
        if result.peers > 0 { livePaths.insert(key) } else { livePaths.remove(key) }
        return result
    }
}
