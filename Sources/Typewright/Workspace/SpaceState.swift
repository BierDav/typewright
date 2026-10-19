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

/// Scroll position (0 = top, 1 = bottom) and zoom of a previewed file in the HTML or SVG preview.
struct WebPreviewState: Codable, Equatable {
    var scroll = 0.0
    /// nil fits the width where the preview can.
    var zoom: Double?
}

/// UI state of one space; file keys are paths relative to the space folder.
struct SpaceState: Codable {
    var selected: String?
    var preview: String?
    var split = 0.5
    var editors: [String: EditorState] = [:]
    var previews: [String: PreviewState] = [:]
    var htmlPreviews: [String: WebPreviewState] = [:]
    var svgPreviews: [String: WebPreviewState] = [:]
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
        htmlPreviews = try c.decodeIfPresent([String: WebPreviewState].self, forKey: .htmlPreviews) ?? [:]
        svgPreviews = try c.decodeIfPresent([String: WebPreviewState].self, forKey: .svgPreviews) ?? [:]
    }
}

/// Keeps every space's UI state in Application Support so it survives relaunches.
@MainActor
enum SpaceStore {
    private static let file = URL.applicationSupportDirectory
        .appending(path: "Typewright", directoryHint: .isDirectory)
        // Named before projects became spaces; kept so saved state survives.
        .appending(path: "projects.json")

    private static var states: [String: SpaceState] = {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: SpaceState].self, from: data)) ?? [:]
    }()

    /// nil for spaces that were never opened before.
    static func state(for root: URL) -> SpaceState? {
        states[root.path]
    }

    static func save(_ state: SpaceState, for root: URL) {
        states[root.path] = state
        write()
    }

    /// Carries the state over when a space folder is renamed.
    static func move(from old: URL, to new: URL) {
        states[new.path] = states.removeValue(forKey: old.path)
        write()
    }

    private static func write() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
