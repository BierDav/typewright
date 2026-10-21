import SwiftUI

@main
struct TypewrightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Settings live in SettingsWindowController; this scene only hosts the menus.
        Settings { EmptyView() }
        .commands { AppCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.apply(UserDefaults.standard.string(forKey: "appearance") ?? "")
        BuiltinCompiler.warmUp()
        Task { await CompilerManager.shared.setUp() }
        Task { await LanguageServerManager.shared.setUp() }
        SyncService.shared.restart()
        Opener.shared.restoreSession()
        Opener.shared.installSpaceShortcuts()
        Opener.shared.installNavigationButtons()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if Invites.handles(url) { Invites.open(url) } else { Opener.shared.open(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Opener.shared.showEmptyWindow() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Opener.shared.isTerminating = true
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindowController.shared.show() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { Opener.shared.newWindow() }
                .keyboardShortcut("n")
            Button("Link Folder as Space…") { Opener.shared.openPanel() }
                .keyboardShortcut("o")
            Menu("Spaces") {
                ForEach(SpaceList.all, id: \.self) { url in
                    Button(url.lastPathComponent) { Opener.shared.open(url) }
                }
            }
        }
        CommandGroup(after: .saveItem) {
            Button("Move File…") { Opener.shared.showPalette(page: "file.move") }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Close Space") { Opener.shared.closeSpace() }
                .keyboardShortcut("w", modifiers: [.command, .control])
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Space…") { Opener.shared.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandMenu("Navigate") {
            Button("Back") { Opener.shared.goBack() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
            Button("Forward") { Opener.shared.goForward() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
        }
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { Opener.shared.showPalette() }
                .keyboardShortcut("k")
            Button("Show Spaces") { Opener.shared.toggleSpaces() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Toggle Sidebar") { Opener.shared.toggleSidebar() }
                .keyboardShortcut("s")
        }
    }
}
