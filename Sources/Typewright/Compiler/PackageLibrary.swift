import Foundation
import Observation
import TypstBridge

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
    }

    /// A local namespace; linked ones point at a folder elsewhere.
    struct Namespace: Identifiable, Hashable {
        let name: String
        let url: URL
        let target: URL?
        let packages: [Package]
        var id: String { name }
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
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
            linkError = "“\(name)” isn't a valid namespace. Use letters, digits, - and _."
            return
        }
        guard name != "preview" else {
            linkError = "“preview” is Typst Universe's namespace."
            return
        }
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

    private func changed() {
        refresh()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
