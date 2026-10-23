import CryptoKit
import Foundation

/// A disposable file tree cache; filesystem validation and file inspection run on a worker.
enum SpaceIndex {
    struct Snapshot: Sendable {
        let tree: [FileNode]
        let validated: Bool
    }

    struct Progress: Sendable {
        enum Phase: Sendable {
            case loading, scanning, saving
        }

        let phase: Phase
        var items = 0
        var path: String?
    }

    enum Update: Sendable {
        case progress(Progress)
        case snapshot(Snapshot)
    }

    struct Entry: Codable, Sendable {
        let name: String
        let kind: FileKind
        let modified: Date?
        let size: Int?
        let children: [Entry]?

        func node(in parent: URL) -> FileNode {
            let url = parent.appendingPathComponent(name).standardizedFileURL
            return FileNode(url: url, kind: kind, children: children?.map { $0.node(in: url) })
        }
    }

    struct Record: Codable, Sendable {
        let version: Int
        let root: String
        let entries: [Entry]

        var tree: [FileNode] { entries.map { $0.node(in: URL(fileURLWithPath: root)) } }
    }

    private static var directory: URL {
        if SpaceRepository.isTestHost {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TypewrightTests/FileIndex")
        }
        return URL.cachesDirectory.appendingPathComponent("Typewright/FileIndex")
    }

    static func updates(for root: URL, useCache: Bool, rebuild: Bool = false,
                        cacheDirectory: URL? = nil) -> AsyncStream<Update> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .utility) {
                let file = cacheFile(for: root, in: cacheDirectory ?? directory)
                continuation.yield(.progress(Progress(phase: rebuild ? .scanning : .loading)))
                let cached = rebuild ? nil : load(root: root, from: file)
                if useCache, let cached, !Task.isCancelled {
                    continuation.yield(.snapshot(Snapshot(tree: cached.tree, validated: false)))
                }
                do {
                    var count = 0
                    let record = try scan(root: root, cached: cached) { progress in
                        count = progress.items
                        continuation.yield(.progress(progress))
                    }
                    try Task.checkCancellation()
                    continuation.yield(.progress(Progress(phase: .saving, items: count)))
                    save(record, to: file)
                    continuation.yield(.snapshot(Snapshot(tree: record.tree, validated: true)))
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    static func cacheFile(for root: URL, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".plist")
    }

    static func load(root: URL, from file: URL) -> Record? {
        precondition(!Thread.isMainThread)
        guard let data = try? Data(contentsOf: file),
              let record = try? PropertyListDecoder().decode(Record.self, from: data),
              record.version == 1, record.root == root.standardizedFileURL.path else { return nil }
        return record
    }

    static func save(_ record: Record, to file: URL) {
        precondition(!Thread.isMainThread)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard !Task.isCancelled, let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func scan(root: URL, cached: Record? = nil, onProgress: @escaping (Progress) -> Void = { _ in }) throws -> Record {
        precondition(!Thread.isMainThread)
        let root = root.standardizedFileURL
        let progress = ScanProgress(root: root, report: onProgress)
        onProgress(Progress(phase: .scanning))
        let entries = try scan(root, depth: 0, cached: cached?.root == root.path ? cached?.entries ?? [] : [], progress: progress)
        onProgress(Progress(phase: .scanning, items: progress.items))
        return Record(version: 1, root: root.path, entries: entries)
    }

    private final class ScanProgress {
        private let root: String
        private let report: (Progress) -> Void
        private var lastReport = ContinuousClock.now
        private(set) var items = 0

        init(root: URL, report: @escaping (Progress) -> Void) {
            self.root = root.path + "/"
            self.report = report
        }

        func visit(_ url: URL) {
            items += 1
            let now = ContinuousClock.now
            // Throttle updates so large trees don't flood the UI thread.
            guard now - lastReport >= .milliseconds(100) else { return }
            lastReport = now
            report(Progress(phase: .scanning, items: items, path: String(url.path.dropFirst(root.count))))
        }
    }

    private static func scan(_ dir: URL, depth: Int, cached: [Entry], progress: ScanProgress) throws -> [Entry] {
        try Task.checkCancellation()
        guard depth < 8 else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .contentModificationDateKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []
        let previous = Dictionary(cached.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [Entry] = []
        for url in items {
            try Task.checkCancellation()
            progress.visit(url)
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let old = previous[url.lastPathComponent]
            let kind: FileKind
            let children: [Entry]?
            if values.isDirectory == true, values.isSymbolicLink != true {
                kind = .folder
                children = try scan(url, depth: depth + 1, cached: old?.children ?? [], progress: progress)
            } else if values.isRegularFile == true {
                if let old, old.children == nil, old.modified == values.contentModificationDate, old.size == values.fileSize {
                    kind = old.kind
                } else {
                    kind = FileKind(url: url)
                }
                children = nil
            } else {
                // Pipes, sockets and directory links must never be opened or traversed.
                continue
            }
            entries.append(Entry(name: url.lastPathComponent, kind: kind, modified: values.contentModificationDate,
                                 size: values.fileSize, children: children))
        }
        return entries.sorted { a, b in
            if (a.children == nil) != (b.children == nil) { return a.children != nil }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
