import SwiftUI

struct HomeView: View {
    @State private var recents: [URL] = []
    @State private var query = ""
    @State private var showClone = false

    private var filtered: [URL] {
        query.isEmpty ? recents : recents.filter {
            $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            HomeDetail()
        }
        .navigationTitle("Typewright Home")
        .sheet(isPresented: $showClone) { CloneSheet() }
        .onAppear {
            recents = Recents.all
        }
    }

    private var sidebar: some View {
        List {
            Section {
                Button { Opener.shared.newProject() } label: {
                    Label("New Project…", systemImage: "plus.rectangle.on.folder")
                }
                Button { Opener.shared.openPanel() } label: {
                    Label("Open…", systemImage: "folder")
                }
                Button { showClone = true } label: {
                    Label("Clone Repository…", systemImage: "arrow.triangle.branch")
                }
            }
            .buttonStyle(.plain)

            Section("Recent") {
                ForEach(filtered, id: \.self) { url in
                    RecentRow(url: url)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 1) { Opener.shared.open(url) }
                        .contextMenu {
                            Button("Open") { Opener.shared.open(url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                            Button("Remove from Recents") {
                                Recents.remove(url)
                                recents = Recents.all
                            }
                        }
                }
                if filtered.isEmpty {
                    Text(query.isEmpty ? "No Recent Projects" : "No Results")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
    }
}

private struct RecentRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let path = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard let branch = Recents.branch(of: url) else { return path }
        return "\(path) · \(branch)"
    }
}

private struct HomeDetail: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @Bindable private var compilers = CompilerManager.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Typewright").font(.largeTitle.bold())
                Text("Choose a template to get started")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                ForEach(ProjectTemplate.all) { t in
                    TemplateCard(template: t)
                }
            }
            .padding(.top, 28)
            Spacer()

            HStack(spacing: 28) {
                Picker(selection: $compilers.selection) {
                    Text("Newest installed").tag(CompilerManager.automatic)
                    if compilers.systemBinary != nil { Text("System typst").tag(CompilerManager.system) }
                    ForEach(compilers.installed, id: \.self) { Text("Typst \($0)").tag($0) }
                } label: {
                    Label("Compiler", systemImage: "shippingbox")
                }
                .fixedSize()
                Picker(selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Label("Theme", systemImage: "moon")
                }
                .fixedSize()
                Button { SettingsWindowController.shared.show() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .padding(.bottom, 18)

            StatusBar()
        }
        .onChange(of: appearance) { _, v in Appearance.apply(v) }
    }
}

private struct TemplateCard: View {
    let template: ProjectTemplate
    @State private var hovering = false

    var body: some View {
        Button { Opener.shared.newProject(template) } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white)
                    .frame(width: 96, height: 128)
                    .overlay {
                        Image(systemName: template.symbol)
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.tint)
                    }
                    .shadow(color: .black.opacity(0.25), radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(-5)
                            .opacity(hovering ? 1 : 0)
                    }
                Text(template.name).font(.callout)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Compiler state and download progress.
struct StatusBar: View {
    private var compilers: CompilerManager { .shared }

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            if let (version, progress) = compilers.downloads.first {
                Text("Downloading Typst \(version)…")
                ProgressView(value: progress).frame(width: 120).controlSize(.small)
            } else if let error = compilers.lastError {
                Text(error).foregroundStyle(.red).lineLimit(1)
            } else {
                Text(compilers.activeBinary == nil ? "No Typst compiler installed" : compilers.activeDescription)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 28)
    }
}

private struct CloneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var parent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Repository").font(.title2.bold())
            TextField("URL", text: $remote, prompt: Text("https://github.com/user/repo.git"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Directory:")
                Text(parent.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { parent = url }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clone") {
                    running = true
                    error = nil
                    Task {
                        error = await Opener.shared.clone(remote.trimmingCharacters(in: .whitespaces), into: parent)
                        running = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(remote.isEmpty || running)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
