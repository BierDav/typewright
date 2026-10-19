import Foundation

/// Symlink mirror of the project where unsaved buffers are compiled without touching the real files.
/// Folders are only turned into real directories on the way to a file that holds a buffer.
@MainActor
final class ShadowRoot {
    let root: URL
    let shadow: URL
    /// Contents written into the mirror, by relative path.
    private var written: [String: String] = [:]
    private let fm = FileManager.default

    init(root: URL, in dir: URL) {
        self.root = root
        shadow = dir.appendingPathComponent("root", isDirectory: true)
        reset()
    }

    /// Rebuilds the mirror, e.g. after files were added, removed or renamed.
    func reset() {
        try? fm.removeItem(at: shadow)
        try? fm.createDirectory(at: shadow, withIntermediateDirectories: true)
        link(contentsOf: root, into: shadow)
        written = [:]
    }

    /// Mirror location of a project file.
    func url(for file: URL) -> URL? {
        relative(file).map { shadow.appendingPathComponent($0) }
    }

    /// Makes the mirror show `buffers` for those files and the disk version for everything else.
    /// Typst rejects a main file that resolves outside the root, so it is always a real copy.
    func sync(buffers: [URL: String], main: URL) {
        var wanted: [String: String] = [:]
        for (url, text) in buffers { if let rel = relative(url) { wanted[rel] = text } }
        if let rel = relative(main), wanted[rel] == nil {
            wanted[rel] = (try? String(contentsOf: main, encoding: .utf8)) ?? ""
        }
        for rel in written.keys where wanted[rel] == nil {
            let target = shadow.appendingPathComponent(rel)
            try? fm.removeItem(at: target)
            try? fm.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent(rel))
            written[rel] = nil
        }
        for (rel, text) in wanted where written[rel] != text {
            materialize(parentOf: rel)
            let target = shadow.appendingPathComponent(rel)
            if written[rel] == nil { try? fm.removeItem(at: target) }
            try? text.write(to: target, atomically: false, encoding: .utf8)
            written[rel] = text
        }
    }

    private func relative(_ url: URL) -> String? {
        let prefix = root.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// Replaces symlinked folders on the way to `rel` with real folders of symlinks.
    private func materialize(parentOf rel: String) {
        var current = ""
        for part in rel.split(separator: "/").dropLast() {
            current += current.isEmpty ? String(part) : "/" + part
            let dir = shadow.appendingPathComponent(current)
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: dir.path)) != nil
            guard isLink || !fm.fileExists(atPath: dir.path) else { continue }
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            link(contentsOf: root.appendingPathComponent(current), into: dir)
        }
    }

    private func link(contentsOf source: URL, into dir: URL) {
        let items = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
        for name in items {
            try? fm.createSymbolicLink(at: dir.appendingPathComponent(name), withDestinationURL: source.appendingPathComponent(name))
        }
    }
}
