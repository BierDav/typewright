import SwiftUI

@main
enum TypewrightMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--cli" {
            exit(TypewrightCLI.run(Array(CommandLine.arguments.dropFirst(2))))
        }
        TypewrightApp.main()
    }
}

struct TypewrightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Settings live in SettingsWindowController; this scene only hosts the menus.
        Settings { EmptyView() }
        .commands { AppCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuLayout = KeyLayout.current

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.apply(UserDefaults.standard.string(forKey: "appearance") ?? "")
        BuiltinCompiler.warmUp()
        Task { await CompilerManager.shared.setUp() }
        Task { await LanguageServerManager.shared.setUp() }
        if !Self.isTesting { Task { await PackageLibrary.shared.refreshUniverse() } }
        SyncService.shared.restart()
        Opener.shared.restoreSession()
        LibraryWatcher.shared.start()
        // Tests run inside the app and must not commit to the user's spaces.
        if !Self.isTesting {
            SpaceRepository.shared.setLFSLimit(megabytes: SyncService.shared.lfsThresholdMB)
            CommitScheduler.shared.start()
        }
        Opener.shared.installShortcuts()
        Opener.shared.installNavigationButtons()
        // SwiftUI builds its menus once; keep their key equivalents following the layout.
        menuLayout = KeyLayout.current
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMenusIfNeeded() }
        }
    }

    private func updateMenusIfNeeded() {
        guard KeyLayout.current != menuLayout else { return }
        menuLayout = KeyLayout.current
        KeyLayout.updateMenus()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if Invites.handles(url) { Invites.open(url) } else { Opener.shared.openFromOutside(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Opener.shared.showEmptyWindow() }
        return false
    }

    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Pending edits reach disk and the history before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isTesting else { return .terminateNow }
        Opener.shared.prepareToQuit()
        guard SpaceRepository.shared.isOpen else { return .terminateNow }
        Task { @MainActor in
            await CommitScheduler.shared.commitNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Opener.shared.prepareToQuit()
    }
}

struct AppCommands: Commands {
    private var keys: Shortcuts { KeyLayout.current.shortcuts }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindowController.shared.show() }
                .keyboardShortcut(keys.settings)
        }
        CommandGroup(replacing: .newItem) {
            Button("New File…") { Opener.shared.newFile() }
                .keyboardShortcut(keys.newFile)
                .disabled(Opener.shared.keyState?.workspace == nil)
            Button("New Window") { Opener.shared.newWindow() }
                .keyboardShortcut(keys.newWindow)
            Button("New Space") { Opener.shared.newSpace(in: Opener.shared.keyState) }
            Button("Import Folder as Space…") { Opener.shared.openPanel() }
                .keyboardShortcut(keys.openSpace)
            Menu("Spaces") {
                ForEach(SpaceList.all, id: \.self) { url in
                    Button(url.lastPathComponent) { Opener.shared.open(url) }
                }
            }
        }
        CommandGroup(after: .saveItem) {
            Button("Move File…") { Opener.shared.showPalette(page: "file.move") }
                .keyboardShortcut(keys.moveFile)
            Button("Show File History…") { Opener.shared.showFileHistory() }
            Button("Recently Deleted…") { Opener.shared.showRecentlyDeleted() }
            Button("Close Space") { Opener.shared.closeSpace() }
                .keyboardShortcut(keys.closeSpace)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Space…") { Opener.shared.showSearch() }
                .keyboardShortcut(keys.findInSpace)
        }
        CommandMenu("Navigate") {
            Button("Back") { Opener.shared.goBack() }
                .keyboardShortcut(keys.back)
            Button("Forward") { Opener.shared.goForward() }
                .keyboardShortcut(keys.forward)
        }
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { Opener.shared.showPalette() }
                .keyboardShortcut(keys.palette)
            Button("Show Spaces") { Opener.shared.toggleSpaces() }
                .keyboardShortcut(keys.showSpaces)
            Button("Toggle Sidebar") { Opener.shared.toggleSidebar() }
                .keyboardShortcut(keys.sidebar)
            Button("Cycle Preview Mode") { Opener.shared.togglePreview() }
                .keyboardShortcut(keys.togglePreview)
            Button("Preview Current File") { Opener.shared.previewCurrentFile() }
                .keyboardShortcut(keys.previewCurrentFile)
        }
    }
}
