import AppKit
import SwiftUI
import TypewrightCore

/// Deleted files and folders, found again in the history: there's no trash, deleting is a commit.
@MainActor
enum RecentlyDeleted {
    private static var controller: NSWindowController?
    private static var model: RecentlyDeletedModel?

    /// Shows the window scoped to `folder` (a space or a folder in one); nil lists the whole library.
    static func show(in folder: URL? = nil) {
        if let controller, let model {
            model.scope = folder
            Task { await model.load() }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = RecentlyDeletedModel(scope: folder)
        let host = NSHostingController(rootView: RecentlyDeletedView(model: model))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.title = "Recently Deleted"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 820, height: 520))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RecentlyDeleted")
        if !window.setFrameUsingName("RecentlyDeleted") { window.center() }
        let controller = NSWindowController(window: window)
        self.controller = controller
        self.model = model
        controller.showWindow(nil)
    }
}

@MainActor @Observable
final class RecentlyDeletedModel {
    var scope: URL?
    private(set) var items: [DeletedItem] = []
    private(set) var isLoading = false
    var selection: DeletedItem.ID?
    var query = ""
    /// The selected item's content, for the preview.
    private(set) var preview: FileContent?
    @ObservationIgnored private let repository: SpaceRepository

    init(scope: URL?, repository: SpaceRepository? = nil) {
        self.scope = scope
        self.repository = repository ?? .shared
    }

    var scopeName: String? {
        guard let scope, let path = repository.relativePath(of: scope) else { return nil }
        return path
    }

    var visible: [DeletedItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    var selected: DeletedItem? { items.first { $0.id == selection } }

    func load() async {
        isLoading = true
        items = await repository.deleted(in: scope)
        isLoading = false
        if selected == nil { selection = visible.first?.id }
        await loadPreview()
    }

    func loadPreview() async {
        preview = nil
        guard let item = selected, item.kind == .file else { return }
        if let stash = item.stash {
            let file = repository.root.appendingPathComponent(".jj/typewright/deleted/\(stash)/files/file")
            preview = (try? Data(contentsOf: file)).map(FileContent.data)
        } else if let commit = item.lastCommit {
            preview = await repository.content(of: repository.url(of: item.path), at: commit)
        }
    }

    enum Outcome { case restored(URL), exists, failed }

    /// Restores at the item's own place, or with a free name when `keepBoth`.
    func restore(_ item: DeletedItem, keepBoth: Bool = false) async -> Outcome {
        var url = repository.url(of: item.path)
        if keepBoth {
            let dir = url.deletingLastPathComponent()
            let ext = item.kind == .folder || url.pathExtension.isEmpty ? nil : url.pathExtension
            let base = ext == nil ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            url = dir.appendingPathComponent(uniqueName(name: base, ext: ext, exists: ExistsIn(dir)))
        }
        switch await repository.restore(item, to: url) {
        case .restored:
            // A whole space comes back into the list.
            if !item.path.contains("/") { SpaceList.add(url) }
            await load()
            return .restored(url)
        case .exists: return .exists
        case .failed: return .failed
        }
    }
}

struct RecentlyDeletedView: View {
    @Bindable var model: RecentlyDeletedModel
    @AppStorage("revealAfterRestore") private var revealAfterRestore = true
    @State private var failure: String?

    var body: some View {
        VSplitView {
            list.frame(minHeight: 180)
            detail.frame(minHeight: 140, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search Deleted Items")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let name = model.scopeName {
                    Picker("Show", selection: Binding(get: { model.scope != nil }, set: { inScope in
                        if !inScope { model.scope = nil }
                        Task { await model.load() }
                    })) {
                        Text("All Spaces").tag(false)
                        Text(name).tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .frame(minWidth: 560, minHeight: 380)
        .task { await model.load() }
        .onChange(of: model.selection) { Task { await model.loadPreview() } }
        .onReceive(NotificationCenter.default.publisher(for: SpaceRepository.didCommit)) { _ in
            Task { await model.load() }
        }
        .alert("Couldn't Restore", isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.visible.isEmpty && !model.isLoading {
            ContentUnavailableView {
                Label(model.query.isEmpty ? "Nothing Deleted" : "No Results", systemImage: "trash.slash")
            } description: {
                Text(model.query.isEmpty ? "Files you delete in Typewright show up here, so you can bring them back."
                    : "No deleted item matches “\(model.query)”.")
            }
        } else {
            Table(model.visible, selection: $model.selection) {
                TableColumn("Name") { item in
                    Label(item.name, systemImage: item.kind == .folder ? "folder" : Self.icon(item.name))
                }
                TableColumn("Where") { item in
                    Text((item.path as NSString).deletingLastPathComponent.replacingOccurrences(of: "/", with: " › "))
                        .foregroundStyle(.secondary)
                }
                TableColumn("Deleted") { item in
                    Text(item.time, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .help(item.time.formatted(date: .complete, time: .shortened))
                }
                .width(min: 90, ideal: 120)
            }
            .contextMenu(forSelectionType: DeletedItem.ID.self) { ids in
                if let item = model.items.first(where: { ids.contains($0.id) }) {
                    Button("Restore") { Task { await restore(item) } }
                    if canShowHistory(item) { Button("Show History…") { showHistory(item) } }
                }
            } primaryAction: { ids in
                if let item = model.items.first(where: { ids.contains($0.id) }) { Task { await restore(item) } }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selected {
            switch (item.kind, model.preview) {
            case (.folder, _):
                ContentUnavailableView {
                    Label(item.name, systemImage: "folder")
                } description: {
                    Text(item.files == 1 ? "1 file" : "\(item.files) files")
                }
            case (_, .text(let text)?):
                ScrollView([.vertical, .horizontal]) {
                    Text(String(text.prefix(20_000)))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            case (_, .data(let data)?):
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                } else {
                    ContentUnavailableView("No Preview", systemImage: "doc", description: Text(item.name))
                }
            default:
                ContentUnavailableView("No Preview", systemImage: "doc", description: Text(item.name))
            }
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open After Restoring", isOn: $revealAfterRestore)
                .toggleStyle(.checkbox)
            Spacer()
            if let item = model.selected, canShowHistory(item) {
                Button("Show History…") { showHistory(item) }
            }
            Button("Restore") {
                if let item = model.selected { Task { await restore(item) } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selected == nil)
        }
        .padding(12)
        .background(.bar)
    }

    private func canShowHistory(_ item: DeletedItem) -> Bool { item.kind == .file && item.lastCommit != nil }

    private func restore(_ item: DeletedItem, keepBoth: Bool = false) async {
        switch await model.restore(item, keepBoth: keepBoth) {
        case .restored(let url):
            if revealAfterRestore { Opener.shared.open(url) }
        case .exists:
            let choice = PaletteDialog.choose("“\(item.name)” already exists",
                detail: "Something else is at its place now. Keep both, with a number added to the restored one?",
                choices: [
                    PaletteDialog.Choice(id: "both", title: "Keep Both", icon: "plus.square.on.square"),
                    PaletteDialog.Choice(id: "cancel", title: "Cancel", icon: "xmark"),
                ])
            if choice == "both" { await restore(item, keepBoth: true) }
        case .failed:
            failure = SpaceRepository.shared.lastError ?? "The history doesn't have “\(item.name)” anymore."
        }
    }

    /// The file's history works without the file: it starts with the deletion.
    private func showHistory(_ item: DeletedItem) {
        let url = SpaceRepository.shared.url(of: item.path)
        let space = SpaceRepository.shared.url(of: item.space)
        Opener.shared.showHistory(of: url, inSpace: space)
    }

    private static func icon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "typ": return "t.square"
        case "md", "markdown": return "m.square"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "bib": return "books.vertical"
        default: return "doc"
        }
    }
}

#Preview {
    RecentlyDeletedView(model: RecentlyDeletedModel(scope: nil))
        .frame(width: 820, height: 520)
}
