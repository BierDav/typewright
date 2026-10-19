import Foundation

/// Cursor and scroll position of one file; `top` is the first visible character.
struct EditorState: Codable, Equatable {
    var selection = 0
    var length = 0
    var top = 0
}

/// Zoom (nil = fit width) and scroll destination of one previewed file.
struct PreviewState: Codable, Equatable {
    var scale: Double?
    var page = 0
    var x = 0.0
    var y = 0.0
}

/// UI state of one project; file keys are paths relative to the project root.
struct ProjectState: Codable {
    var selected: String?
    var preview: String?
    var split = 0.5
    var editors: [String: EditorState] = [:]
    var previews: [String: PreviewState] = [:]
    var expanded: [String] = []

    init() {}

    // Decoded field by field so adding keys never drops older saved state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        split = try c.decodeIfPresent(Double.self, forKey: .split) ?? 0.5
        editors = try c.decodeIfPresent([String: EditorState].self, forKey: .editors) ?? [:]
        previews = try c.decodeIfPresent([String: PreviewState].self, forKey: .previews) ?? [:]
        expanded = try c.decodeIfPresent([String].self, forKey: .expanded) ?? []
    }
}

/// Keeps every project's UI state in Application Support so it survives relaunches.
@MainActor
enum ProjectStore {
    private static let file = URL.applicationSupportDirectory
        .appending(path: "Typewright", directoryHint: .isDirectory)
        .appending(path: "projects.json")

    private static var states: [String: ProjectState] = {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: ProjectState].self, from: data)) ?? [:]
    }()

    /// nil for projects that were never opened before.
    static func state(for root: URL) -> ProjectState? {
        states[root.path]
    }

    static func save(_ state: ProjectState, for root: URL) {
        states[root.path] = state
        guard let data = try? JSONEncoder().encode(states) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
