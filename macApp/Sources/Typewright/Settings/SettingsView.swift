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
        func tab(_ title: String, _ symbol: String, _ view: some View, height: CGFloat = 520) -> NSTabViewItem {
            let host = NSHostingController(rootView: view.frame(width: 560, height: height))
            host.sizingOptions = []
            host.title = title
            host.preferredContentSize = NSSize(width: 560, height: height)
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(tab("General", "gearshape", GeneralSettings()))
        tabs.addTabViewItem(tab("Editor", "textformat", EditorSettings()))
        tabs.addTabViewItem(tab("Fonts", "character.textbox", FontSettings()))
        tabs.addTabViewItem(tab("Packages", "shippingbox", PackageSettings()))
        tabs.addTabViewItem(tab("Devices", "arrow.triangle.2.circlepath", DeviceSettings()))
        // Taller, so the retention rules and Restore Defaults fit without scrolling.
        tabs.addTabViewItem(tab("History", "clock.arrow.circlepath", HistorySettings(), height: 620))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Opens on a tab: 0 General, 1 Editor, 2 Fonts, 3 Packages, 4 Devices, 5 History.
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
    @AppStorage(PreviewPosition.defaultsKey) private var previewPosition = PreviewPosition.trailing
    @AppStorage(DarkModeWarning.defaultsKey) private var warnsAboutDarkMode = true
    @Bindable private var compilers = CompilerManager.shared
    @Bindable private var textSize = PreviewTextSize.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: appearance) { _, v in Appearance.apply(v) }
            }

            Section {
                Picker("Position", selection: $previewPosition) {
                    ForEach(PreviewPosition.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $textSize.size, in: PreviewTextSize.range, step: 1) {
                    LabeledContent("Markdown text size", value: "\(Int(textSize.size.rounded())) px")
                }
                Toggle("Warn when HTML ignores dark mode", isOn: $warnsAboutDarkMode)
            } header: {
                Text("Preview")
            } footer: {
                Text("Pinching the Markdown editor changes this size. HTML previews use browser zoom.")
                    .foregroundStyle(.secondary)
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
    @AppStorage("editorFontName") private var fontName = ""
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @State private var fontFamilies: [String] = []
    @AppStorage("glidingCursor") private var glidingCursor = true
    @AppStorage("wrapGuide") private var wrapGuide = false
    @AppStorage("wrapColumn") private var wrapColumn = 80
    @AppStorage("vimMode") private var vimMode = false
    @AppStorage("concealMath") private var concealMath = true
    @AppStorage("autoClose") private var autoClose = true
    @AppStorage(KeyLayout.defaultsKey) private var layoutID = BuiltinLayout.standard.rawValue
    @ObservedObject private var layouts = KeyLayoutStore.shared
    @State private var showsLayoutEditor = false

    private var currentLayout: KeyLayout {
        layouts.all.first { $0.id == layoutID } ?? KeyLayout(builtIn: .standard)
    }

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $fontName) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Stepper("Size: \(Int(fontSize)) pt", value: $fontSize, in: 9...32)
                Text("#let greeting = \"Hello, Typst\"")
                    .font(Font(EditorFont.font(name: fontName, size: fontSize)))
            }
            Section {
                Picker("Layout", selection: $layoutID) {
                    ForEach(layouts.all) { layout in
                        Text(layout.name).tag(layout.id)
                    }
                }
                Button("Edit Layout…") { showsLayoutEditor = true }
            } header: {
                Text("Keyboard")
            } footer: {
                Text(currentLayout.summary).foregroundStyle(.secondary)
            }
            Section("Cursor") {
                Toggle("Gliding cursor", isOn: $glidingCursor)
                Text("The cursor slides to its new position instead of jumping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Vim key bindings", isOn: $vimMode)
                Text("Normal, insert and visual modes with Vim's motions and operators. ⌘ shortcuts keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Typing") {
                Toggle("Close brackets and quotes", isOn: $autoClose)
                Text("Typing ( [ { \" $ or ` adds its closer, typing the closer steps over it, and a selection gets wrapped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Math") {
                Toggle("Show math and escapes as rendered", isOn: $concealMath)
                Text("Symbol names show as their symbol, text in math loses its quotes and escapes their backslash, like $12\"k\"Omega$ as $12kΩ$ and 1\\. as 1., except right at the cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Wrapping") {
                Toggle("Wrap lines at a column", isOn: $wrapGuide)
                if wrapGuide {
                    Stepper("Column: \(wrapColumn)", value: $wrapColumn, in: TypstTextView.wrapColumns)
                }
                Text("Lines wrap at the guide, or at the window edge when it's narrower. Hold ⌘ and drag the guide to move it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
                        LanguageServerSection()
        }
        .formStyle(.grouped)
        .onAppear { fontFamilies = EditorFont.families }
        .sheet(isPresented: $showsLayoutEditor) {
            LayoutEditorView(selectedID: $layoutID)
        }
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
            LabeledContent("solveng \(SolvengSupport.version)", value: "Built in")
        } header: {
            Text("Language Servers")
        } footer: {
            if let error = server.lastError {
                Text(error).foregroundStyle(.red)
            } else {
                Text("Completions pop up while typing, or with ⌥⎋ or ⌃Space. ⌘-click an import, symbol, path or font name to open it. Uses tinymist from github.com/Myriad-Dreamin/tinymist, and solveng's language support (github.com/BierDav/solveng) for its calculations.")
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
                Text("Looked up in the previewed file’s folder and every folder above it, so a document finds its fonts even outside a space and in Quick Look.")
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
        guard let folder = PaletteFiles.folder("Add Font Folder") else { return }
        if !fonts.machinePaths.contains(folder.path) { fonts.machinePaths.append(folder.path) }
    }
}

struct PackageSettings: View {
    @Bindable private var packages = PackageLibrary.shared
    @State private var spec = ""
    @State private var namespace = ""
    @State private var repository = ""

    var body: some View {
        Form {
            Section {
                ForEach(packages.namespaces) { ns in
                    HStack {
                        Image(systemName: ns.target == nil ? "folder.fill" : "link").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(ns.name)")
                            Text(ns.packages.isEmpty ? "No packages"
                                 : ns.packages.map { "\($0.name):\($0.version)" }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        if ns.canUpdate {
                            Button { Task { await packages.update(ns) } } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .disabled(!packages.cloning.isEmpty)
                                .help("Update from GitHub")
                        }
                        revealButton(ns.target ?? ns.url)
                        if ns.target != nil { removeButton { packages.unlink(ns) } }
                    }
                    .help((ns.target ?? ns.url).path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
                HStack {
                    TextField("Namespace", text: $namespace, prompt: Text("Namespace (defaults to the folder name)"))
                        .labelsHidden()
                    Button("Link Folder…", action: linkFolder)
                }
                HStack {
                    TextField("GitHub Repository", text: $repository, prompt: Text("owner/repo or a GitHub link"))
                        .labelsHidden()
                        .onSubmit(clone)
                    if packages.cloning.isEmpty {
                        Button("Clone", action: clone)
                            .disabled(repository.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            } header: {
                Text("Local Packages")
            } footer: {
                if let error = packages.linkError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("A linked folder becomes a namespace: with my-libs/1.0.0/ inside, or a package repository my-libs/ whose typst.toml says version 1.0.0, linked as “personal”, documents import \"@personal/my-libs:1.0.0\". Unlinking keeps your files. A cloned package repository goes into the namespace above, or “local”, as <name>/<version>/ from its typst.toml.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    TextField("Package", text: $spec, prompt: Text("@preview/cetz:0.3.1"))
                        .labelsHidden()
                        .onSubmit(download)
                    if packages.downloading.isEmpty {
                        Button { download() } label: { Label("Download", systemImage: "arrow.down.circle") }
                            .disabled(spec.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                ForEach(packages.downloaded) { package in
                    HStack {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
                        Text(package.name)
                        Text(package.version).foregroundStyle(.secondary)
                        Spacer()
                        revealButton(package.url)
                        removeButton { packages.remove(package) }
                    }
                }
            } header: {
                Text("Typst Universe")
            } footer: {
                if let error = packages.downloadError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Downloaded automatically when a document imports \"@preview/…\". Download one ahead of time, e.g. to work offline. Shared with the typst CLI.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { packages.refresh() }
    }

    private func download() {
        let spec = spec
        Task { if await packages.download(spec) { self.spec = "" } }
    }

    private func clone() {
        let input = repository
        let name = namespace.trimmingCharacters(in: .whitespaces)
        Task {
            guard await packages.clone(input, into: name.isEmpty ? "local" : name) else { return }
            repository = ""
            namespace = ""
        }
    }

    private func linkFolder() {
        guard let url = PaletteFiles.folder("Link Package Folder") else { return }
        let name = namespace.trimmingCharacters(in: .whitespaces)
        packages.link(url, as: name.isEmpty ? url.lastPathComponent : name)
        if packages.linkError == nil { namespace = "" }
    }

    private func revealButton(_ url: URL) -> some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove")
    }
}
