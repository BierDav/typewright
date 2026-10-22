import AppKit
import SwiftUI
import TypewrightCore

/// Shows the window's command palette or full text search above everything else.
struct WindowOverlayView: View {
    let state: WindowState
    let workspace: Workspace?

    var body: some View {
        ZStack(alignment: .top) {
            if let overlay = state.overlay {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .overlay { CursorArea(isModal: true).ignoresSafeArea() }
                    .transition(.opacity)
                Group {
                    switch overlay {
                    case .palette(let page):
                        CommandPalette(state: state, workspace: workspace, startPage: page, onClose: close)
                    case .search(let allSpaces):
                        SpaceSearchView(state: state, workspace: workspace,
                                        allSpaces: allSpaces ?? (workspace == nil || state.spacesProgress > 0.5), onClose: close)
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                .padding(.top, 72)
                .padding(.bottom, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.18), value: state.overlay)
    }

    private func close() {
        state.overlay = nil
        // Back to the editor, which the palette's field took focus from.
        if let tv = workspace?.find.textView { tv.window?.makeFirstResponder(tv) }
    }
}

/// Esc still reaches an overlay when none of its fields has focus, like after clicking a row or the material.
private struct EscapeMonitor: ViewModifier {
    let action: () -> Void
    let accepts: (NSResponder?) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Overlays open in the key window; others may have their own.
                let window = NSApp.keyWindow
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 53, event.window === window, accepts(window?.firstResponder) else { return event }
                    action()
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    /// By default anything but a text view counts; those handle Esc themselves, like the fields' own handlers or Vim mode.
    func onEscapeWhenUnfocused(accepts: @escaping (NSResponder?) -> Bool = { !($0 is NSText) },
                               _ action: @escaping () -> Void) -> some View {
        modifier(EscapeMonitor(action: action, accepts: accepts))
    }
}

/// Keeps the enclosing scroll view's scrollers floating over the content, so always-visible scroll bars don't narrow the rows.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerView { ScrollerView() }
    func updateNSView(_ view: ScrollerView, context: Context) { view.apply() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScrollerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class ScrollerView: NSView {
        private var observer: (any NSObjectProtocol)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // AppKit puts the user's style back whenever the preference or a mouse changes.
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func apply() {
            guard let scroll = enclosingScrollView, scroll.scrollerStyle != .overlay else { return }
            scroll.scrollerStyle = .overlay
        }
    }
}

// MARK: - Palette model

/// One row of the palette: a command, a file or a folder.
struct PaletteItem: Identifiable {
    enum Action {
        case run(() -> Void)
        /// Runs without closing the palette, so the list can show the result, like a finished download.
        case stay(() -> Void)
        case page(PalettePage)
    }

    let id: String
    let title: String
    var subtitle: String?
    let icon: String
    var shortcut: String?
    let section: String
    /// Only shown once something is typed, like the space's files.
    var searchOnly = false
    /// Hidden words that also find the item, like "delete" for Move to Trash.
    var keywords: [String] = []
    /// The file, folder or space name inside the title, shown bold.
    var emphasis: Range<String.Index>?
    let action: Action
}

/// A step of the palette: a list to pick from or a name to type.
struct PalettePage {
    enum Kind {
        case list(() -> [PaletteItem])
        case input(initial: String, submit: (String) -> Void)
    }

    let title: String
    let placeholder: String
    let kind: Kind
}

/// Linear-style command menu: type to filter commands and files, arrows to move, Return to run.
struct CommandPalette: View {
    let state: WindowState
    let workspace: Workspace?
    var startPage: String?
    let onClose: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @State private var pages: [PalettePage] = []
    /// Where the pointer last moved over the list.
    @State private var pointer = NSEvent.mouseLocation
    @FocusState private var focused: Bool

    private var page: PalettePage? { pages.last }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !pages.isEmpty {
                    Text(pages.map(\.title).joined(separator: " › "))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "command").foregroundStyle(.secondary)
                }
                TextField(page?.placeholder ?? "Type a command or search files…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(run)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { back(); return .handled }
                    .onKeyPress(.delete) {
                        guard query.isEmpty, !pages.isEmpty else { return .ignored }
                        back()
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            if case .input = page?.kind {
                EmptyView()
            } else {
                Divider()
                list
            }
            Divider()
            footer
        }
        .frame(width: 640)
        .onEscapeWhenUnfocused(back)
        // Swiping to the space overview or another space changes what the palette offers.
        .onChange(of: context) {
            pages = []
            selection = 0
        }
        .task {
            if let startPage, case .page(let next)? = rootItems.first(where: { $0.id == startPage })?.action {
                pages = [next]
            }
            // The editor holds on to first responder until it's released; then the field can take focus.
            NSApp.keyWindow?.makeFirstResponder(nil)
            try? await Task.sleep(for: .milliseconds(30))
            focused = true
        }
        .onChange(of: query) { selection = 0 }
    }

    // MARK: List

    private var items: [PaletteItem] {
        guard case .list(let build)? = page?.kind ?? .list({ rootItems }) else { return [] }
        let all = build()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all.filter { !$0.searchOnly } }
        let scored = all.enumerated().compactMap { index, item -> (Int, Int, PaletteItem)? in
            let title = Self.score(q, item.title.lowercased())
            let subtitle = item.subtitle.flatMap { Self.score(q, $0.lowercased()) }.map { $0 + 3 }
            // Keywords only count as clear prefix or word matches, not scattered letters.
            let keyword = item.keywords.compactMap { Self.score(q, $0) }.filter { $0 < 4 }.min().map { $0 + 1 }
            guard let score = [title, subtitle, keyword].compactMap({ $0 }).min() else { return nil }
            return (score, index, item)
        }
        // Sections stay together, ordered by their best match.
        let best = Dictionary(scored.map { ($0.2.section, $0.0) }, uniquingKeysWith: min)
        return scored.sorted { a, b in
            let sa = best[a.2.section] ?? 0, sb = best[b.2.section] ?? 0
            if sa != sb { return sa < sb }
            if a.2.section != b.2.section { return a.2.section < b.2.section }
            return a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
        }.map(\.2).prefix(200).map { $0 }
    }

    /// Marks the longest of `names` that stands as its own word in a command's title, like "Move **main.typ** to Trash".
    private static func emphasizingNames(_ items: [PaletteItem], names: [String?]) -> [PaletteItem] {
        let names = Set(names.compactMap { $0 }.filter { !$0.isEmpty }).sorted { $0.count > $1.count }
        return items.map { item in
            // Rows that are just a name, like files, need no emphasis.
            guard !item.searchOnly else { return item }
            var item = item
            for name in names {
                guard let range = item.title.range(of: name), range.lowerBound > item.title.startIndex,
                      item.title[item.title.index(before: range.lowerBound)] == " ",
                      range.upperBound == item.title.endIndex || [" ", "…"].contains(item.title[range.upperBound]) else { continue }
                item.emphasis = range
                break
            }
            return item
        }
    }

    /// Lower is better: prefix, word start, substring, then scattered letters.
    static func score(_ q: String, _ text: String) -> Int? {
        fuzzyScore(query: q, text: text).map(Int.init)
    }

    private var list: some View {
        let items = items
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].section != item.section {
                            Text(item.section)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, index == 0 ? 8 : 12)
                                .padding(.bottom, 4)
                        }
                        PaletteRow(item: item, isSelected: index == selection)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = index
                                run()
                            }
                            .onContinuousHover { phase in
                                // Rows scrolling under a resting pointer don't steal the keyboard's selection.
                                guard case .active = phase, NSEvent.mouseLocation != pointer else { return }
                                pointer = NSEvent.mouseLocation
                                selection = index
                            }
                    }
                    if items.isEmpty {
                        Text("No results")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                // The visible width; a fixed width would scroll sideways.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OverlayScrollers())
            }
            .frame(height: 360)
            .onChange(of: selection) { _, index in
                if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Navigate")
            hint("↩", page.map { if case .input = $0.kind { "Create" } else { "Select" } } ?? "Run")
            hint("esc", pages.isEmpty ? "Close" : "Back")
            Spacer()
            if let workspace { Text(workspace.name).foregroundStyle(.tertiary) }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func back() {
        if pages.isEmpty { return onClose() }
        pages.removeLast()
        query = ""
        selection = 0
    }

    private func run() {
        if case .input(_, let submit)? = page?.kind {
            submit(query)
            return onClose()
        }
        let items = items
        guard items.indices.contains(selection) else { return NSSound.beep() }
        switch items[selection].action {
        case .run(let action):
            onClose()
            action()
        case .stay(let action):
            action()
        case .page(let next):
            pages.append(next)
            if case .input(let initial, _) = next.kind { query = initial } else { query = "" }
            selection = 0
        }
    }

    // MARK: Commands

    /// The space overview counts as soon as a swipe is past halfway, so the palette follows the gesture.
    private var inOverview: Bool { workspace == nil || state.spacesProgress > 0.5 }

    private struct Context: Equatable {
        let space: URL?
        let overview: Bool
    }

    private var context: Context { Context(space: workspace?.root, overview: inOverview) }

    private var rootItems: [PaletteItem] {
        let keys = KeyLayout.current.shortcuts
        var items: [PaletteItem] = []
        if let ws = workspace {
            if inOverview {
                items.append(PaletteItem(id: "overview.back", title: "Back to \(ws.name)", icon: "arrow.uturn.backward",
                                         shortcut: keys.showSpaces.display, section: "Spaces", action: .run { state.setSpacesOpen(false) }))
            } else {
                items += spaceItems(ws)
            }
        }
        let all = SpaceList.all
        let spaces = all.filter { $0.path != workspace?.root.path }
        items += spaces.map { url in
            let index = all.firstIndex(of: url) ?? 9
            return PaletteItem(id: "space:\(url.path)", title: "Open \(url.lastPathComponent)",
                               subtitle: url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                               icon: "square.stack", shortcut: index < 9 ? "⌘\(index + 1)" : nil, section: "Spaces",
                               action: .run { Opener.shared.switchToSpace(at: index, in: state) })
        }
        items = Self.emphasizingNames(items, names: [workspace?.selectedFile?.lastPathComponent,
                                                     workspace?.selectedFile?.deletingLastPathComponent().lastPathComponent,
                                                     workspace?.name] + spaces.map(\.lastPathComponent))
        items += fontItems
        items += settingsItems
        items += [
            PaletteItem(id: "spaces.new", title: "New Space", icon: "plus.square", section: "Spaces",
                        keywords: ["create space", "new folder"],
                        action: .run { DispatchQueue.main.async { Opener.shared.newSpace(in: state) } }),
            PaletteItem(id: "spaces.open", title: "Import Folder as Space…", icon: "folder.badge.plus", shortcut: keys.openSpace.display,
                        section: "Spaces", keywords: ["open folder", "link folder"],
                        action: .run { Opener.shared.openPanel(in: state) }),
            PaletteItem(id: "spaces.search", title: "Search All Spaces", icon: "magnifyingglass", section: "Spaces",
                        action: .run { DispatchQueue.main.async { state.overlay = .search(allSpaces: true) } }),
            PaletteItem(id: "app.settings", title: "Settings…", icon: "gearshape", shortcut: keys.settings.display, section: "App",
                        action: .run { SettingsWindowController.shared.show() }),
            PaletteItem(id: "app.window", title: "New Window", icon: "macwindow.badge.plus", shortcut: keys.newWindow.display, section: "App",
                        action: .run { Opener.shared.newWindow() }),
        ]
        return items
    }

    private func spaceItems(_ ws: Workspace) -> [PaletteItem] {
        let keys = KeyLayout.current.shortcuts
        var items: [PaletteItem] = []
        let file = ws.selectedFile.flatMap { ws.isInSpace($0) ? $0 : nil }
        let here = file?.deletingLastPathComponent().standardizedFileURL ?? ws.root
        for (kind, icon) in [("File", "doc.badge.plus"), ("Folder", "folder.badge.plus")] {
            items.append(PaletteItem(id: "new.\(kind).here", title: "New \(kind) in \(ws.displayName(of: here))",
                                     icon: icon, section: "Create", action: .page(namePage(kind, in: here, ws))))
            if here != ws.root {
                items.append(PaletteItem(id: "new.\(kind).root", title: "New \(kind) in \(ws.name)",
                                         icon: icon, section: "Create", action: .page(namePage(kind, in: ws.root, ws))))
            }
            items.append(PaletteItem(id: "new.\(kind).in", title: "New \(kind) in…", icon: icon, section: "Create",
                                     action: .page(PalettePage(title: "New \(kind)", placeholder: "Choose a folder…",
                                                               kind: .list { folderItems(kind, ws) }))))
        }
        if let file {
            let name = file.lastPathComponent
            if ws.selectedKind?.isEditable == true {
                items.append(PaletteItem(id: "find", title: "Find in \(name)", icon: "magnifyingglass", shortcut: keys.find.display,
                                         section: "File", action: .run { ws.find.show(replace: false) }))
                items.append(PaletteItem(id: "replace", title: "Find and Replace in \(name)", icon: "arrow.left.arrow.right",
                                         shortcut: keys.replace.display, section: "File", action: .run { ws.find.show(replace: true) }))
            }
            if ws.selectedKind == .typst, LanguageServerManager.shared.binary != nil {
                items.append(PaletteItem(id: "format", title: "Format \(name)", icon: "text.alignleft", shortcut: keys.format.display,
                                         section: "File", keywords: ["format code", "prettify", "typstyle", "reformat"],
                                         action: .run { ws.formatSelected() }))
            }
            if Workspace.isPreviewable(file) {
                let previewed = ws.previewFile == file
                items.append(PaletteItem(id: "preview", title: previewed ? "Hide Preview" : "Preview \(name)",
                                         icon: previewed ? "eye.slash" : "eye",
                                         shortcut: previewed ? nil : keys.previewCurrentFile.display,
                                         section: "File", action: .run { ws.togglePreview(file) }))
            }
            if ws.selectedKind == .typst, let tv = ws.find.textView {
                items += refactorItems(tv)
            }
            items.append(PaletteItem(id: "file.usages", title: "Find Usages of \(name)", icon: "arrow.triangle.branch",
                                     section: "File", keywords: ["references", "imports", "includes", "where used"],
                                     action: .page(PalettePage(title: "Usages of \(name)", placeholder: "Filter usages…",
                                                               kind: .list { usageItems(of: file, ws) }))))
            if FileHistory.isAvailable(for: file) {
                items.append(PaletteItem(id: "file.history", title: "Show History of \(name)…", icon: "clock.arrow.circlepath",
                                         section: "File", keywords: ["versions", "restore", "diff", "time machine"],
                                         action: .run { FileHistory.show(file, in: ws) }))
            }
            if SpaceRepository.shared.hasConflict(file) {
                items.append(PaletteItem(id: "file.conflict", title: "Resolve Conflict in \(name)…", icon: "arrow.triangle.merge",
                                         section: "File", keywords: ["merge", "sync"],
                                         action: .run { FileHistory.resolve(file, in: ws) }))
            }
            items.append(PaletteItem(id: "file.rename", title: "Rename \(name)…", icon: "pencil", section: "File",
                                     action: .page(PalettePage(title: "Rename \(name)", placeholder: "New name",
                                                               kind: .input(initial: name) { new in
                                         withAnimation(.smooth(duration: 0.25)) { ws.rename(file, to: new) }
                                     }))))
            items.append(PaletteItem(id: "file.move", title: "Move \(name) to…", icon: "folder.badge.gearshape", shortcut: keys.moveFile.display, section: "File",
                                     action: .page(PalettePage(title: "Move \(name)", placeholder: "Choose a folder…",
                                                               kind: .list { moveTargets(file, ws) }))))
            items.append(PaletteItem(id: "file.trash", title: "Move \(name) to Trash", icon: "trash", section: "File",
                                     keywords: ["delete", "remove"],
                                     action: .run { withAnimation(.smooth(duration: 0.2)) { ws.delete(file) } }))
            items.append(PaletteItem(id: "file.window", title: "Open \(name) in New Window", icon: "macwindow.badge.plus",
                                     section: "File", action: .run { Opener.shared.openInNewWindow(ws.root, file: file) }))
            items.append(PaletteItem(id: "file.finder", title: "Reveal \(name) in Finder", icon: "folder", section: "File",
                                     action: .run { NSWorkspace.shared.activateFileViewerSelecting([file]) }))
            items.append(PaletteItem(id: "file.abs", title: "Copy Absolute Path of \(name)", icon: "doc.on.doc", section: "File",
                                     action: .run { copyPath(file) }))
            items.append(PaletteItem(id: "file.rel", title: "Copy Relative Path of \(name)", icon: "doc.on.doc", section: "File",
                                     action: .run { copyPath(ws.relativePath(of: file)) }))
        }
        items.append(PaletteItem(id: "space.search", title: "Find in \(ws.name)", icon: "text.magnifyingglass", shortcut: keys.findInSpace.display,
                                 section: "Space", action: .run { DispatchQueue.main.async { state.overlay = .search(allSpaces: false) } }))
        items.append(PaletteItem(id: "preview.toggle", title: ws.previewFile == nil ? "Show Preview" : "Hide Preview",
                                 icon: ws.previewFile == nil ? "eye" : "eye.slash", shortcut: keys.togglePreview.display,
                                 section: "Space", keywords: ["preview pane", "toggle preview"],
                                 action: .run { ws.togglePreviewVisibility() }))
        for mode in RenderMode.allCases where mode != ws.renderMode {
            items.append(PaletteItem(id: "render.\(mode.rawValue)", title: "Render Preview as \(mode.rawValue.uppercased())",
                                     icon: "doc.richtext", section: "Space", action: .run { ws.renderMode = mode }))
        }
        items.append(PaletteItem(id: "space.rename", title: "Rename \(ws.name)…", icon: "pencil", section: "Space",
                                 keywords: ["rename space", "rename folder"],
                                 action: .page(PalettePage(title: "Rename \(ws.name)", placeholder: "New name",
                                                           kind: .input(initial: ws.name) { new in
                                     // After the palette is gone; the window switches to the renamed folder.
                                     DispatchQueue.main.async { Opener.shared.rename(space: ws.root, to: new) }
                                 }))))
        items.append(PaletteItem(id: "space.finder", title: "Reveal \(ws.name) in Finder", icon: "folder", section: "Space",
                                 action: .run { NSWorkspace.shared.activateFileViewerSelecting([ws.root]) }))
        if SpaceList.isInRepository(ws.root) {
            // The save panel waits until the palette is gone.
            items.append(PaletteItem(id: "space.link", title: "Link \(ws.name) to…", icon: "link", section: "Space",
                                     keywords: ["symlink", "alias", "shortcut"],
                                     action: .run { DispatchQueue.main.async { Opener.shared.link(ws.root) } }))
        }
        if SyncService.shared.isSynced(ws.root) {
            // The confirmation alert waits until the palette is gone.
            items.append(PaletteItem(id: "space.invite", title: "Copy Invite Link to \(ws.name)…", icon: "person.badge.plus", section: "Space",
                                     keywords: ["share", "collaborate", "invite", "link"],
                                     action: .run { DispatchQueue.main.async { Invites.copyLink(for: ws.root) } }))
        }
        items.append(PaletteItem(id: "space.sidebar", title: state.sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                                 icon: "sidebar.left", shortcut: keys.sidebar.display, section: "Space",
                                 action: .run { withAnimation(.smooth(duration: 0.3)) { state.sidebarVisible.toggle() } }))
        items.append(PaletteItem(id: "space.spaces", title: "Show Spaces", icon: "square.stack", shortcut: keys.showSpaces.display, section: "Space",
                                 action: .run { state.setSpacesOpen(true) }))
        items.append(PaletteItem(id: "space.close", title: "Close \(ws.name)", icon: "xmark", shortcut: keys.closeSpace.display, section: "Space",
                                 action: .run { state.space = nil }))
        // Typing searches every file name in the space.
        items += Workspace.flatten(ws.tree).filter { $0.children == nil }.map { node in
            let dir = (ws.relativePath(of: node.url) as NSString).deletingLastPathComponent
            return PaletteItem(id: "file:\(node.url.path)", title: node.name, subtitle: dir.isEmpty ? nil : dir,
                               icon: node.isTypst ? "t.square" : MarkdownRenderer.isMarkdown(node.url) ? "m.square"
                                   : node.kind == .font ? "textformat" : node.kind == .image ? "photo" : "doc", section: "Files",
                               searchOnly: true, action: .run { withAnimation(.smooth(duration: 0.3)) { ws.select(node.url) } })
        }
        return items
    }

    /// Refactorings at the caret; they run in the editor once the palette is gone.
    private func refactorItems(_ tv: TypstTextView) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let keys = KeyLayout.current.shortcuts
        if let docs = tv.onShowDocs, let word = Self.identifier(in: tv.string, at: tv.selectedRange().location) {
            items.append(PaletteItem(id: "code.docs", title: "Show Documentation for \(word)", icon: "book", shortcut: keys.documentation.display,
                                     section: "Code", keywords: ["quick documentation", "help", "hover", "docs"],
                                     action: .run(docs)))
        }
        let symbol = Refactor.symbol(in: tv.string, at: tv.selectedRange().location)
        if let symbol, let rename = tv.onRename {
            let what = symbol.kind == "function" ? "Function" : "Variable"
            items.append(PaletteItem(id: "refactor.rename", title: "Rename \(what) \(symbol.name)…", icon: "pencil.line",
                                     shortcut: keys.rename.display, section: "Refactor", keywords: ["rename symbol", "refactor"],
                                     action: .run(rename)))
        }
        if let extract = tv.onExtractVariable {
            items.append(PaletteItem(id: "refactor.variable", title: "Extract Variable…", icon: "arrow.up.right.square",
                                     shortcut: keys.extractVariable.display, section: "Refactor", keywords: ["introduce variable", "refactor"],
                                     action: .run(extract)))
        }
        if let function = tv.onExtractFunction {
            items.append(PaletteItem(id: "refactor.function", title: "Extract Function…", icon: "function",
                                     shortcut: keys.extractFunction.display, section: "Refactor", keywords: ["extract method", "refactor"],
                                     action: .run { function(false) }))
            items.append(PaletteItem(id: "refactor.function.scope", title: "Extract Function to Scope…", icon: "function",
                                     shortcut: keys.extractFunctionToScope.display, section: "Refactor", keywords: ["extract method", "refactor"],
                                     action: .run { function(true) }))
        }
        let caret = tv.selectedRange().location
        if tv.hasQuickFixes?(caret) == true, let fixes = tv.onQuickFix {
            items.append(PaletteItem(id: "code.actions", title: "Show Context Actions…", icon: "lightbulb", shortcut: keys.contextActions.display,
                                     section: "Code", keywords: ["quick fix", "convert", "solveng", "def", "solve", "math"],
                                     action: .run { fixes(caret) }))
        }
        if symbol?.kind == "variable", let symbol, let inline = tv.onInlineVariable {
            items.append(PaletteItem(id: "refactor.inline", title: "Inline Variable \(symbol.name)", icon: "arrow.down.left.square",
                                     shortcut: keys.inlineVariable.display, section: "Refactor", keywords: ["refactor"], action: .run(inline)))
        }
        if tv.comments != nil {
            items.append(PaletteItem(id: "code.comment", title: "Comment Line", icon: "text.bubble", shortcut: keys.commentLine.display,
                                     section: "Code", keywords: ["uncomment", "toggle comment", "line comment"],
                                     action: .run { tv.toggleLineComment() }))
            items.append(PaletteItem(id: "code.comment.block", title: "Comment Block", icon: "text.bubble.fill",
                                     shortcut: keys.commentBlock.display, section: "Code",
                                     keywords: ["uncomment", "toggle comment", "block comment"],
                                     action: .run { tv.toggleBlockComment() }))
        }
        return items
    }

    /// The Typst name (with field access, like `calc.pow`) the caret touches.
    static func identifier(in text: String, at offset: Int) -> String? {
        let s = text as NSString
        func part(_ c: unichar) -> Bool {
            guard let scalar = UnicodeScalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || c == 95 || c == 45 || c == 46
        }
        var start = min(offset, s.length), end = start
        while start > 0, part(s.character(at: start - 1)) { start -= 1 }
        while end < s.length, part(s.character(at: end)) { end += 1 }
        let word = s.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return word.first.map { $0.isLetter || $0 == "_" } == true ? word : nil
    }

    /// Places that import, include or load the file.
    private func usageItems(of file: URL, _ ws: Workspace) -> [PaletteItem] {
        let usages = ws.fileUsages(of: file)
        guard !usages.isEmpty else {
            return [PaletteItem(id: "usages.none", title: "No usages in \(ws.name)", icon: "questionmark.circle",
                                section: "Usages", action: .stay { NSSound.beep() })]
        }
        return usages.map { usage in
            let l = usage.location
            return PaletteItem(id: "usage:\(l.url.path):\(l.line):\(l.character)", title: "\(usage.file):\(l.line + 1)",
                               subtitle: usage.preview, icon: "t.square", section: "Usages",
                               action: .run { withAnimation(.smooth(duration: 0.3)) { ws.reveal(usage) } })
        }
    }

    /// Folders the file can move into; its own folder is left out.
    private func moveTargets(_ file: URL, _ ws: Workspace) -> [PaletteItem] {
        let folders = [ws.root] + Workspace.flatten(ws.tree).filter { $0.children != nil }.map(\.url)
        return folders.filter { ws.canMove(file, into: $0) }.map { dir in
            PaletteItem(id: "move:\(dir.path)", title: ws.displayName(of: dir),
                        subtitle: dir == ws.root ? nil : ws.relativePath(of: dir), icon: "folder", section: "Folders",
                        action: .run { withAnimation(.smooth(duration: 0.25)) { ws.move(file, into: dir) } })
        }
    }

    // MARK: Settings

    /// Settings that make sense as one command; the rest open their tab.
    private var settingsItems: [PaletteItem] {
        let defaults = UserDefaults.standard
        func toggle(_ id: String, _ name: String, key: String, default value: Bool, icon: String,
                    keywords: [String] = []) -> PaletteItem {
            let on = defaults.object(forKey: key) as? Bool ?? value
            return PaletteItem(id: "settings.\(id)", title: "\(on ? "Turn Off" : "Turn On") \(name)", icon: icon,
                               section: "Settings", keywords: keywords + ["setting", "toggle", "enable", "disable"],
                               action: .run { defaults.set(!on, forKey: key) })
        }
        var items = [
            toggle("vim", "Vim Mode", key: "vimMode", default: false, icon: "keyboard", keywords: ["vim key bindings", "modal"]),
            toggle("glide", "Gliding Cursor", key: "glidingCursor", default: true, icon: "character.cursor.ibeam",
                   keywords: ["caret", "animation"]),
            toggle("autoClose", "Closing Brackets and Quotes", key: "autoClose", default: true, icon: "parentheses",
                   keywords: ["auto close", "auto pair", "brackets", "quotes"]),
            toggle("conceal", "Math and Escapes as Rendered", key: "concealMath", default: true, icon: "function",
                   keywords: ["hidden syntax", "conceal", "symbols", "escapes", "backslash", "live preview"]),
            toggle("wrap", "Wrap Guide", key: "wrapGuide", default: false, icon: "text.word.spacing",
                   keywords: ["wrap lines at a column", "ruler", "line length"]),
            toggle("libraryWarnings", "Ignoring Library Warnings", key: "ignoreLibraryWarnings", default: true,
                   icon: "exclamationmark.triangle", keywords: ["packages", "diagnostics"]),
        ]
        let server = LanguageServerManager.shared
        items.append(PaletteItem(id: "settings.lsp", title: "\(server.isEnabled ? "Turn Off" : "Turn On") Completions and Go to Definition",
                                 icon: "text.badge.plus", section: "Settings",
                                 keywords: ["tinymist", "language server", "lsp", "autocomplete", "setting"],
                                 action: .run { server.isEnabled.toggle() }))
        let size = defaults.object(forKey: "editorFontSize") as? Double ?? 14
        items += [
            PaletteItem(id: "settings.bigger", title: "Increase Editor Font Size", subtitle: "\(Int(size)) pt", icon: "textformat.size.larger",
                        section: "Settings", keywords: ["zoom in", "text size", "setting"],
                        action: .stay { defaults.set(min(size + 1, 32), forKey: "editorFontSize") }),
            PaletteItem(id: "settings.smaller", title: "Decrease Editor Font Size", subtitle: "\(Int(size)) pt", icon: "textformat.size.smaller",
                        section: "Settings", keywords: ["zoom out", "text size", "setting"],
                        action: .stay { defaults.set(max(size - 1, 9), forKey: "editorFontSize") }),
        ]
        let position = defaults.string(forKey: PreviewPosition.defaultsKey) ?? PreviewPosition.trailing.rawValue
        for other in PreviewPosition.allCases where other.rawValue != position {
            items.append(PaletteItem(id: "settings.previewPosition.\(other.rawValue)", title: "Show Preview \(other.place)",
                                     icon: other.icon, section: "Settings",
                                     keywords: ["split", "horizontal", "vertical", "layout", "above", "below", "side by side", "setting"],
                                     action: .run { defaults.set(other.rawValue, forKey: PreviewPosition.defaultsKey) }))
        }
        let appearance = defaults.string(forKey: "appearance") ?? Appearance.system.rawValue
        for mode in Appearance.allCases where mode.rawValue != appearance {
            items.append(PaletteItem(id: "settings.appearance.\(mode.rawValue)", title: "Use \(mode.title) Appearance",
                                     icon: mode == .dark ? "moon" : mode == .light ? "sun.max" : "circle.lefthalf.filled",
                                     section: "Settings", keywords: ["theme", "dark mode", "light mode", "setting"],
                                     action: .run {
                                         defaults.set(mode.rawValue, forKey: "appearance")
                                         Appearance.apply(mode.rawValue)
                                     }))
        }
        if let ws = workspace {
            let html = ws.htmlPreview
            items.append(PaletteItem(id: "settings.htmlDark", title: "\(html.darkMode ? "Turn Off" : "Turn On") Dark HTML Preview",
                                     icon: "doc.richtext", section: "Settings", keywords: ["preview", "invert", "setting"],
                                     action: .run { html.darkMode.toggle() }))
            items.append(PaletteItem(id: "settings.htmlPages", title: "\(html.pages ? "Turn Off" : "Turn On") A4 Pages in HTML Preview",
                                     icon: "doc.plaintext", section: "Settings", keywords: ["preview", "paginate", "setting"],
                                     action: .run { html.pages.toggle() }))
        }
        let layout = KeyLayout.current
        for other in KeyLayout.all where other.id != layout.id {
            items.append(PaletteItem(id: "settings.layout.\(other.id)", title: "Use \(other.name) Keyboard Layout",
                                     icon: "keyboard", section: "Settings",
                                     keywords: ["keyboard shortcuts", "key bindings", "keymap", "intellij", "setting"],
                                     action: .run { defaults.set(other.id, forKey: KeyLayout.defaultsKey) }))
        }
        let tabs = [("General", "gearshape", 0, ["compiler", "typst version", "theme"]),
                    ("Editor", "textformat", 1, ["font size", "cursor", "wrapping", "vim", "tinymist",
                                                "keyboard shortcuts", "key bindings", "intellij"]),
                    ("Package", "shippingbox", 3, ["packages", "preview packages", "cache"]),
                    ("Device", "arrow.triangle.2.circlepath", 4, ["sync", "devices", "passkey", "account"])]
        items += tabs.map { name, icon, tab, keywords in
            PaletteItem(id: "settings.tab.\(tab)", title: "\(name) Settings…", icon: icon, section: "Settings",
                        keywords: keywords + ["preferences"], action: .run { SettingsWindowController.shared.show(tab: tab) })
        }
        return items
    }

    // MARK: Fonts

    private var fontItems: [PaletteItem] {
        let fonts = FontLibrary.shared
        var items = [
            PaletteItem(id: "fonts.install", title: "Install Google Font…", icon: "arrow.down.circle", section: "Fonts",
                        keywords: ["download", "google fonts", "typeface", "add font"],
                        action: .page(PalettePage(title: "Install Google Font", placeholder: "Search Google Fonts…",
                                                  kind: .list { googleFontItems }))),
            PaletteItem(id: "fonts.folder", title: "Add Font Folder…", icon: "folder.badge.plus", section: "Fonts",
                        keywords: ["fonts", "typeface"], action: .run { Self.addFontFolder() }),
            PaletteItem(id: "fonts.settings", title: "Font Settings…", icon: "character.textbox", section: "Fonts",
                        keywords: ["fonts", "manage fonts"], action: .run { SettingsWindowController.shared.show(tab: 2) }),
        ]
        if !fonts.installed.isEmpty {
            items.insert(PaletteItem(id: "fonts.remove", title: "Remove Google Font…", icon: "trash", section: "Fonts",
                                     keywords: ["delete", "uninstall", "fonts"],
                                     action: .page(PalettePage(title: "Remove Google Font", placeholder: "Choose a font…",
                                                               kind: .list { installedFontItems }))), at: 1)
        }
        return items
    }

    /// Google Fonts' catalog; it loads on first use, and the list fills in when it arrives.
    private var googleFontItems: [PaletteItem] {
        let fonts = FontLibrary.shared
        if fonts.catalog.isEmpty {
            Task { await fonts.loadCatalog() }
            return [PaletteItem(id: "fonts.loading", title: fonts.lastError ?? "Loading Google Fonts…", icon: "hourglass",
                                section: "Google Fonts", action: .run {})]
        }
        return fonts.catalog.map { font in
            let installed = fonts.installed.contains(font.family)
            let downloading = fonts.downloads[font.family] != nil
            return PaletteItem(id: "google:\(font.family)", title: font.family,
                               subtitle: downloading ? "Downloading…" : installed ? "Installed" : font.category?.capitalized,
                               icon: installed ? "checkmark.circle.fill" : "textformat", section: "Google Fonts",
                               action: .stay {
                                   guard !installed, !downloading else { return NSSound.beep() }
                                   Task { await fonts.download(font.family) }
                               })
        }
    }

    private var installedFontItems: [PaletteItem] {
        FontLibrary.shared.installed.map { family in
            PaletteItem(id: "installed:\(family)", title: family, icon: "textformat", section: "Installed",
                        action: .stay { FontLibrary.shared.remove(family) })
        }
    }

    private static func addFontFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders with fonts every space can use"
        guard panel.runModal() == .OK else { return }
        let fonts = FontLibrary.shared
        fonts.machinePaths += panel.urls.map(\.path).filter { !fonts.machinePaths.contains($0) }
    }

    private func folderItems(_ kind: String, _ ws: Workspace) -> [PaletteItem] {
        let folders = [ws.root] + Workspace.flatten(ws.tree).filter { $0.children != nil }.map(\.url)
        return folders.map { dir in
            PaletteItem(id: "dir:\(dir.path)", title: ws.displayName(of: dir),
                        subtitle: dir == ws.root ? nil : ws.relativePath(of: dir), icon: "folder", section: "Folders",
                        action: .page(namePage(kind, in: dir, ws)))
        }
    }

    private func namePage(_ kind: String, in dir: URL, _ ws: Workspace) -> PalettePage {
        let placeholder = kind == "File" ? "Name, e.g. chapter.typ" : "Folder name"
        return PalettePage(title: "New \(kind) in \(ws.displayName(of: dir))", placeholder: placeholder, kind: .input(initial: "") { name in
            withAnimation(.smooth(duration: 0.25)) {
                if dir != ws.root { ws.expanded.insert(dir) }
                if kind == "File" { ws.createFile(in: dir, named: name) } else { ws.createFolder(in: dir, named: name) }
            }
        })
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    private var title: AttributedString {
        guard let range = item.emphasis else { return AttributedString(item.title) }
        var result = AttributedString(String(item.title[..<range.lowerBound]))
        var name = AttributedString(String(item.title[range]))
        name.inlinePresentationIntent = .stronglyEmphasized
        result += name
        result += AttributedString(String(item.title[range.upperBound...]))
        return result
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut).font(.caption).foregroundStyle(.secondary)
            }
            if case .page = item.action {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isSelected ? 0.1 : 0)))
    }
}
