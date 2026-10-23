import Foundation
import Observation
import TypstBridge
import TypewrightCore

/// Typst packages in the folders typst, `typst watch` and tinymist all read: the download cache and local namespaces.
@MainActor @Observable
final class PackageLibrary {
    static let shared = PackageLibrary()

    /// Posted when packages appear or go, so spaces retry failed imports.
    static let didChange = Notification.Name("PackageLibraryDidChange")

    struct Package: Identifiable, Hashable {
        let namespace: String
        let name: String
        let version: String
        let url: URL
        var id: String { spec }
        var spec: String { "@\(namespace)/\(name):\(version)" }
        /// Cloned with git, so it can be updated from its remote; linked repositories are the user's to pull.
        var isCloned: Bool {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil
                && FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
        }
    }

    /// A local namespace; linked ones point at a folder elsewhere.
    struct Namespace: Identifiable, Hashable {
        let name: String
        let url: URL
        let target: URL?
        let packages: [Package]
        var id: String { name }
        /// The whole namespace is one cloned repository of `<name>/<version>/` folders.
        var isCloned: Bool { FileManager.default.fileExists(atPath: (target ?? url).appending(path: ".git").path) }
        var canUpdate: Bool { isCloned || packages.contains(where: \.isCloned) }
    }

    /// One release in Typst Universe's package list.
    struct UniversePackage: Codable, Hashable, Identifiable {
        let name: String
        let version: String
        let description: String?
        let authors: [String]?
        let license: String?
        let repository: String?
        let updatedAt: Int?
        var id: String { "\(name):\(version)" }
        var spec: String { "@preview/\(name):\(version)" }
    }

    /// A package imported at an older version than Typst Universe has.
    struct Upgrade: Equatable {
        let spec: String
        let latest: String
        let updatedSpec: String
        let range: NSRange
    }

    /// A package's `typst.toml`, for docs while offline.
    struct Manifest {
        let name: String
        let version: String
        let description: String?
        let authors: [String]
        let license: String?
        let repository: String?
    }

    /// Where typst caches downloaded `@preview` packages.
    let cacheDirectory = URL.cachesDirectory.appending(path: "typst/packages", directoryHint: .isDirectory)
    /// Where typst looks for local packages, one folder per namespace.
    let dataDirectory = URL.applicationSupportDirectory.appending(path: "typst/packages", directoryHint: .isDirectory)

    private(set) var downloaded: [Package] = []
    private(set) var namespaces: [Namespace] = []
    private(set) var downloading: Set<String> = []
    private(set) var downloadError: String?
    private(set) var linkError: String?
    private(set) var cloning: Set<String> = []

    /// Typst Universe's package list, cached so completions, versions and docs work offline.
    private(set) var universe: [UniversePackage] = []
    /// Whether the list was fetched from the network this session; offline only uses the cache.
    private(set) var isOnline = false
    @ObservationIgnored private var universeByName: [String: [UniversePackage]] = [:]
    @ObservationIgnored private var refreshingUniverse = false

    private static let universeURL = URL(string: "https://packages.typst.org/preview/index.json")!
    private static let universeCache = URL.applicationSupportDirectory.appending(path: "Typewright/packages-index.json")

    private init() {
        refresh()
        loadUniverseCache()
    }

    func refresh() {
        downloaded = Self.packages(in: cacheDirectory.appending(path: "preview"), namespace: "preview")
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dataDirectory.path)) ?? []
        namespaces = names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let url = dataDirectory.appending(path: name, directoryHint: .isDirectory)
            var target = (try? fm.destinationOfSymbolicLink(atPath: url.path)).map {
                URL(fileURLWithPath: $0, relativeTo: dataDirectory).standardizedFileURL
            }
            // A link to a folder of package repositories finds nothing as `<name>/<version>`; it becomes kept links.
            if let folder = target, Self.manifested(Self.packages(in: url, namespace: name)).isEmpty, !Self.repositories(in: folder).isEmpty {
                try? fm.removeItem(at: url)
                Self.keepLinks(at: url, to: folder)
            }
            if let folder = Self.linkedFolder(of: url) {
                Self.keepLinks(at: url, to: folder)
                target = folder
            }
            var isDir: ObjCBool = false
            guard target != nil || fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue else { return nil }
            return Namespace(name: name, url: url, target: target, packages: Self.packages(in: url, namespace: name))
        }
    }

    // MARK: - Typst Universe

    /// Fetches Universe's package list; the cache keeps versions and docs working offline.
    func refreshUniverse() async {
        guard !refreshingUniverse else { return }
        refreshingUniverse = true
        defer { refreshingUniverse = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.universeURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let list = try JSONDecoder().decode([UniversePackage].self, from: data)
            try? FileManager.default.createDirectory(at: Self.universeCache.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: Self.universeCache, options: .atomic)
            setUniverse(list)
            isOnline = true
        } catch {
            isOnline = false
        }
    }

    private func loadUniverseCache() {
        guard let data = try? Data(contentsOf: Self.universeCache),
              let list = try? JSONDecoder().decode([UniversePackage].self, from: data) else { return }
        setUniverse(list)
    }

    private func setUniverse(_ list: [UniversePackage]) {
        universe = list
        universeByName = Dictionary(grouping: list, by: \.name).mapValues { entries in
            entries.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        }
    }

    /// Every release, newest first per package, for completing imports and their versions.
    var universeSpecs: [String] {
        universeByName.keys.sorted().flatMap { universeByName[$0]?.map(\.spec) ?? [] }
    }

    func universePackage(for spec: String) -> UniversePackage? {
        guard let parts = Self.parts(of: spec), parts.namespace == "preview" else { return nil }
        return universeByName[parts.name]?.first { $0.version == parts.version }
    }

    /// The newest release Universe lists, or the newest local copy when the list isn't available.
    func latestVersion(namespace: String, name: String) -> String? {
        if namespace == "preview", let newest = universeByName[name]?.first?.version { return newest }
        return localPackages(namespace: namespace, name: name).map(\.version)
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Every version in Universe and on disk, newest first.
    func versions(namespace: String, name: String) -> [String] {
        var versions = Set(localPackages(namespace: namespace, name: name).map(\.version))
        if namespace == "preview" { versions.formUnion(universeByName[name]?.map(\.version) ?? []) }
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    private func localPackages(namespace: String, name: String) -> [Package] {
        let downloaded = namespace == "preview" ? self.downloaded.filter { $0.name == name } : []
        let local = namespaces.first { $0.name == namespace }?.packages.filter { $0.name == name } ?? []
        return downloaded + local
    }

    /// The spec from a completion's label, which tinymist quotes.
    static func spec(in label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return parts(of: trimmed) != nil ? trimmed : nil
    }

    /// `@namespace/name` and its version, when written.
    static func parts(of spec: String) -> (namespace: String, name: String, version: String?)? {
        guard let match = specMatch(spec), let namespace = group(match, 1, in: spec),
              let name = group(match, 2, in: spec) else { return nil }
        return (namespace, name, group(match, 3, in: spec))
    }

    /// Markdown docs for a package, built from the cached list and the package's `typst.toml` so they work offline.
    func documentation(for spec: String) -> String? {
        guard let parts = Self.parts(of: spec),
              let version = parts.version ?? latestVersion(namespace: parts.namespace, name: parts.name) else { return nil }
        let full = "@\(parts.namespace)/\(parts.name):\(version)"
        let entry = universePackage(for: full)
        let manifest = packageFolder(namespace: parts.namespace, name: parts.name, version: version)
            .flatMap(Self.manifest(at:))
        var lines: [String] = []
        if parts.namespace == "preview",
           let page = URL(string: "https://typst.app/universe/package/\(parts.name)") {
            var links = ["[Universe](\(page.absoluteString))"]
            if let repository = entry?.repository ?? manifest?.repository, let url = URL(string: repository) {
                links.append("[Repository](\(url.absoluteString))")
            }
            lines.append(links.joined(separator: " | "))
        }
        // Offline without a cached list, don't claim a version is the newest.
        let newest = parts.namespace == "preview"
            ? universeByName[parts.name]?.first?.version : latestVersion(namespace: parts.namespace, name: parts.name)
        lines.append("**Package:** `\(full)`")
        if let newest {
            lines.append(newest == version ? "**Up to date** (latest version)" : "**Latest:** `\(newest)`")
        }
        let authors = entry?.authors ?? manifest?.authors ?? []
        if !authors.isEmpty { lines.append("**Authors:** \(authors.joined(separator: ", "))") }
        if let description = entry?.description ?? manifest?.description, !description.isEmpty {
            lines.append("**Description:** \(description)")
        }
        if let license = entry?.license ?? manifest?.license, !license.isEmpty {
            lines.append("**License:** \(license)")
        }
        if let updated = entry?.updatedAt { lines.append("**Updated:** \(Self.date(updated))") }
        let releases = versions(namespace: parts.namespace, name: parts.name)
        if releases.count > 1 {
            lines.append("**Available Versions (\(releases.count))**")
            let details = parts.namespace == "preview" ? universeByName[parts.name] ?? [] : []
            for release in releases {
                let date = details.first { $0.version == release }?.updatedAt.map { " / \(Self.date($0))" } ?? ""
                lines.append("- \(release == newest ? "**\(release)**" : release)\(date)")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private func packageFolder(namespace: String, name: String, version: String) -> URL? {
        if let local = localPackages(namespace: namespace, name: name).first(where: { $0.version == version }) {
            return local.url
        }
        let base = namespace == "preview" ? cacheDirectory.appending(path: "preview") : dataDirectory.appending(path: namespace)
        let url = base.appending(path: "\(name)/\(version)", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.appending(path: "typst.toml").path) ? url : nil
    }

    /// Packages imported at a version older than the one `latest` names.
    static func upgrades(in text: String, latest: (String) -> String?) -> [Upgrade] {
        let s = text as NSString
        return upgradePattern.matches(in: text, range: NSRange(location: 0, length: s.length)).compactMap { match in
            guard let name = group(match, 1, in: text), let version = group(match, 2, in: text),
                  let newest = latest(name), newest != version else { return nil }
            return Upgrade(spec: s.substring(with: match.range), latest: newest,
                           updatedSpec: "@preview/\(name):\(newest)", range: match.range)
        }
    }

    static func manifest(at folder: URL) -> Manifest? {
        guard let toml = try? String(contentsOf: folder.appending(path: "typst.toml"), encoding: .utf8),
              let core = packageManifest(toml: toml) else { return nil }
        return Manifest(name: core.name, version: core.version,
                        description: tomlString("description", in: toml),
                        authors: tomlStrings("authors", in: toml) ?? tomlString("authors", in: toml).map { [$0] } ?? [],
                        license: tomlString("license", in: toml),
                        repository: tomlString("repository", in: toml))
    }

    private static let specPattern = try! NSRegularExpression(
        pattern: #"^@([A-Za-z_][A-Za-z0-9_-]*)/([A-Za-z0-9_-]+)(?::([A-Za-z0-9_.-]+))?$"#)
    private static let upgradePattern = try! NSRegularExpression(
        pattern: #"@preview/([A-Za-z0-9_-]+):([A-Za-z0-9_.-]+)"#)

    private static func specMatch(_ spec: String) -> NSTextCheckingResult? {
        specPattern.firstMatch(in: spec, range: NSRange(location: 0, length: (spec as NSString).length))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        let range = match.range(at: index)
        return range.location == NSNotFound ? nil : (text as NSString).substring(with: range)
    }

    private static func tomlString(_ key: String, in toml: String) -> String? {
        let pattern = "(?m)^\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: toml, range: NSRange(location: 0, length: (toml as NSString).length)) else {
            return nil
        }
        return group(match, 1, in: toml)
    }

    private static func tomlStrings(_ key: String, in toml: String) -> [String]? {
        let pattern = "(?m)^\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*\\[([^\\]]*)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: toml, range: NSRange(location: 0, length: (toml as NSString).length)),
              let inner = group(match, 1, in: toml),
              let quotes = try? NSRegularExpression(pattern: #""([^"]*)""#) else { return nil }
        return quotes.matches(in: inner, range: NSRange(location: 0, length: (inner as NSString).length))
            .compactMap { group($0, 1, in: inner) }
    }

    private static let universeDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func date(_ timestamp: Int) -> String {
        universeDate.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    /// `<dir>/<name>/<version>` folders.
    private static func packages(in dir: URL, namespace: String) -> [Package] {
        let fm = FileManager.default
        func folders(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.filter {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.appending(path: $0).path, isDirectory: &isDir) && isDir.boolValue
            }
        }
        return folders(dir).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.flatMap { name in
            let versions = folders(dir.appending(path: name))
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            return versions.map { Package(namespace: namespace, name: name, version: $0,
                                          url: dir.appending(path: "\(name)/\($0)", directoryHint: .isDirectory)) }
        }
    }

    /// Downloads `@preview/name:version`, or the newest version without one; returns whether it worked.
    @discardableResult
    func download(_ spec: String) async -> Bool {
        var spec = spec.trimmingCharacters(in: .whitespaces)
        if !spec.isEmpty, !spec.hasPrefix("@") { spec = "@preview/" + spec }
        guard !spec.isEmpty, !downloading.contains(spec) else { return false }
        downloading.insert(spec)
        downloadError = nil
        let request = spec
        let result = await Task.detached {
            let raw = tw_package_download(request)
            defer { tw_string_free(raw) }
            return String(cString: raw)
        }.value
        downloading.remove(spec)
        guard result.hasPrefix("ok:") else {
            downloadError = String(result.drop { $0 != ":" }.dropFirst())
            return false
        }
        changed()
        return true
    }

    func remove(_ package: Package) {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: package.url)
            // Drop the package's folder once its last version is gone.
            let parent = package.url.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: parent.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
                try? fm.removeItem(at: parent)
            }
        } catch {
            downloadError = error.localizedDescription
        }
        changed()
    }

    /// Marks a namespace folder whose `<name>/<version>` links Typewright keeps, holding the linked folder's path.
    private static let linkMarker = ".typewright-link"

    /// The folder a kept namespace links, from its marker.
    private static func linkedFolder(of namespace: URL) -> URL? {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: namespace.path)) == nil,
              let path = try? String(contentsOf: namespace.appending(path: linkMarker), encoding: .utf8) else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// Packages that are ones, with a `typst.toml`, rather than any folder two levels down.
    private static func manifested(_ packages: [Package]) -> [Package] {
        packages.filter { FileManager.default.fileExists(atPath: $0.url.appending(path: "typst.toml").path) }
    }

    /// Package repositories with a `typst.toml` at their root: `folder` itself and its subfolders, by name and version.
    private static func repositories(in folder: URL) -> [(name: String, version: String, url: URL)] {
        let fm = FileManager.default
        let candidates = [folder] + ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        return candidates.compactMap { url in
            guard let toml = try? String(contentsOf: url.appending(path: "typst.toml"), encoding: .utf8),
                  let manifest = packageManifest(toml: toml) else { return nil }
            return (manifest.name, manifest.version, url)
        }
    }

    /// Makes `namespace` a folder of `<name>/<version>` links into `folder`: its package repositories by their
    /// `typst.toml`, and the versions of its `<name>/<version>/` folders; redone on refresh, so version bumps show up.
    private static func keepLinks(at namespace: URL, to folder: URL) {
        let fm = FileManager.default
        var wanted: [String: URL] = [:]
        for package in manifested(packages(in: folder, namespace: "")) { wanted["\(package.name)/\(package.version)"] = package.url }
        for repo in repositories(in: folder) { wanted["\(repo.name)/\(repo.version)"] = repo.url }
        try? fm.createDirectory(at: namespace, withIntermediateDirectories: true)
        try? (folder.path + "\n").write(to: namespace.appending(path: linkMarker), atomically: true, encoding: .utf8)
        // Only links are removed, never what they point at.
        for name in (try? fm.contentsOfDirectory(atPath: namespace.path)) ?? [] where !name.hasPrefix(".") {
            let dir = namespace.appending(path: name)
            for version in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let link = dir.appending(path: version)
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
                if wanted["\(name)/\(version)"]?.path != destination { try? fm.removeItem(at: link) }
            }
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
        }
        for (path, target) in wanted {
            let link = namespace.appending(path: path)
            guard (try? fm.attributesOfItem(atPath: link.path)) == nil else { continue }
            try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }

    /// Registers `folder` as `@namespace/…` by linking it into typst's local package folder.
    func link(_ folder: URL, as namespace: String) {
        let name = namespace.trimmingCharacters(in: .whitespaces)
        linkError = nil
        guard validate(namespace: name) else { return }
        let link = dataDirectory.appending(path: name)
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: link.path)) == nil else {
            linkError = "The namespace “\(name)” already exists."
            return
        }
        do {
            try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            // typst only reads `<name>/<version>/`; package repositories (a `typst.toml` at their root) get links in that shape.
            if Self.repositories(in: folder).isEmpty {
                try fm.createSymbolicLink(at: link, withDestinationURL: folder)
            } else {
                Self.keepLinks(at: link, to: folder)
            }
        } catch {
            linkError = error.localizedDescription
        }
        changed()
    }

    /// Forgets a linked namespace; the folder it points at stays.
    func unlink(_ namespace: Namespace) {
        guard namespace.target != nil else { return }
        do { try FileManager.default.removeItem(at: namespace.url) } catch { linkError = error.localizedDescription }
        changed()
    }

    // MARK: - Cloning

    /// Clones a GitHub repository (`owner/repo` or a link) into `@namespace`: a package repository with a `typst.toml`
    /// becomes `<name>/<version>/`, one of `<name>/<version>/` folders becomes the whole namespace.
    @discardableResult
    func clone(_ input: String, into namespace: String, replacing: Bool = false) async -> Bool {
        linkError = nil
        guard let url = packageCloneUrl(input: input) else {
            linkError = "“\(input)” isn't a GitHub repository. Enter owner/repo or a link to it."
            return false
        }
        let name = namespace.trimmingCharacters(in: .whitespaces)
        guard validate(namespace: name), !cloning.contains(url) else { return false }
        cloning.insert(url)
        defer { cloning.remove(url) }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "Typewright-package-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let repo = staging.appending(path: "repo", directoryHint: .isDirectory)
        if let error = await Self.git(["clone", "--depth", "1", "--quiet", url, repo.path]) {
            linkError = "Couldn't clone \(url): \(error)"
            return false
        }
        let target: URL
        if let toml = try? String(contentsOf: repo.appending(path: "typst.toml"), encoding: .utf8) {
            guard let manifest = packageManifest(toml: toml) else {
                linkError = "The repository's typst.toml has no valid package name and version."
                return false
            }
            target = dataDirectory.appending(path: "\(name)/\(manifest.name)/\(manifest.version)", directoryHint: .isDirectory)
        } else if !Self.packages(in: repo, namespace: name).isEmpty {
            target = dataDirectory.appending(path: name, directoryHint: .isDirectory)
        } else {
            linkError = "The repository has no typst.toml, nor packages as <name>/<version>/ folders."
            return false
        }
        do {
            if (try? fm.attributesOfItem(atPath: target.path)) != nil {
                guard replacing else {
                    linkError = "\(target.path.replacingOccurrences(of: dataDirectory.path + "/", with: "@")) already exists."
                    return false
                }
                try fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: repo, to: target)
        } catch {
            linkError = error.localizedDescription
            return false
        }
        changed()
        return true
    }

    /// Pulls a cloned namespace, and fetches every cloned package's newest version next to the old ones.
    func update(_ namespace: Namespace) async {
        linkError = nil
        if namespace.isCloned {
            if let error = await Self.git(["-C", (namespace.target ?? namespace.url).path, "pull", "--ff-only", "--quiet"]) {
                linkError = "Couldn't update @\(namespace.name): \(error)"
            }
            return changed()
        }
        for package in namespace.packages where package.isCloned {
            guard let remote = await Self.gitOutput(["-C", package.url.path, "remote", "get-url", "origin"]) else { continue }
            await clone(remote, into: namespace.name, replacing: true)
        }
    }

    private func validate(namespace name: String) -> Bool {
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
            linkError = "“\(name)” isn't a valid namespace. Use letters, digits, - and _."
            return false
        }
        guard name != "preview" else {
            linkError = "“preview” is Typst Universe's namespace."
            return false
        }
        return true
    }

    /// Runs git without ever asking for credentials; returns its error output on failure.
    private static func git(_ arguments: [String]) async -> String? {
        await run(arguments).error
    }

    private static func gitOutput(_ arguments: [String]) async -> String? {
        let result = await run(arguments)
        return result.error == nil ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private static func run(_ arguments: [String]) async -> (output: String, error: String?) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return ("", error.localizedDescription) }
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return (output, nil) }
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return (output, text.isEmpty ? "git exited with status \(process.terminationStatus)." : text)
        }.value
    }

    private func changed() {
        refresh()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
