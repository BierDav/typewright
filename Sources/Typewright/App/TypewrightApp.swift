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
        Opener.shared.restoreSession()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Opener.shared.open($0) }
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
            Button("Open Space…") { Opener.shared.openPanel() }
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
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { Opener.shared.showPalette() }
                .keyboardShortcut("k")
            Button("Show Spaces") { Opener.shared.toggleSpaces() }
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
    }
}
