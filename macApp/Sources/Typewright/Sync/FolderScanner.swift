import CoreServices
import Foundation
import IrohBridge
import TypewrightCore

/// Walks a synced space like git would: `.gitignore` rules apply, ignored folders aren't entered,
/// symlinks are skipped. Hashes are cached by size and modification date, so rescans are cheap.
final class FolderScanner: @unchecked Sendable {
    struct Result {
        let files: [String: LocalFile]
        let ignore: IgnoreRules
    }

    private struct Cached {
        let size: Int
        let modified: Date
        let hash: String
        let isText: Bool
    }

    private var cache: [String: Cached] = [:]
    private let lock = NSLock()

    func scan(_ root: URL) -> Result {
        let ignore = IgnoreRules()
        var files: [String: LocalFile] = [:]
        walk(root, relative: "", ignore: ignore, into: &files)
        return Result(files: files, ignore: ignore)
    }

    /// The current state of one file, or nil if it's missing or not a regular file.
    func file(_ root: URL, path: String) -> LocalFile? {
        let url = root.appendingPathComponent(path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
        return describe(url, path: path, values: values)
    }

    /// Rules of all `.gitignore` files, without hashing anything.
    func ignoreRules(_ root: URL) -> IgnoreRules {
        let ignore = IgnoreRules()
        func visit(_ dir: URL, _ relative: String) {
            if let text = try? String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8) {
                ignore.add(dir: relative, content: text)
            }
            let items = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
            for url in items {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let path = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
                if !ignore.matches(path: path, isDir: true) { visit(url, path) }
            }
        }
        visit(root, "")
        return ignore
    }

    private func walk(_ dir: URL, relative: String, ignore: IgnoreRules, into files: inout [String: LocalFile]) {
        if let text = try? String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8) {
            ignore.add(dir: relative, content: text)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        for url in items {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let path = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
            if values.isDirectory == true {
                if !ignore.matches(path: path, isDir: true) { walk(url, relative: path, ignore: ignore, into: &files) }
            } else if values.isRegularFile == true, !ignore.matches(path: path, isDir: false),
                      let file = describe(url, path: path, values: values) {
                files[path] = file
            }
        }
    }

    private func describe(_ url: URL, path: String, values: URLResourceValues) -> LocalFile? {
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate ?? .distantPast
        lock.lock()
        let cached = cache[url.path]
        lock.unlock()
        if let cached, cached.size == size, cached.modified == modified {
            return LocalFile(path: path, hash: cached.hash, size: Double(size), isText: cached.isText)
        }
        guard let raw = tws_hash_file(url.path) else { return nil }
        let hash = String(cString: raw)
        tws_string_free(raw)
        // Kinds like PDF, Office and images, and contents that sniff as binary, are never diffed.
        let isText = FileKind(url: url).isEditable
        lock.lock()
        cache[url.path] = Cached(size: size, modified: modified, hash: hash, isText: isText)
        lock.unlock()
        return LocalFile(path: path, hash: hash, size: Double(size), isText: isText)
    }
}

/// Reports changes anywhere below a folder, coalesced by FSEvents.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onPaths: ([String]) -> Void

    convenience init(_ url: URL, onChange: @escaping () -> Void) {
        self.init(url) { (_: [String]) in onChange() }
    }

    /// Reports the changed paths, so callers can skip their own bookkeeping folders.
    init(_ url: URL, onPaths: @escaping ([String]) -> Void) {
        self.onPaths = onPaths
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onPaths(list)
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
