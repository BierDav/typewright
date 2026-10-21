import Foundation
import Observation
import TypewrightCore

struct TypstRelease: Codable, Hashable, Identifiable {
    let version: String
    let assetURL: URL
    var id: String { version }
}

/// Where compiles run: in process, or through a typst CLI binary.
enum ActiveCompiler: Equatable {
    case builtin
    case binary(URL)
}

/// Selects the built-in compiler or a downloaded or system typst CLI.
@MainActor @Observable
final class CompilerManager {
    static let shared = CompilerManager()

    static let builtin = "builtin"
    static let automatic = "automatic"
    static let system = "system"

    private(set) var releases: [TypstRelease] = []
    private(set) var installed: [String] = []
    private(set) var downloads: [String: Double] = [:]
    private(set) var lastError: String?
    let systemBinary: URL?

    var selection: String {
        didSet { UserDefaults.standard.set(selection, forKey: "compilerSelection") }
    }

    private let directory: URL
    private var observations: [URL: NSKeyValueObservation] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Typewright/compilers", isDirectory: true)
        selection = UserDefaults.standard.string(forKey: "compilerSelection") ?? Self.builtin
        systemBinary = ["/opt/homebrew/bin/typst", "/usr/local/bin/typst"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        releases = (try? JSONDecoder().decode([TypstRelease].self, from: Data(contentsOf: cacheFile))) ?? []
        scanInstalled()
    }

    var latestRelease: TypstRelease? { releases.first }

    var active: ActiveCompiler? {
        if selection == Self.builtin { return .builtin }
        return activeBinary.map(ActiveCompiler.binary)
    }

    /// External binary used for compiling, if one is selected and available.
    var activeBinary: URL? {
        switch selection {
        case Self.builtin: return nil
        case Self.system: return systemBinary
        case Self.automatic:
            guard let newest = installed.first else { return nil }
            return binary(for: newest)
        default:
            return installed.contains(selection) ? binary(for: selection) : nil
        }
    }

    var activeDescription: String {
        switch selection {
        case Self.builtin: return "Typst \(BuiltinCompiler.version)"
        case Self.system: return "System typst"
        case Self.automatic: return installed.first.map { "Typst \($0)" } ?? "No compiler"
        default: return "Typst \(selection)"
        }
    }

    func binary(for version: String) -> URL {
        directory.appendingPathComponent(version).appendingPathComponent("typst")
    }

    /// Fetches releases and installs the latest typst on first launch.
    func setUp() async {
        await refreshReleases()
        if installed.isEmpty, selection == Self.automatic, let latest = latestRelease {
            await download(latest)
        }
    }

    func refreshReleases() async {
        do {
            let url = URL(string: "https://api.github.com/repos/typst/typst/releases?per_page=100")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let fetched = Self.pickReleases(from: try JSONDecoder().decode([GitHubRelease].self, from: data))
            guard !fetched.isEmpty else { return }
            releases = fetched
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(fetched).write(to: cacheFile)
        } catch {
            lastError = "Could not load typst releases: \(error.localizedDescription)"
        }
    }

    func download(_ release: TypstRelease) async {
        guard downloads[release.version] == nil else { return }
        downloads[release.version] = 0
        defer {
            downloads[release.version] = nil
            observations[release.assetURL] = nil
        }
        lastError = nil
        do {
            let archive = try await fetch(release.assetURL) { [weak self] p in
                Task { @MainActor in self?.downloads[release.version] = p }
            }
            let target = directory.appendingPathComponent(release.version, isDirectory: true)
            try await Task.detached { try Self.install(archive: archive, into: target) }.value
            scanInstalled()
        } catch {
            lastError = "Download of typst \(release.version) failed: \(error.localizedDescription)"
        }
    }

    func remove(_ version: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(version))
        if selection == version { selection = Self.automatic }
        scanInstalled()
    }

    // MARK: - Internals

    private var cacheFile: URL { directory.appendingPathComponent("releases.json") }

    private func scanInstalled() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        installed = names
            .filter { FileManager.default.isExecutableFile(atPath: binary(for: $0).path) }
            .sorted { Self.compare($0, $1) }
    }

    private func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error { return cont.resume(throwing: error) }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return cont.resume(throwing: URLError(.badServerResponse))
                }
                // The temp file is deleted when this handler returns.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.xz")
                do {
                    try FileManager.default.moveItem(at: tmp, to: kept)
                    cont.resume(returning: kept)
                } catch { cont.resume(throwing: error) }
            }
            observations[url] = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }

    private nonisolated static func install(archive: URL, into target: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: archive)
        }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", archive.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }

        let found = fm.enumerator(at: staging, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "typst" }
        guard let found else { throw CocoaError(.fileNoSuchFile) }

        let binary = target.appendingPathComponent("typst")
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.moveItem(at: found, to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    // MARK: - Release selection

    struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let prerelease: Bool
        let assets: [Asset]
    }

    nonisolated static var assetName: String {
        #if arch(arm64)
        "typst-aarch64-apple-darwin.tar.xz"
        #else
        "typst-x86_64-apple-darwin.tar.xz"
        #endif
    }

    /// Newest patch of each minor version since 0.11, newest first.
    nonisolated static func pickReleases(from all: [GitHubRelease]) -> [TypstRelease] {
        let releases = all.map { r in
            TypewrightCore.GitHubRelease(tag: r.tag_name, prerelease: r.prerelease, assets: r.assets.map {
                ReleaseAsset(name: $0.name, url: $0.browser_download_url.absoluteString)
            })
        }
        return pickTypstReleases(all: releases, assetName: assetName).compactMap { r in
            URL(string: r.assetUrl).map { TypstRelease(version: r.version, assetURL: $0) }
        }
    }

    /// True if `a` is newer than `b`.
    nonisolated static func compare(_ a: String, _ b: String) -> Bool {
        isNewerVersion(a: a, b: b)
    }
}
