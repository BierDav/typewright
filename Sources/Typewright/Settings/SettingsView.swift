import AppKit
import SwiftUI

/// Native toolbar-tab preferences window; SwiftUI's Settings scene rebuilds its toolbar on every switch.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        func tab(_ title: String, _ symbol: String, _ view: some View) -> NSTabViewItem {
            let host = NSHostingController(rootView: view.frame(width: 560, height: 520))
            host.sizingOptions = []
            host.title = title
            host.preferredContentSize = NSSize(width: 560, height: 520)
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(tab("General", "gearshape", GeneralSettings()))
        tabs.addTabViewItem(tab("Editor", "textformat", EditorSettings()))
        tabs.addTabViewItem(tab("Fonts", "character.textbox", FontSettings()))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Opens on a tab: 0 General, 1 Editor, 2 Fonts.
    func show(tab: Int) {
        (contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab
        show()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct GeneralSettings: View {
    @AppStorage("ignoreLibraryWarnings") private var ignoreLibraryWarnings = true
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @Bindable private var compilers = CompilerManager.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: appearance) { _, v in Appearance.apply(v) }
            }

            Section("Diagnostics") {
                Toggle("Ignore library warnings", isOn: $ignoreLibraryWarnings)
                Text("Hide warnings from imported packages (e.g. @preview/…). Errors are always shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Use", selection: $compilers.selection) {
                    Text("Built-in (Typst \(BuiltinCompiler.version))").tag(CompilerManager.builtin)
                    Text("Newest installed").tag(CompilerManager.automatic)
                    if compilers.systemBinary != nil {
                        Text("System typst").tag(CompilerManager.system)
                    }
                    ForEach(compilers.installed, id: \.self) { Text("Typst \($0)").tag($0) }
                }
                ForEach(compilers.releases) { release in
                    CompilerRow(release: release, isLatest: release == compilers.latestRelease)
                }
                if let system = compilers.systemBinary {
                    LabeledContent("System", value: system.path)
                }
            } header: {
                HStack {
                    Text("Typst Compiler")
                    Spacer()
                    Button { Task { await compilers.refreshReleases() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh releases")
                }
            } footer: {
                if let error = compilers.lastError {
                    Text(error).foregroundStyle(.red)
                } else if compilers.active != .builtin {
                    Label("External compilers are slower: every keystroke is saved to disk and recompiled by a separate typst process.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Compilers are downloaded from github.com/typst/typst.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CompilerRow: View {
    let release: TypstRelease
    let isLatest: Bool
    private var compilers: CompilerManager { .shared }

    var body: some View {
        let installed = compilers.installed.contains(release.version)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(release.version).font(.headline)
                    if isLatest { badge("Latest", .blue) }
                    if installed { badge("Installed", .green) }
                }
                Text(isLatest ? "The current Typst compiler. Recommended." : "For documents that don't build on the latest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = compilers.downloads[release.version] {
                ProgressView(value: progress).frame(width: 100)
            } else if installed {
                Button("Remove", role: .destructive) { compilers.remove(release.version) }
            } else {
                Button { Task { await compilers.download(release) } } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct EditorSettings: View {
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("glidingCursor") private var glidingCursor = true

    var body: some View {
        Form {
            Section("Font") {
                Stepper("Size: \(Int(fontSize)) pt", value: $fontSize, in: 9...32)
                Text("#let greeting = \"Hello, Typst\"")
                    .font(.system(size: fontSize, design: .monospaced))
            }
            Section("Cursor") {
                Toggle("Gliding cursor", isOn: $glidingCursor)
                Text("The cursor slides to its new position instead of jumping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
                        LanguageServerSection()
        }
        .formStyle(.grouped)
    }
}

private struct LanguageServerSection: View {
    @Bindable private var server = LanguageServerManager.shared

    var body: some View {
        Section {
            Toggle("Completions and Go to Definition", isOn: $server.isEnabled)
            if let system = server.systemBinary {
                LabeledContent("tinymist", value: system.path)
            } else if server.isDownloading {
                LabeledContent("tinymist") { ProgressView().controlSize(.small) }
            } else if let version = server.downloadedVersion {
                LabeledContent("tinymist \(version)") {
                    HStack {
                        Button("Update") { Task { await server.download() } }
                        Button("Remove", role: .destructive) { server.remove() }
                    }
                }
            } else {
                LabeledContent("tinymist") {
                    Button { Task { await server.download() } } label: { Label("Download", systemImage: "arrow.down.circle") }
                }
                .disabled(!server.isEnabled)
            }
        } header: {
            Text("Language Server")
        } footer: {
            if let error = server.lastError {
                Text(error).foregroundStyle(.red)
            } else {
                Text("Completions pop up while typing, or with ⌥⎋ or ⌃Space. ⌘-click an import, symbol, path or font name to open it. Uses tinymist from github.com/Myriad-Dreamin/tinymist.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FontSettings: View {
    @Bindable private var fonts = FontLibrary.shared
    @State private var query = ""

    private var results: [FontLibrary.GoogleFont] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let matches = fonts.catalog.filter { $0.family.localizedCaseInsensitiveContains(q) }
        // Families starting with the query first, then the rest in catalog (popularity) order.
        let prefixed = matches.filter { $0.family.lowercased().hasPrefix(q.lowercased()) }
        return Array((prefixed + matches.filter { !prefixed.contains($0) }).prefix(40))
    }

    var body: some View {
        Form {
            Section {
                ForEach(fonts.spacePaths.indices, id: \.self) { i in
                    HStack {
                        TextField("Folder", text: $fonts.spacePaths[i], prompt: Text("./fonts"))
                            .labelsHidden()
                        removeButton { fonts.spacePaths.remove(at: i) }
                    }
                }
                Button("Add Folder") { fonts.spacePaths.append("./") }
            } header: {
                Text("Space Fonts")
            } footer: {
                Text("Folders inside each space, relative to its root. Their fonts are only used by that space.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(fonts.machinePaths.indices, id: \.self) { i in
                    HStack {
                        Text(fonts.machinePaths[i].replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        removeButton { fonts.machinePaths.remove(at: i) }
                    }
                }
                Button("Add Folder…") { chooseMachineFolder() }
            } header: {
                Text("Machine Fonts")
            } footer: {
                Text("Folders every space searches for fonts.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(fonts.installed, id: \.self) { family in
                    HStack {
                        Text(family)
                        Spacer()
                        removeButton { fonts.remove(family) }
                    }
                }
                TextField("Search", text: $query, prompt: Text("Search Google Fonts"))
                ForEach(results) { font in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(font.family)
                            if let category = font.category {
                                Text(category).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let progress = fonts.downloads[font.family] {
                            ProgressView(value: progress).frame(width: 100)
                        } else if fonts.installed.contains(font.family) {
                            Text("Downloaded").foregroundStyle(.secondary)
                        } else {
                            Button { Task { await fonts.download(font.family) } } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                }
            } header: {
                Text("Google Fonts")
            } footer: {
                if let error = fonts.lastError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Kept inside Typewright and available to every space, without installing them on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await fonts.loadCatalog() }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove")
    }

    private func chooseMachineFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        fonts.machinePaths += panel.urls.map(\.path).filter { !fonts.machinePaths.contains($0) }
    }
}
