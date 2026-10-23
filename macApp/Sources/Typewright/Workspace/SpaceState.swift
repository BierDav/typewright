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

/// Where a previewed file is shown; PDF, SVG and A4 HTML share it, so switching formats keeps the spot.
struct DocumentPosition: Codable, Equatable {
    /// Page index plus the fraction of that page above the view's top edge.
    var page = 0.0
    /// Points per screen point; nil fits the page width.
    var zoom: Double?
    /// Scroll (0 = top, 1 = bottom) of reflowing HTML and Markdown, which have no pages.
    var flow = 0.0
    /// Horizontal scroll (0 = left edge, 1 = right edge) of pages zoomed wider than the view.
    var pan = 0.0
    /// The format the file was last previewed in; nil uses the default.
    var mode: RenderMode?

    init(page: Double = 0, zoom: Double? = nil, flow: Double = 0, pan: Double = 0, mode: RenderMode? = nil) {
        self.page = page
        self.zoom = zoom
        self.flow = flow
        self.pan = pan
        self.mode = mode
    }

    // Field by field, so positions saved before a key existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = try c.decodeIfPresent(Double.self, forKey: .page) ?? 0
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom)
        flow = try c.decodeIfPresent(Double.self, forKey: .flow) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)).flatMap(RenderMode.init)
    }
}

enum PreviewMode: String, Codable {
    case hidden, following, pinned

    var nextTitle: String {
        switch self {
        case .hidden: "Show Preview"
        case .following: "Pin Preview"
        case .pinned: "Hide Preview"
        }
    }

    var icon: String {
        switch self {
        case .hidden: "eye"
        case .following: "eye.fill"
        case .pinned: "pin.fill"
        }
    }
}

/// UI state of one space; file keys are paths relative to the space folder.
struct SpaceState: Codable {
    var selected: String?
    var preview: String?
    var previewMode: PreviewMode?
    /// The file the preview last showed, kept while the preview is hidden.
    var lastPreview: String?
    var split = 0.5
    var editors: [String: EditorState] = [:]
    var previews: [String: PreviewState] = [:]
    var positions: [String: DocumentPosition] = [:]
    var expanded: [String] = []

    init() {}

    // Decoded field by field so adding keys never drops older saved state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        previewMode = try c.decodeIfPresent(PreviewMode.self, forKey: .previewMode)
        lastPreview = try c.decodeIfPresent(String.self, forKey: .lastPreview)
        split = try c.decodeIfPresent(Double.self, forKey: .split) ?? 0.5
        editors = try c.decodeIfPresent([String: EditorState].self, forKey: .editors) ?? [:]
        previews = try c.decodeIfPresent([String: PreviewState].self, forKey: .previews) ?? [:]
        expanded = try c.decodeIfPresent([String].self, forKey: .expanded) ?? []
        positions = try c.decodeIfPresent([String: DocumentPosition].self, forKey: .positions) ?? [:]
    }
}

struct WorkspaceSession {
    var state: SpaceState
    var buffers: [URL: String]
    var dirty: Set<URL> = []
}

/// Keeps every space's UI state in Application Support so it survives relaunches.
@MainActor
enum SpaceStore {
    private static let file: URL = {
        if SpaceRepository.isTestHost {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TypewrightTests/projects.json")
        }
        // Named before projects became spaces; kept so saved state survives.
        return URL.applicationSupportDirectory.appending(path: "Typewright", directoryHint: .isDirectory)
            .appending(path: "projects.json")
    }()

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
