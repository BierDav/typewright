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
        /// Cloned with git, so it can be updated from its remote.
        var isCloned: Bool { FileManager.default.fileExists(atPath: url.appending(path: ".git").path) }
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

    private init() {
        refresh()
    }

    func refresh() {
        downloaded = Self.packages(in: cacheDirectory.appending(path: "preview"), namespace: "preview")
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dataDirectory.path)) ?? []
        namespaces = names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let url = dataDirectory.appending(path: name, directoryHint: .isDirectory)
            let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)).map {
                URL(fileURLWithPath: $0, relativeTo: dataDirectory).standardizedFileURL
            }
            var isDir: ObjCBool = false
            guard target != nil || fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue else { return nil }
            return Namespace(name: name, url: url, target: target, packages: Self.packages(in: url, namespace: name))
        }
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
            try fm.createSymbolicLink(at: link, withDestinationURL: folder)
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
        guard let url = PackageRepos.shared.cloneURL(input: input) else {
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
            guard let manifest = PackageRepos.shared.manifest(toml: toml) else {
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
