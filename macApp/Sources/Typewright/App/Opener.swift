import AppKit
import SwiftUI
import TypewrightCore

/// Opens space windows from menus, Finder and the space selector.
@MainActor
final class Opener {
    static let shared = Opener()

    private var controllers: [MainWindowController] = []
    private let defaults: UserDefaults?
    private var isRestoringSession = false

    init(defaults: UserDefaults? = AppDelegate.isTesting ? nil : .standard) {
        self.defaults = defaults
    }

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
            let controller = MainWindowController(space: url, file: file)
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
        askToImport(url, in: state) { [weak self] space in
            if let state { self?.open(space, in: state) } else { self?.open(space) }
        }
    }

    /// A new window on `space`, showing `file` when given.
    func openInNewWindow(_ space: URL, file: URL? = nil) {
        let controller = MainWindowController(space: space.standardizedFileURL, file: file?.standardizedFileURL)
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

    /// Reopens each window with its own navigation and preview state.
    func restoreSession() {
        guard let defaults, controllers.isEmpty else { return }
        let saved: [WindowSession]
        if let data = defaults.data(forKey: Self.windowsKey),
           let windows = try? JSONDecoder().decode([WindowSession].self, from: data) {
            saved = windows
        } else {
            saved = (defaults.stringArray(forKey: Self.sessionKey) ?? []).map {
                WindowSession(space: URL(fileURLWithPath: $0))
            }
        }
        let windows = saved.filter { $0.space.map { FileManager.default.fileExists(atPath: $0.path) } ?? true }
        isRestoringSession = true
        for session in windows {
            let resolved = session.space.map { Self.resolve($0) }
            show(MainWindowController(space: resolved?.space, file: session.file ?? resolved?.file, restoring: session), session: session)
        }
        if windows.isEmpty { show(MainWindowController(space: nil)) }
        isRestoringSession = false
        saveSession()
    }

    func saveSession() {
        guard let defaults, !isRestoringSession, !isTerminating else { return }
        let windows = controllers.map { WindowSession(controller: $0) }
        guard let data = try? JSONEncoder().encode(windows) else { return }
        defaults.set(data, forKey: Self.windowsKey)
    }

    /// Capture every window before termination starts closing them.
    func prepareToQuit() {
        guard !isTerminating else { return }
        flushAllSaves()
        controllers.forEach { $0.state.workspace?.persist() }
        saveSession()
        isTerminating = true
    }

    private static let windowsKey = "openWindows"

    // Named before projects became spaces; kept so the session survives.
    private static let sessionKey = "openProjects"

    func closed(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        // Keep the session when quitting closes all windows.
        if !isTerminating { saveSession() }
    }

    private(set) var isTerminating = false

    func flushAllSaves() {
        controllers.forEach { $0.state.workspace?.flushSaves() }
    }

    private func show(_ controller: MainWindowController, session: WindowSession? = nil) {
        controller.onClose = { [weak self, weak controller] in
            if let controller { self?.closed(controller) }
        }
        // Offset from the front window, so the new one doesn't hide exactly behind it.
        if let front = controllers.first(where: { $0.window?.isKeyWindow == true })?.window ?? controllers.last?.window,
           let window = controller.window {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        if let rect = session?.placement(), let window = controller.window { window.setFrame(rect, display: false) }
        controllers.append(controller)
        controller.showWindow(nil)
        // Full screen opens on the display the window is on now.
        if session?.fullScreen == true, let window = controller.window {
            DispatchQueue.main.async { if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } }
        }
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
        askToImport(url, in: state) { [weak self] space in
            if let state { self?.open(space, in: state) } else { self?.open(space) }
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
            PaletteDialog.error(error, title: "Couldn't create a new space")
            return nil
        }
    }

    /// "New Space" from the menu and palette: makes one and shows it.
    func newSpace(in state: WindowState?, named name: String = "Untitled Space") {
        guard let url = newSpace(named: name) else { return }
        if let state = state ?? keyState {
            state.renameNewSpace = true
            state.sidebarVisible = true
            open(url, in: state)
        } else {
            let controller = MainWindowController(space: url, renameNewSpace: true)
            show(controller)
        }
    }

    /// The window to ask in: `state`, the key one, any, or a new empty one.
    private func promptState(_ state: WindowState?) -> WindowState {
        if let state = state ?? keyState ?? controllers.first(where: { $0.window?.isMainWindow == true })?.state
            ?? controllers.last?.state {
            state.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return state
        }
        let controller = MainWindowController(space: nil)
        show(controller)
        return controller.state
    }

    /// Asks in the command palette how a folder from outside becomes a space: copied into the library (and what
    /// becomes of the original) or listed where it is, as an external space. `done` gets the space.
    /// `external` is off where the folder already is one, or only an import helps (sync).
    func askToImport(_ source: URL, in state: WindowState? = nil, external offersExternal: Bool = true,
                     done: @escaping (URL) -> Void = { _ in }) {
        let source = source.standardizedFileURL
        let name = source.lastPathComponent
        let git = SpaceFolders.isGitRepository(source)
        func importing(_ id: String, _ title: String, _ subtitle: String, _ icon: String, _ mode: SpaceFolders.ImportMode) -> PaletteItem {
            PaletteItem(id: "import.\(id)", title: title, subtitle: git ? SpaceFolders.gitRepositoryNote : subtitle, icon: icon,
                        section: "Import “\(name)”", action: .run { [weak self] in
                Task { if let space = await self?.importSpace(source, mode: mode) { done(space) } }
            })
        }
        let external = PaletteItem(id: "import.external", title: "Add as External Space",
                                   subtitle: "Stays where it is: no history or device sync", icon: "arrow.up.forward.square",
                                   section: "Import “\(name)”", keywords: ["link", "external", "open in place"],
                                   action: .run { [weak self] in
            guard let space = self?.addExternal(source) else { return }
            done(space)
        })
        var items = [
            importing("link", "Import and Replace With Link", "Copies it into the library; a link takes its place, the original goes to the Trash",
                      "link", .replaceWithLink),
            importing("keep", "Import and Keep Original", "Copies it into the library; the original stays", "doc.on.doc", .keepOriginal),
            importing("delete", "Import and Delete Original", "Moves it into the library; the original goes to the Trash", "trash", .deleteOriginal),
        ]
        // Git keeps a checkout's history already, so leaving it where it is comes first.
        if offersExternal { if git { items.insert(external, at: 0) } else { items.append(external) } }
        promptState(state).ask(PalettePage(title: "Import “\(name)”", placeholder: "Choose how to add “\(name)”…",
                                           kind: .list { items }))
    }

    /// Lists a folder outside the library as a space, where it is.
    @discardableResult
    func addExternal(_ source: URL) -> URL? {
        let source = source.standardizedFileURL
        let resolved = source.resolvingSymlinksInPath().path
        let base = SpaceList.repository.resolvingSymlinksInPath().path
        if resolved == base || base.hasPrefix(resolved + "/") {
            PaletteDialog.error(SpaceFolders.ImportError.containsRepository, title: "Can't add that folder")
            return nil
        }
        SpaceList.add(source)
        return source
    }

    /// Copies a folder into the repository; `mode` says what becomes of the original. Returns the new space.
    @discardableResult
    func importSpace(_ source: URL, mode: SpaceFolders.ImportMode) async -> URL? {
        let source = source.standardizedFileURL
        let windows = windows(showing: source.resolvingSymlinksInPath())
        windows.forEach { $0.state.workspace?.flushSaves() }
        let root = SpaceList.repository
        let result = await Task.detached { Result(catching: { try SpaceFolders.importFolder(source, into: root, mode: mode) }) }.value
        switch result {
        case .failure(let error):
            PaletteDialog.error(error, title: "Couldn't import “\(source.lastPathComponent)”")
            return nil
        case .success(let target):
            if mode == .replaceWithLink { SpaceLinks.shared.record(source, to: target) }
            relocate(windows, from: source.resolvingSymlinksInPath(), to: target)
            // Keeps the space where it was in the list.
            SpaceList.replace(source, with: target)
            return target
        }
    }

    /// Deletes a repository space after asking in the command palette; it stays in the history (Recently Deleted) and
    /// undo brings it back. Links to it stay where they are and work again once it's back.
    func deleteSpace(_ url: URL, in state: WindowState? = nil) {
        let url = url.standardizedFileURL
        let name = url.lastPathComponent
        var detail = "Undo or File › Recently Deleted… bring it back"
        if SyncService.shared.isSynced(url) { detail += "; this Mac stops syncing it, other devices keep it" }
        let state = promptState(state)
        state.ask(PalettePage(title: "Delete “\(name)”?", placeholder: "Delete “\(name)”?", kind: .list {[
            PaletteItem(id: "delete.confirm", title: "Delete Space “\(name)”", subtitle: detail, icon: "trash",
                        section: "Delete “\(name)”", action: .run {
                FileOperations.spaces.perform(.deleteSpace(url), name: "Delete “\(name)”",
                                              message: "Delete space \(name)", undoManager: state.undoManager)
            }),
            PaletteItem(id: "delete.cancel", title: "Cancel", icon: "xmark", section: "Delete “\(name)”", action: .run {}),
        ]}))
    }

    /// The deletion itself, for `FileOperations`: windows showing the space close it, and its sync stops.
    func deleteSpaceNow(_ url: URL, message: String) async -> DeletedItem? {
        let windows = windows(showing: url)
        windows.forEach { $0.state.workspace?.flushSaves() }
        // Its shares, nested ones too, stop through `SpaceRepository.didDelete`; undo brings them back.
        guard let item = await SpaceRepository.shared.delete([url], message: message)?.first else {
            PaletteDialog.message("Couldn't delete “\(url.lastPathComponent)”", detail: SpaceRepository.shared.lastError)
            return nil
        }
        windows.forEach { $0.state.space = nil }
        // The list keeps its entry, so the space returns to its place when restored.
        NotificationCenter.default.post(name: SpaceList.didChange, object: nil)
        return item
    }

    /// Removes a folder outside the library from the spaces list after asking; the folder stays where it is.
    func forgetSpace(_ url: URL, in state: WindowState? = nil) {
        let url = url.standardizedFileURL
        let name = url.lastPathComponent
        let state = promptState(state)
        state.ask(PalettePage(title: "Remove “\(name)” from Spaces?", placeholder: "Remove “\(name)” from Spaces?",
                              kind: .list {[
            PaletteItem(id: "forget.confirm", title: "Remove “\(name)” from Spaces",
                        subtitle: "The folder stays where it is; it's no longer listed here", icon: "minus.circle",
                        section: "Remove “\(name)”", action: .run {
                self.windows(showing: url).forEach { $0.state.space = nil }
                SpaceList.remove(url)
            }),
            PaletteItem(id: "forget.cancel", title: "Cancel", icon: "xmark", section: "Remove “\(name)”",
                        action: .run {}),
        ]}))
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
            PaletteDialog.error(error, title: "Couldn't create the link")
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
            PaletteDialog.message("“\(name)” already exists.", detail: "Choose a different name for the space.")
            return nil
        }
        let windows = windows(showing: old)
        windows.forEach { $0.state.workspace?.flushSaves() }
        do {
            try FileManager.default.moveItem(at: old, to: target)
        } catch {
            PaletteDialog.error(error, title: "Couldn't rename “\(old.lastPathComponent)”")
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
    func spaceMovedExternally(from old: URL, to target: URL) {
        SpaceLinks.shared.moved(from: old, to: target)
        relocate(windows(showing: old), from: old, to: target, external: true)
        SpaceList.replace(old, with: target)
    }

    private func relocate(_ windows: [MainWindowController], from old: URL, to target: URL, external: Bool = false) {
        if external {
            for window in windows {
                window.state.pendingSession = window.state.workspace?.sessionAfterMoving(to: target)
            }
        }
        // Persist under the old key first so the saved state moves along.
        windows.forEach { $0.state.workspace?.close() }
        SpaceStore.move(from: old, to: target)
        SpaceRepository.shared.noteMoved(from: old, to: target)
        for window in windows {
            window.state.relocatingSpace = true
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
    private static let defaults: UserDefaults = {
        guard SpaceRepository.isTestHost else { return .standard }
        let name = "dev.bierdav.Typewright.tests.spaces"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

    /// Where the spaces live; the same as `SpaceRepository.shared.root`, without opening the repository.
    static let repository = SpaceRepository.defaultRoot.standardizedFileURL

    static var all: [URL] {
        order(stored: stored, repository: SpaceFolders.spaces(in: repository))
    }

    /// Stored entries that still exist (older ones may be files or links), then repository folders not stored yet.
    static func order(stored: [String], repository: [URL]) -> [URL] {
        var seen = Set<String>()
        let known = stored
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Workspace.root(of: $0).resolvingSymlinksInPath() }
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
        get { defaults.stringArray(forKey: key) ?? [] }
        set {
            defaults.set(newValue, forKey: key)
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
