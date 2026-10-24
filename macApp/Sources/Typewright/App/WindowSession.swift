import AppKit

struct WindowSession: Codable {
    var space: URL?
    var file: URL?
    var workspace: SpaceState?
    var sidebarVisible: Bool?
    var frame: String?

    init(space: URL?) {
        self.space = space
    }

    @MainActor init(controller: MainWindowController) {
        let state = controller.state
        space = state.space
        file = state.pendingFile
        workspace = state.workspace?.session().state ?? state.pendingSession?.state
        sidebarVisible = state.sidebarVisible
        frame = controller.window.map { NSStringFromRect($0.frame) }
    }
}
