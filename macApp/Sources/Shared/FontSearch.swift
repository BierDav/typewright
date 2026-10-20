import Foundation

/// The folders typst searches for fonts before the system's; shared with the Quick Look extension.
enum FontSearch {
    /// The user's real home; a sandboxed extension's `NSHomeDirectory()` is its container.
    static let home: URL = {
        guard let dir = getpwuid(getuid())?.pointee.pw_dir else { return URL(fileURLWithPath: NSHomeDirectory()) }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }()

    static let support = home.appending(path: "Library/Application Support/Typewright", directoryHint: .isDirectory)
    /// Google Fonts are used straight from here, never installed into the system.
    static let googleDirectory = support.appending(path: "fonts/google", directoryHint: .isDirectory)
    /// The configured folders, written by the app since the extension can't read its defaults.
    static let settingsFile = support.appending(path: "fonts/paths.json")

    struct Settings: Codable, Equatable {
        /// Relative ones are looked up in the starting folder and every folder above it.
        var space = ["./fonts"]
        var machine: [String] = []
    }

    static func loadSettings() -> Settings {
        (try? Data(contentsOf: settingsFile)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    static func save(_ settings: Settings) {
        guard settings != loadSettings(), let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: settingsFile, options: .atomic)
    }

    /// `~` is the real home, also inside the sandbox.
    static func expand(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home.path + path.dropFirst()
    }

    /// Existing font folders in search order: relative paths from `folder` upwards, so the nearest wins,
    /// then absolute ones, the machine's, and Google Fonts.
    static func directories(_ settings: Settings, from folder: URL) -> [URL] {
        var ancestors: [URL] = []
        var dir = folder.standardizedFileURL
        while true {
            ancestors.append(dir)
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { break }
            dir = parent
        }
        let space = settings.space.flatMap { path -> [URL] in
            let expanded = expand(path)
            if expanded.hasPrefix("/") { return [URL(fileURLWithPath: expanded)] }
            return ancestors.map { $0.appending(path: path) }
        }
        let machine = settings.machine.map { URL(fileURLWithPath: expand($0)) }
        var seen = Set<String>()
        return (space + machine + [googleDirectory])
            .map(\.standardizedFileURL)
            .filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                    && seen.insert(url.path).inserted
            }
    }
}
