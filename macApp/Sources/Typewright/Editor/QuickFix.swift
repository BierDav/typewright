import AppKit

/// An inline fix for a diagnostic, offered in the docs popup and with ⌥↩.
struct QuickFix: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// nil for a note that can't be run, like a lookup still in progress.
    let run: (@MainActor () -> Void)?
}

/// Fixes the app knows for typst's diagnostics.
@MainActor
enum QuickFixes {
    static func fixes(for diagnostic: Diagnostic, root: URL) -> [QuickFix] {
        if let family = missingFont(in: diagnostic.message) { return fontFixes(family, root: root) }
        return []
    }

    /// The family from typst's "unknown font family: poppins".
    static func missingFont(in message: String) -> String? {
        let prefix = "unknown font family: "
        guard message.hasPrefix(prefix) else { return nil }
        let family = message.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return family.isEmpty ? nil : family
    }

    // MARK: - Missing fonts

    /// Finds the family on Google Fonts and offers places to put it: Typewright's own fonts, a space font folder
    /// or a machine font folder, existing or new.
    private static func fontFixes(_ name: String, root: URL) -> [QuickFix] {
        fontInstallFixes(name, root: root) + [searchFix(name)]
    }

    /// Looks the font up on the web, for fonts Google Fonts doesn't have or to compare sources.
    private static func searchFix(_ name: String) -> QuickFix {
        QuickFix(id: "font.search", title: "Search “\(name)” on Google", icon: "magnifyingglass") {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: "\(name) font")]
            if let url = components.url { NSWorkspace.shared.open(url) }
        }
    }

    private static func fontInstallFixes(_ name: String, root: URL) -> [QuickFix] {
        let fonts = FontLibrary.shared
        if fonts.catalog.isEmpty {
            Task { await fonts.loadCatalog() }
            let note = fonts.lastError ?? "Looking up “\(name)” on Google Fonts…"
            return [QuickFix(id: "font.lookup", title: note, icon: "hourglass", run: nil)]
        }
        guard let font = fonts.googleFont(named: name) else {
            return [
                QuickFix(id: "font.none", title: "“\(name)” isn’t on Google Fonts", icon: "questionmark.circle", run: nil),
                QuickFix(id: "font.settings", title: "Add a Font Folder in Settings…", icon: "character.textbox") {
                    SettingsWindowController.shared.show(tab: 2)
                },
            ]
        }
        let family = font.family
        if fonts.downloads[family] != nil {
            return [QuickFix(id: "font.downloading", title: "Downloading “\(family)”…", icon: "arrow.down.circle", run: nil)]
        }
        var fixes = [QuickFix(id: "font.app", title: "Install “\(family)” in Typewright", icon: "arrow.down.circle") {
            Task { await fonts.download(family) }
        }]
        for folder in fonts.spaceFolders(for: root) {
            fixes.append(QuickFix(id: "font.space.\(folder.path)", title: "Save “\(family)” to \(display(folder, root: root))",
                                  icon: "folder") {
                Task { await fonts.download(family, into: folder) }
            })
        }
        fixes.append(QuickFix(id: "font.space.new", title: "Save “\(family)” to a New Space Font Folder…",
                              icon: "folder.badge.plus") {
            guard let folder = chooseFolder(in: root, message: "Choose a folder in the space for its fonts") else { return }
            let relative = folder.path.hasPrefix(root.path + "/") ? "./" + folder.path.dropFirst(root.path.count + 1) : folder.path
            if !fonts.spacePaths.contains(relative) { fonts.spacePaths.append(relative) }
            Task { await fonts.download(family, into: folder) }
        })
        for path in fonts.machinePaths {
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            fixes.append(QuickFix(id: "font.machine.\(path)", title: "Save “\(family)” to \(display(folder, root: root))",
                                  icon: "desktopcomputer") {
                Task { await fonts.download(family, into: folder) }
            })
        }
        fixes.append(QuickFix(id: "font.machine.new", title: "Save “\(family)” to a New Machine Font Folder…",
                              icon: "folder.badge.plus") {
            guard let folder = chooseFolder(in: nil, message: "Choose a folder every space searches for fonts") else { return }
            if !fonts.machinePaths.contains(folder.path) { fonts.machinePaths.append(folder.path) }
            Task { await fonts.download(family, into: folder) }
        })
        return fixes
    }

    /// Space folders read relative to the space; others with `~` for the home folder.
    private static func display(_ folder: URL, root: URL) -> String {
        if folder.path.hasPrefix(root.path + "/") { return String(folder.path.dropFirst(root.path.count + 1)) }
        return folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func chooseFolder(in directory: URL?, message: String) -> URL? {
        PaletteFiles.folder(message, initial: directory)
    }
}
