import SwiftUI
import UniformTypeIdentifiers

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
        Opener.shared.restoreSession()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Opener.shared.open($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Opener.shared.showHome() }
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
            Button("New Project…") { Opener.shared.newProject() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open…") { Opener.shared.openPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(Recents.all.prefix(10), id: \.self) { url in
                    Button(url.lastPathComponent) { Opener.shared.open(url) }
                }
            }
        }
        CommandGroup(after: .saveItem) {
            Button("Close Project") { Opener.shared.closeProject() }
                .keyboardShortcut("w", modifiers: [.command, .control])
        }
        CommandGroup(after: .windowArrangement) {
            Button("Typewright Home") { Opener.shared.showHome() }
        }
    }
}
