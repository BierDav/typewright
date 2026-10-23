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
        let (url, file) = Self.resolve(url)
        if focus(url) {
            if let file { controllers.first { $0.state.workspace?.root == url }?.state.workspace?.select(file) }
            return
        }
        let empty = controllers.filter { $0.state.space == nil }
        if let target = empty.first(where: { $0.window?.isKeyWindow == true }) ?? empty.first {
            target.state.pendingFile = file
            target.state.space = url
            target.showWindow(nil)
        } else {
            let controller = MainWindowController(space: url)
            controller.state.pendingFile = file
            show(controller)
        }
    }

    /// Switches `state`'s window to `url`; other windows may show the same space.
    func open(_ url: URL, in state: WindowState) {
        let (url, file) = Self.resolve(url)
        state.pendingFile = file
        state.space = url
    }

    /// Links and items inside repository spaces lead to the space itself, showing the file.
    private static func resolve(_ url: URL) -> (space: URL, file: URL?) {
        guard let found = SpaceList.repositorySpace(of: url) else { return (url.standardizedFileURL, nil) }
        var isDir: ObjCBool = false
        let file = found.item.flatMap { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && !isDir.boolValue ? $0 : nil }
        return (found.space, file)
    }

    /// Finder and the Open panel: folders outside the repository are imported first; single files open in place.
    func openFromOutside(_ url: URL, in state: WindowState? = nil) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let known = SpaceList.all.contains { $0.path == url.resolvingSymlinksInPath().path }
        guard exists, isDir.boolValue, !known, !SpaceList.isInRepository(url) else {
            if let state { open(url, in: state) } else { open(url) }
            return
        }
        Task {
            guard let space = await importSpace(url) else { return }
            if let state { open(space, in: state) } else { open(space) }
        }
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

    @discardableResult
    func newWindow(from source: WindowState? = nil) -> MainWindowController {
        let source = source ?? keyState ?? controllers.first(where: { $0.window?.isMainWindow == true })?.state
        let controller = MainWindowController(space: source?.workspace?.root ?? source?.space, copying: source)
        show(controller)
        return controller
    }

    /// Brings up a window without a space, reusing an existing one.
    func showEmptyWindow() {
        if let empty = controllers.first(where: { $0.state.space == nil }) {
            empty.showWindow(nil)
        } else {
            show(MainWindowController(space: nil))
        }
    }

    func closeSpace() {
        keyState?.space = nil
    }

    /// The layout's window shortcuts, also covering built-in alternates like IntelliJ's ⌘K.
    func installShortcuts() {
        Popups.menuCommands = { [weak self] in
            let keys = KeyLayout.current.shortcuts
            return [
                Popups.MenuCommand(keys: keys.palette) { [weak self] in self?.state(for: $0)?.overlay = .palette() },
                Popups.MenuCommand(keys: keys.findInSpace) { [weak self] in self?.state(for: $0)?.overlay = .search(allSpaces: nil) },
                Popups.MenuCommand(keys: keys.showSpaces) { [weak self] window in
                    guard let state = self?.state(for: window), state.space != nil else { return }
                    state.setSpacesOpen(!state.spacesOpen)
                },
                Popups.MenuCommand(keys: keys.moveFile) { [weak self] in self?.state(for: $0)?.overlay = .palette(page: "file.move") },
            ]
        }
        Popups.installTracking()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard !KeyLayout.isRecordingShortcut, NSApp.modalWindow == nil else { return false }
                let keys = KeyLayout.current.shortcuts
                // These work without a space too.
                if keys.settings.matches(event) {
                    SettingsWindowController.shared.show()
                    return true
                }
                if keys.newWindow.matches(event) {
                    self.newWindow()
                    return true
                }
                if keys.openSpace.matches(event) {
                    self.openPanel()
                    return true
                }
                guard let state = self.state(for: event.window),
                      state.overlay == nil else { return false }
                if keys.palette.matches(event) { self.showPalette(); return true }
                if keys.showSpaces.matches(event) { self.toggleSpaces(); return true }
                if keys.sidebar.matches(event) { self.toggleSidebar(); return true }
                if keys.findInSpace.matches(event) { self.showSearch(); return true }
                if keys.moveFile.matches(event) { self.showPalette(page: "file.move"); return true }
                if keys.closeSpace.matches(event) { self.closeSpace(); return true }
                if keys.back.matches(event), let workspace = state.workspace { workspace.goBack(); return true }
                if keys.forward.matches(event), let workspace = state.workspace { workspace.goForward(); return true }
                if keys.togglePreview.matches(event), let workspace = state.workspace {
                    workspace.togglePreviewVisibility()
                    return true
                }
                if keys.previewCurrentFile.matches(event), let workspace = state.workspace {
                    workspace.previewSelectedFile()
                    return true
                }
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                      let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) else { return false }
                // A layout can bind a digit in the editor, like ⌘7 commenting a line; the editor goes first.
                if let editor = event.window?.firstResponder as? TypstTextView,
                   editor.performKeyEquivalent(with: event) { return true }
                self.switchToSpace(at: digit - 1, in: state)
                return true
            }
            return handled ? nil : event
        }
    }

    /// The mouse's back and forward buttons move the caret through the navigation history of the window below them.
    func installNavigationButtons() {
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            let handled = MainActor.assumeIsolated {
                guard event.buttonNumber == 3 || event.buttonNumber == 4 else { return false }
                if event.buttonNumber == 3, Popups.back(in: event.window) { return true }
                guard let state = self.state(for: event.window),
                      state.overlay == nil, let workspace = state.workspace else { return false }
                if event.buttonNumber == 3 { workspace.goBack() } else { workspace.goForward() }
                return true
            }
            return handled ? nil : event
        }
    }

    func goBack() { keyState?.workspace?.goBack() }

    func goForward() { keyState?.workspace?.goForward() }

    func togglePreview() { keyState?.workspace?.togglePreviewVisibility() }

    func previewCurrentFile() { keyState?.workspace?.previewSelectedFile() }

    /// History of a file that may be deleted, in the window showing its space (opened if needed).
    func showHistory(of file: URL, inSpace space: URL) {
        func workspace() -> Workspace? {
            controllers.first { $0.state.workspace?.root.standardizedFileURL == space.standardizedFileURL }?.state.workspace
        }
        if let ws = workspace() {
            _ = focus(space)
            return FileHistory.show(file, in: ws)
        }
        open(space)
        // The window builds its space on the next updates.
        Task {
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if let ws = workspace() { return FileHistory.show(file, in: ws) }
            }
        }
    }

    /// Recently Deleted for the key window's space, or the whole library.
    func showRecentlyDeleted() {
        RecentlyDeleted.show(in: (keyState?.workspace?.root).flatMap { SpaceList.isInRepository($0) ? $0 : nil })
    }

    /// The menu can't follow the key window, so files without history (git checkouts, outside the library) beep.
    func showFileHistory() {
        guard let ws = keyState?.workspace, let file = ws.selectedFile else { return }
        guard FileHistory.isAvailable(for: file) else { return NSSound.beep() }
        FileHistory.show(file, in: ws)
    }

    /// Slides to the space at `index` in the list, in the direction of its place relative to the current one.
    func switchToSpace(at index: Int, in state: WindowState) {
        let spaces = SpaceList.all
        guard spaces.indices.contains(index) else { return NSSound.beep() }
        let target = spaces[index]
        let current = (state.workspace?.root ?? state.space.map(Workspace.root))?.resolvingSymlinksInPath().path
        guard target.path != current else { return state.setSpacesOpen(false) }
        state.switchForward = spaces.firstIndex { $0.path == current }.map { index > $0 } ?? true
        // The old space takes on the slide before it's replaced.
        DispatchQueue.main.async { state.space = target.standardizedFileURL }
    }

    func toggleSpaces() {
        guard let state = keyState, state.space != nil else { return }
        // A hidden sidebar stays hidden; the selector slides in along the window's edge instead.
        state.floatingSidebar = false
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

    var keyState: WindowState? {
        state(for: NSApp.keyWindow)
    }

    /// The state of the main window showing `window`, which may be one of its popups, as a clicked docs panel takes key.
    func state(for window: NSWindow?) -> WindowState? {
        let host = Popups.hostWindow(for: window)
        return controllers.first { $0.window === host }?.state
            ?? controllers.first { $0.window === Popups.menuWindow }?.state
    }

    /// Reopens the spaces from the last session, or an empty window.
    func restoreSession() {
        guard controllers.isEmpty else { return }
        let paths = UserDefaults.standard.stringArray(forKey: Self.sessionKey) ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { newWindow() } else {
            // Imported folders left links behind; open their copies.
            urls.forEach { show(MainWindowController(space: Self.resolve($0).space)) }
        }
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

    func flushAllSaves() {
        controllers.forEach { $0.state.workspace?.flushSaves() }
    }

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

    /// Asks for a folder to import as a space.
    func openPanel(in state: WindowState? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Import"
        panel.message = "Choose a folder to import as a space"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard SpaceList.repositorySpace(of: url) == nil else {
            if let state { open(url, in: state) } else { open(url) }
            return
        }
        Task {
            guard let space = await importSpace(url) else { return }
            if let state { open(space, in: state) } else { open(space) }
        }
    }

    /// A new, empty space folder in the repository, at the end of the list.
    @discardableResult
    func newSpace(named name: String = "Untitled Space") -> URL? {
        do {
            let url = try SpaceFolders.create(named: name, in: SpaceList.repository)
            SpaceList.add(url)
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// "New Space" from the menu and palette: makes one and shows it.
    func newSpace(in state: WindowState?, named name: String = "Untitled Space") {
        guard let url = newSpace(named: name) else { return }
        if let state { open(url, in: state) } else { open(url) }
    }

    /// Copies a folder into the repository, asking what becomes of the original. Returns the new space.
    /// `warnAboutGit` is off where the caller already told the user (the migration sheet).
    @discardableResult
    func importSpace(_ source: URL, mode: SpaceFolders.ImportMode? = nil, warnAboutGit: Bool = true) async -> URL? {
        let source = source.standardizedFileURL
        if warnAboutGit, SpaceFolders.isGitRepository(source) {
            let alert = NSAlert()
            alert.messageText = "“\(source.lastPathComponent)” is a Git repository"
            alert.informativeText = "Typewright keeps no history for Git repositories and won't sync them, since Git "
                + "already tracks their changes. You can still edit and preview it in Typewright."
            alert.addButton(withTitle: "Import Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        var mode = mode
        if mode == nil {
            let alert = NSAlert()
            alert.messageText = "Import “\(source.lastPathComponent)” into Typewright?"
            alert.informativeText = "Typewright copies the folder into its spaces, where every change is kept in its history. "
                + "A link to the copy can take the original's place, so you still find it where it was; the original goes to the Trash."
            alert.addButton(withTitle: "Import and Replace With Link")
            alert.addButton(withTitle: "Import and Keep Original")
            alert.addButton(withTitle: "Import and Delete Original")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: mode = .replaceWithLink
            case .alertSecondButtonReturn: mode = .keepOriginal
            case .alertThirdButtonReturn: mode = .deleteOriginal
            default: return nil
            }
        }
        let windows = windows(showing: source.resolvingSymlinksInPath())
        windows.forEach { $0.state.workspace?.flushSaves() }
        let root = SpaceList.repository
        let chosen = mode ?? .keepOriginal
        let result = await Task.detached { Result(catching: { try SpaceFolders.importFolder(source, into: root, mode: chosen) }) }.value
        switch result {
        case .failure(let error):
            NSAlert(error: error).runModal()
            return nil
        case .success(let target):
            if chosen == .replaceWithLink { SpaceLinks.shared.record(source, to: target) }
            relocate(windows, from: source.resolvingSymlinksInPath(), to: target)
            // Keeps the space where it was in the list.
            SpaceList.replace(source, with: target)
            return target
        }
    }

    /// Deletes a repository space after asking; it stays in the history (Recently Deleted) and undo brings it back.
    /// Links to it stay where they are and work again once it's back.
    func deleteSpace(_ url: URL, in state: WindowState? = nil) {
        let url = url.standardizedFileURL
        let alert = NSAlert()
        alert.messageText = "Delete “\(url.lastPathComponent)”?"
        alert.informativeText = "You can undo this, or get the space back later from File › Recently Deleted…."
        if SyncService.shared.isSynced(url) { alert.informativeText += " This Mac stops syncing it; your other devices keep it." }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let manager = (state ?? keyState)?.undoManager
        FileOperations.spaces.perform(.deleteSpace(url), name: "Delete “\(url.lastPathComponent)”",
                                      message: "Delete space \(url.lastPathComponent)", undoManager: manager)
    }

    /// The deletion itself, for `FileOperations`: windows showing the space close it, and its sync stops.
    func deleteSpaceNow(_ url: URL, message: String) async -> DeletedItem? {
        let windows = windows(showing: url)
        windows.forEach { $0.state.workspace?.flushSaves() }
        // Its shares, nested ones too, stop through `SpaceRepository.didDelete`; undo brings them back.
        guard let item = await SpaceRepository.shared.delete([url], message: message)?.first else {
            let alert = NSAlert()
            alert.messageText = "Couldn't delete “\(url.lastPathComponent)”"
            alert.informativeText = SpaceRepository.shared.lastError ?? ""
            alert.runModal()
            return nil
        }
        windows.forEach { $0.state.space = nil }
        // The list keeps its entry, so the space returns to its place when restored.
        NotificationCenter.default.post(name: SpaceList.didChange, object: nil)
        return item
    }

    /// Asks where to put a link to a space or an item in one, ~/Documents first.
    func link(_ item: URL) {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = item.lastPathComponent
        panel.canCreateDirectories = true
        panel.prompt = "Link"
        panel.message = "Choose where to put a link to “\(item.lastPathComponent)”"
        guard panel.runModal() == .OK, let location = panel.url else { return }
        do {
            // The panel already asked whether to replace an existing item.
            if FileManager.default.fileExists(atPath: location.path) || SpaceFolders.isLink(location) {
                try FileManager.default.trashItem(at: location, resultingItemURL: nil)
            }
            try SpaceLinks.shared.create(to: item, at: location)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Renames a space's folder on disk; every window showing it, its saved state, its links and its sync follow along.
    @discardableResult
    func rename(space old: URL, to name: String, registersUndo: Bool = true) -> URL? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = old.standardizedFileURL
        guard !name.isEmpty, !name.contains("/"), name != old.lastPathComponent else { return nil }
        let target = old.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        // Case-only renames hit the same folder on case-insensitive volumes.
        let caseOnly = target.path.lowercased() == old.path.lowercased()
        guard caseOnly || !FileManager.default.fileExists(atPath: target.path) else {
            let alert = NSAlert()
            alert.messageText = "“\(name)” already exists."
            alert.informativeText = "Choose a different name for the space."
            alert.runModal()
            return nil
        }
        let windows = windows(showing: old)
        windows.forEach { $0.state.workspace?.flushSaves() }
        do {
            try FileManager.default.moveItem(at: old, to: target)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
        SpaceLinks.shared.moved(from: old, to: target)
        relocate(windows, from: old, to: target)
        SpaceList.replace(old, with: target)
        if registersUndo, SpaceList.isInRepository(target) {
            FileOperations.spaces.performed(inverse: .renameSpace(FileOp.Move(from: target, to: old)),
                                            name: "Rename “\(old.lastPathComponent)”",
                                            message: "Rename space \(old.lastPathComponent) to \(target.lastPathComponent)",
                                            undoManager: keyState?.undoManager)
        }
        return target
    }

    private func windows(showing root: URL) -> [MainWindowController] {
        let path = root.standardizedFileURL.path
        return controllers.filter { controller in
            let root = controller.state.workspace?.root ?? controller.state.space.map(Workspace.root)
            return root?.standardizedFileURL.path == path || root?.resolvingSymlinksInPath().path == path
        }
    }

    /// Points windows, saved state and sync at a space's new folder.
    private func relocate(_ windows: [MainWindowController], from old: URL, to target: URL) {
        // Persist under the old key first so the saved state moves along.
        windows.forEach { $0.state.workspace?.close() }
        SpaceStore.move(from: old, to: target)
        SpaceRepository.shared.noteMoved(from: old, to: target)
        for window in windows {
            // A window opened on a file inside the space keeps that file.
            let space = window.state.space?.standardizedFileURL
            let base = window.state.workspace?.root.path ?? old.path
            if let space, space.path.hasPrefix(base + "/") {
                window.state.space = URL(fileURLWithPath: target.path + space.path.dropFirst(base.count))
            } else {
                window.state.space = target
            }
        }
    }
}

/// The user's spaces in their chosen order: the repository's folders, plus folders elsewhere left as they were.
enum SpaceList {
    // Named before projects became spaces; kept so the list survives.
    private static let key = "recentProjects"

    /// Where the spaces live; the same as `SpaceRepository.shared.root`, without opening the repository.
    static let repository = SpaceRepository.defaultRoot.standardizedFileURL

    static var all: [URL] {
        order(stored: stored, repository: SpaceFolders.spaces(in: repository))
    }

    /// Stored entries that still exist (older ones may be files or links), then repository folders not stored yet.
    static func order(stored: [String], repository: [URL]) -> [URL] {
        var seen = Set<String>()
        let known = stored
            .map { Workspace.root(of: URL(fileURLWithPath: $0)).resolvingSymlinksInPath() }
            .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
        return known + repository.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// Whether `url` lies in the repository, so it has history and saves quickly.
    static func isInRepository(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(repository.resolvingSymlinksInPath().path + "/")
    }

    /// The repository space holding `url` (through links too), with the file or folder inside it if any.
    static func repositorySpace(of url: URL) -> (space: URL, item: URL?)? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let base = repository.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(base + "/") else { return nil }
        let parts = resolved.path.dropFirst(base.count + 1).split(separator: "/")
        guard let first = parts.first else { return nil }
        let space = repository.appendingPathComponent(String(first), isDirectory: true).standardizedFileURL
        return (space, parts.count > 1 ? resolved : nil)
    }

    /// Where a space is, for its row: the folders linking to it, or its folder outside the repository.
    @MainActor static func subtitle(of url: URL) -> String {
        func short(_ url: URL) -> String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        let path: String
        if isInRepository(url) {
            let links = SpaceLinks.shared.links(to: url)
            path = links.isEmpty ? "Typewright" : links.map { short($0.url.deletingLastPathComponent()) }.joined(separator: ", ")
        } else {
            path = short(url.deletingLastPathComponent())
        }
        guard let branch = branch(of: url) else { return path }
        return "\(path) · \(branch)"
    }

    /// Posted when the stored list changes, so open sidebars reload it (imports finish after the click).
    static let didChange = Notification.Name("SpaceListDidChange")

    private static var stored: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Appends new spaces; known ones keep their place.
    static func add(_ url: URL) {
        stored = spaceOrderAdd(stored: stored, path: url.resolvingSymlinksInPath().path)
    }

    /// Moves a space to `index` in `all`; missing folders keep their entries for when they return.
    static func move(_ url: URL, to index: Int) {
        let visible = all.map(\.path)
        // Repository folders not stored yet join the stored order first, so they can be placed.
        let current = visible.reduce(stored) { spaceOrderAdd(stored: $0, path: $1) }
        stored = spaceOrderMove(stored: current, visible: visible, path: url.path, index: Int32(clamping: index))
    }

    /// Swaps a renamed or imported space in place, keeping its position.
    static func replace(_ old: URL, with new: URL) {
        let new = new.resolvingSymlinksInPath().path
        // An imported folder's old path now leads to the copy, so match it as typed too.
        for path in Set([old.standardizedFileURL.path, old.resolvingSymlinksInPath().path]) {
            stored = spaceOrderReplace(stored: stored, old: path, new: new)
        }
        if !stored.contains(new) { add(URL(fileURLWithPath: new)) }
    }

    /// Drops every entry that leads to the space, like a file inside it or a symlinked spelling of its path.
    static func remove(_ url: URL) {
        let root = Workspace.root(of: url).resolvingSymlinksInPath().path
        stored = stored.filter { Workspace.root(of: URL(fileURLWithPath: $0)).resolvingSymlinksInPath().path != root }
    }

    /// Current git branch of the space, if any.
    static func branch(of url: URL) -> String? {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        var dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        for _ in 0..<6 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let s = try? String(contentsOf: head, encoding: .utf8) { return gitBranch(head: s) }
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
