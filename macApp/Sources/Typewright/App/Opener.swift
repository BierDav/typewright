import AppKit
import SwiftUI
import TypewrightCore

/// Opens space windows from menus, Finder and the space selector.
@MainActor
final class Opener {
    static let shared = Opener()

    private var controllers: [MainWindowController] = []

    /// Focuses the window showing `url`, else loads it into an empty window, else opens a new one.
    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if focus(url) { return }
        let empty = controllers.filter { $0.state.space == nil }
        if let target = empty.first(where: { $0.window?.isKeyWindow == true }) ?? empty.first {
            target.state.space = url
            target.showWindow(nil)
        } else {
            show(MainWindowController(space: url))
        }
    }

    /// Switches `state`'s window to `url`; other windows may show the same space.
    func open(_ url: URL, in state: WindowState) {
        state.space = url.standardizedFileURL
    }

    /// A new window on `space`, showing `file` when given.
    func openInNewWindow(_ space: URL, file: URL? = nil) {
        let controller = MainWindowController(space: space.standardizedFileURL)
        controller.state.pendingFile = file?.standardizedFileURL
        show(controller)
    }

    @discardableResult
    private func focus(_ url: URL) -> Bool {
        let root = Workspace.root(of: url).path
        guard let existing = controllers.first(where: { $0.state.space.map(Workspace.root)?.path == root }) else { return false }
        existing.showWindow(nil)
        return true
    }

    func newWindow() {
        show(MainWindowController(space: nil))
    }

    /// Brings up a window without a space, reusing an existing one.
    func showEmptyWindow() {
        if let empty = controllers.first(where: { $0.state.space == nil }) {
            empty.showWindow(nil)
        } else {
            newWindow()
        }
    }

    func closeSpace() {
        keyState?.space = nil
    }

    func toggleSpaces() {
        guard let state = keyState, state.space != nil else { return }
        // The selector lives in the sidebar.
        if !state.spacesOpen { state.sidebarVisible = true }
        state.setSpacesOpen(!state.spacesOpen)
    }

    /// ⌘S also saves, for the habit.
    func toggleSidebar() {
        guard let state = keyState else { return }
        state.workspace?.flushSaves()
        withAnimation(.smooth(duration: 0.3)) { state.sidebarVisible.toggle() }
    }

    func showPalette(page: String? = nil) {
        guard let state = keyState else { return }
        state.overlay = state.overlay == .palette(page: page) ? nil : .palette(page: page)
    }

    /// Full text search in the space, or across all spaces from the space overview.
    func showSearch() {
        guard let state = keyState else { return }
        state.overlay = .search(allSpaces: nil)
    }

    private var keyState: WindowState? {
        controllers.first { $0.window?.isKeyWindow == true }?.state
    }

    /// Reopens the spaces from the last session, or an empty window.
    func restoreSession() {
        guard controllers.isEmpty else { return }
        let paths = UserDefaults.standard.stringArray(forKey: Self.sessionKey) ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { newWindow() } else { urls.forEach { show(MainWindowController(space: $0)) } }
    }

    func saveSession() {
        let paths = controllers.compactMap { $0.state.space?.path }
        UserDefaults.standard.set(paths, forKey: Self.sessionKey)
    }

    // Named before projects became spaces; kept so the session survives.
    private static let sessionKey = "openProjects"

    func closed(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        // Keep the session when quitting closes all windows.
        if !isTerminating { saveSession() }
    }

    var isTerminating = false

    private func show(_ controller: MainWindowController) {
        // Offset from the front window, so the new one doesn't hide exactly behind it.
        if let front = controllers.first(where: { $0.window?.isKeyWindow == true })?.window ?? controllers.last?.window,
           let window = controller.window {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        controllers.append(controller)
        controller.showWindow(nil)
        saveSession()
    }

    /// Asks for a space folder; the panel's New Folder button covers creating one.
    func openPanel(in state: WindowState? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a folder to open as a space"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let state { open(url, in: state) } else { open(url) }
    }

    /// Renames the space folder on disk and reopens the window on the new location.
    func rename(_ workspace: Workspace, to name: String, in state: WindowState) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = workspace.root
        guard !name.isEmpty, !name.contains("/"), name != old.lastPathComponent else { return }
        let target = old.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        // Case-only renames hit the same folder on case-insensitive volumes.
        let caseOnly = target.path.lowercased() == old.path.lowercased()
        guard caseOnly || !FileManager.default.fileExists(atPath: target.path) else { return }
        workspace.flushSaves()
        do {
            try FileManager.default.moveItem(at: old, to: target)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        // Persist under the old key first so the saved state moves along.
        workspace.close()
        SpaceStore.move(from: old, to: target)
        SpaceList.replace(old, with: target)
        state.space = target
    }
}

/// The user's spaces in their chosen order.
enum SpaceList {
    // Named before projects became spaces; kept so the list survives.
    private static let key = "recentProjects"

    static var all: [URL] {
        var seen = Set<String>()
        return (UserDefaults.standard.stringArray(forKey: key) ?? [])
            // Older entries may be files; their folder is the space.
            .map { Workspace.root(of: URL(fileURLWithPath: $0)).resolvingSymlinksInPath() }
            .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
    }

    private static var stored: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Appends new spaces; known ones keep their place.
    static func add(_ url: URL) {
        stored = SpaceOrder.shared.add(stored: stored, path: url.resolvingSymlinksInPath().path)
    }

    /// Moves a space to `index` in `all`; missing folders keep their entries for when they return.
    static func move(_ url: URL, to index: Int) {
        stored = SpaceOrder.shared.move(stored: stored, visible: all.map(\.path), path: url.path, index: Int32(clamping: index))
    }

    /// Swaps a renamed space in place, keeping its position.
    static func replace(_ old: URL, with new: URL) {
        stored = SpaceOrder.shared.replace(stored: stored, old: old.resolvingSymlinksInPath().path,
                                           new: new.resolvingSymlinksInPath().path)
    }

    /// Drops every entry that leads to the space, like a file inside it or a symlinked spelling of its path.
    static func remove(_ url: URL) {
        stored = SpaceOrder.shared.remove(stored: stored, root: Workspace.root(of: url).resolvingSymlinksInPath().path) {
            Workspace.root(of: URL(fileURLWithPath: $0)).resolvingSymlinksInPath().path
        }
    }

    /// Current git branch of the space, if any.
    static func branch(of url: URL) -> String? {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        var dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        for _ in 0..<6 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let s = try? String(contentsOf: head, encoding: .utf8) { return Paths.shared.gitBranch(head: s) }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    @MainActor static func apply(_ raw: String) {
        switch Appearance(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
