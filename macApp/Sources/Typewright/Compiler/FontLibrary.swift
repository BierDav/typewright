import Foundation
import Observation

/// Extra font folders for typst: per space, machine wide, and Google Fonts kept inside the app.
@MainActor @Observable
final class FontLibrary {
    static let shared = FontLibrary()

    /// Posted, debounced, whenever the folders or their fonts change.
    static let didChange = Notification.Name("FontLibraryDidChange")

    /// Folders relative to each space's root.
    var spacePaths: [String] {
        didSet { UserDefaults.standard.set(spacePaths, forKey: "fontSpacePaths"); changed() }
    }
    /// Absolute folders every space searches.
    var machinePaths: [String] {
        didSet { UserDefaults.standard.set(machinePaths, forKey: "fontMachinePaths"); changed() }
    }

    private(set) var catalog: [GoogleFont] = []
    private(set) var installed: [String] = []
    private(set) var downloads: [String: Double] = [:]
    private(set) var lastError: String?

    /// Fonts are used straight from here, never installed into the system.
    let googleDirectory = URL.applicationSupportDirectory
        .appending(path: "Typewright/fonts/google", directoryHint: .isDirectory)
    private let catalogFile = URL.applicationSupportDirectory.appending(path: "Typewright/fonts/google-catalog.json")
    @ObservationIgnored private var notifyTask: Task<Void, Never>?
    @ObservationIgnored private var isLoadingCatalog = false

    private init() {
        spacePaths = UserDefaults.standard.stringArray(forKey: "fontSpacePaths") ?? ["./fonts"]
        machinePaths = UserDefaults.standard.stringArray(forKey: "fontMachinePaths") ?? []
        refreshInstalled()
    }

    /// Existing font folders for a space, in search order: its own, the machine's, then Google Fonts.
    func directories(for root: URL) -> [URL] {
        let space = spacePaths.map { path -> URL in
            let expanded = (path as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appending(path: path)
        }
        let machine = machinePaths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        var seen = Set<String>()
        return (space + machine + [googleDirectory])
            .map(\.standardizedFileURL)
            .filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                    && seen.insert(url.path).inserted
            }
    }

    /// The space font folders as configured, whether they exist yet or not.
    func spaceFolders(for root: URL) -> [URL] {
        spacePaths.map { path in
            let expanded = (path as NSString).expandingTildeInPath
            return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appending(path: path)).standardizedFileURL
        }
    }

    /// The catalog entry for a family name in any case, as typst reports them lowercased.
    func googleFont(named name: String) -> GoogleFont? {
        let wanted = name.lowercased()
        return catalog.first { $0.family.lowercased() == wanted }
    }

    private func changed() {
        notifyTask?.cancel()
        // Typing a path shouldn't rescan fonts on every keystroke.
        notifyTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    // MARK: - Google Fonts

    struct GoogleFont: Codable, Identifiable, Hashable {
        let family: String
        let category: String?
        /// Available cuts like `400`, `400i`, `700`.
        let styles: [String]?
        var id: String { family }
    }

    private func refreshInstalled() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: googleDirectory.path)) ?? []
        installed = names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Loads the family list, from a cache younger than a week if there is one.
    func loadCatalog() async {
        guard catalog.isEmpty, !isLoadingCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        let modified = (try? catalogFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified.timeIntervalSinceNow > -7 * 24 * 3600,
           let data = try? Data(contentsOf: catalogFile),
           let cached = try? JSONDecoder().decode([GoogleFont].self, from: data),
           // Caches from before styles were stored can't drive downloads.
           cached.first?.styles != nil {
            catalog = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://fonts.google.com/metadata/fonts")!)
            let metadata = try JSONDecoder().decode(Metadata.self, from: Self.stripXSSI(data))
            catalog = metadata.familyMetadataList.map {
                GoogleFont(family: $0.family, category: $0.category, styles: $0.fonts.map { Array($0.keys) })
            }
            try? FileManager.default.createDirectory(at: catalogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(catalog).write(to: catalogFile, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Couldn't load Google Fonts: \(error.localizedDescription)"
        }
    }

    /// Downloads a Google font into `folder/<family>`, or into Typewright's own Google Fonts folder.
    func download(_ family: String, into folder: URL? = nil) async {
        guard downloads[family] == nil else { return }
        downloads[family] = 0
        defer { downloads[family] = nil }
        do {
            let files = try await cssFiles(family)
            let staging = FileManager.default.temporaryDirectory.appending(path: "Typewright-font-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            for (i, file) in files.enumerated() {
                let (location, _) = try await URLSession.shared.download(from: file.url)
                try FileManager.default.moveItem(at: location, to: staging.appending(path: file.name))
                downloads[family] = Double(i + 1) / Double(files.count)
            }
            let parent = folder ?? googleDirectory
            let target = parent.appending(path: family, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staging, to: target)
            lastError = nil
        } catch {
            lastError = "Couldn't download \(family): \(error.localizedDescription)"
        }
        refreshInstalled()
        changed()
    }

    /// One static file per cut from the CSS API. Unlike the static files in Google's download, these
    /// keep the plain family name; Inter's are named "Inter 18pt" and so on there.
    private func cssFiles(_ family: String) async throws -> [(name: String, url: URL)] {
        let styles = catalog.first { $0.family == family }?.styles ?? ["400"]
        let cuts = styles.compactMap { style -> (italic: Int, weight: Int)? in
            let italic = style.hasSuffix("i")
            return Int(italic ? String(style.dropLast()) : style).map { (italic ? 1 : 0, $0) }
        }.sorted { ($0.italic, $0.weight) < ($1.italic, $1.weight) }
        guard !cuts.isEmpty else { throw URLError(.cannotParseResponse) }
        var components = URLComponents(string: "https://fonts.googleapis.com/css2")!
        let axes = cuts.map { "\($0.italic),\($0.weight)" }.joined(separator: ";")
        components.queryItems = [URLQueryItem(name: "family", value: "\(family):ital,wght@\(axes)")]
        var request = URLRequest(url: components.url!)
        // An old user agent gets plain TrueType files without unicode-range splitting.
        request.setValue("Mozilla/4.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let css = String(decoding: data, as: UTF8.self)
        let files = Self.fontFaces(in: css).map { face in
            let stem = family.replacingOccurrences(of: " ", with: "")
            return (name: "\(stem)-\(face.weight)\(face.italic ? "Italic" : "").\(face.url.pathExtension)", url: face.url)
        }
        guard !files.isEmpty else { throw URLError(.cannotParseResponse) }
        return files
    }

    private static func fontFaces(in css: String) -> [(weight: String, italic: Bool, url: URL)] {
        css.components(separatedBy: "@font-face").dropFirst().compactMap { block in
            func value(_ key: String) -> String? {
                guard let range = block.range(of: key + ":") else { return nil }
                return block[range.upperBound...].prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
            }
            guard let src = value("src"), let open = src.range(of: "url("),
                  let close = src[open.upperBound...].firstIndex(of: ")"),
                  let url = URL(string: String(src[open.upperBound..<close])) else { return nil }
            return (value("font-weight") ?? "400", value("font-style") == "italic", url)
        }
    }

    func remove(_ family: String) {
        try? FileManager.default.removeItem(at: googleDirectory.appending(path: family, directoryHint: .isDirectory))
        refreshInstalled()
        changed()
    }

    /// Google prefixes its JSON with `)]}'` against script inclusion.
    private static func stripXSSI(_ data: Data) -> Data {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")), data.starts(with: Data(")]}'".utf8)) else { return data }
        return data[data.index(after: newline)...]
    }

    private struct Metadata: Decodable {
        struct Family: Decodable {
            let family: String
            let category: String?
            let fonts: [String: Ignored]?
        }
        struct Ignored: Decodable {}
        let familyMetadataList: [Family]
    }
}
