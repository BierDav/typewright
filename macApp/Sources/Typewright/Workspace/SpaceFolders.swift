import AppKit

/// Space folders in the repository: creating, importing and trashing them. Pure file operations, so tests run on temp dirs.
enum SpaceFolders {
    enum ImportError: LocalizedError {
        case insideRepository
        case containsRepository

        var errorDescription: String? {
            switch self {
            case .insideRepository: "The folder is already a space."
            case .containsRepository: "The folder contains Typewright's spaces."
            }
        }
    }

    /// The repository's top-level folders; hidden ones like `.jj` aren't spaces.
    static func spaces(in root: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        .map(\.standardizedFileURL)
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// `name`, or `name 2`, `name 3`… when taken in `dir` (case-insensitively, like APFS).
    static func uniqueName(_ name: String, in dir: URL) -> String {
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }

    /// Makes a new, empty space folder.
    static func create(named name: String, in root: URL) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(uniqueName(clean.isEmpty ? "Untitled Space" : clean, in: root), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.standardizedFileURL
    }

    /// Copies `source` into `root` as a new space. With `replace`, the original goes to the Trash and a link to the copy
    /// takes its place, so it's still found where it was; nothing changes if any step fails.
    static func importFolder(_ source: URL, into root: URL, replace: Bool,
                             trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> URL {
        let fm = FileManager.default
        let source = source.standardizedFileURL
        let resolved = source.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        if resolved == base || base.hasPrefix(resolved + "/") { throw ImportError.containsRepository }
        if resolved.hasPrefix(base + "/") { throw ImportError.insideRepository }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(uniqueName(source.lastPathComponent, in: root), isDirectory: true)
            .standardizedFileURL
        try fm.copyItem(at: URL(fileURLWithPath: resolved), to: target)
        guard replace else { return target }
        do {
            try trash(source)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        try fm.createSymbolicLink(at: source, withDestinationURL: target)
        return target
    }

    /// Keeps Finder's metadata out of the history; jj reads the repository's top-level `.gitignore`.
    static func prepareRepository(_ root: URL) {
        let ignore = root.appendingPathComponent(".gitignore")
        guard !FileManager.default.fileExists(atPath: ignore.path) else { return }
        try? ".DS_Store\n".write(to: ignore, atomically: true, encoding: .utf8)
    }

    /// Whether `url` is a symlink, without following it.
    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

/// A link (symlink) somewhere in the user's folders to a space or an item in it.
struct SpaceLink: Codable, Equatable, Identifiable {
    /// Where the link is.
    var path: String
    /// What it points to.
    var target: String
    /// Bookmark of the link's folder, which follows that folder when it's moved or renamed.
    var folder: Data?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// The links made with "Link to…" and by imports, kept so renames and deletions can carry them along.
@MainActor
final class SpaceLinks {
    static let shared = SpaceLinks()

    private(set) var links: [SpaceLink]
    private let defaults: UserDefaults
    private static let key = "spaceLinks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([SpaceLink].self, from: $0) } ?? []
        links = saved
        refresh()
    }

    /// Links to exactly `item`.
    func links(to item: URL) -> [SpaceLink] {
        let path = item.standardizedFileURL.path
        return links.filter { $0.target == path }
    }

    /// Makes a symlink at `location` to `item`, replacing nothing.
    @discardableResult
    func create(to item: URL, at location: URL) throws -> SpaceLink {
        let location = location.standardizedFileURL
        try FileManager.default.createSymbolicLink(at: location, withDestinationURL: item.standardizedFileURL)
        return record(location, to: item)
    }

    /// Remembers a link made elsewhere, like by an import.
    @discardableResult
    func record(_ location: URL, to item: URL) -> SpaceLink {
        let location = location.standardizedFileURL
        let folder = try? location.deletingLastPathComponent().bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let link = SpaceLink(path: location.path, target: item.standardizedFileURL.path, folder: folder)
        links.removeAll { $0.path == link.path }
        links.append(link)
        save()
        return link
    }

    /// Deletes the link itself; the item stays.
    func remove(_ link: SpaceLink) {
        if SpaceFolders.isLink(link.url) { try? FileManager.default.removeItem(at: link.url) }
        links.removeAll { $0.path == link.path }
        save()
    }

    /// Points links into `old` at `new`. A link named like the renamed item takes its new name too.
    func moved(from old: URL, to new: URL) {
        let old = old.standardizedFileURL.path
        let new = new.standardizedFileURL.path
        let fm = FileManager.default
        var changed = false
        for (index, link) in links.enumerated() {
            let target: String
            if link.target == old { target = new } else if link.target.hasPrefix(old + "/") {
                target = new + link.target.dropFirst(old.count)
            } else { continue }
            var location = link.url
            guard SpaceFolders.isLink(location) else { continue }
            try? fm.removeItem(at: location)
            let renamed = location.deletingLastPathComponent().appendingPathComponent((new as NSString).lastPathComponent)
            if link.target == old, location.lastPathComponent == (old as NSString).lastPathComponent,
               !fm.fileExists(atPath: renamed.path), !SpaceFolders.isLink(renamed) {
                location = renamed
            }
            try? fm.createSymbolicLink(atPath: location.path, withDestinationPath: target)
            links[index].path = location.standardizedFileURL.path
            links[index].target = target
            changed = true
        }
        if changed { save() }
    }

    /// Drops the links into an item that's gone to the Trash; they would only dangle.
    func removed(_ item: URL) {
        let path = item.standardizedFileURL.path
        for link in links where link.target == path || link.target.hasPrefix(path + "/") { remove(link) }
    }

    /// Follows moved folders and forgets links that were deleted or replaced.
    func refresh() {
        var updated: [SpaceLink] = []
        for var link in links {
            if let folder = link.folder {
                var stale = false
                if let dir = try? URL(resolvingBookmarkData: folder, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) {
                    link.path = dir.appendingPathComponent(link.url.lastPathComponent).standardizedFileURL.path
                    if stale {
                        link.folder = try? dir.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    }
                }
            }
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            guard let destination,
                  URL(fileURLWithPath: destination).standardizedFileURL.path == link.target else { continue }
            updated.append(link)
        }
        if updated != links {
            links = updated
            save()
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(links), forKey: Self.key)
    }
}
