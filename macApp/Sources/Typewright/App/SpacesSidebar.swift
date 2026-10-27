import AppKit
import SwiftUI
import TypewrightCore

/// The window's sidebar: the space's file tree, which shrinks away while the selector covers it.
struct SpacesSidebar: View {
    let state: WindowState
    let workspace: Workspace?

    var body: some View {
        GeometryReader { geo in
            let progress = workspace == nil ? 1 : state.spacesProgress
            ZStack {
                if let workspace {
                    SidebarView(workspace: workspace, onShowSpaces: { state.setSpacesOpen(true) },
                                onCreateFile: { Opener.shared.newFile(in: state, folder: $0) }) { name in
                        Opener.shared.rename(space: workspace.root, to: name)
                    }
                    .id(ObjectIdentifier(workspace))
                    .transition(state.switchForward == nil ? .opacity.combined(with: .scale(scale: 0.92)) : state.spaceTransition)
                    .scaleEffect(1 - 0.08 * progress)
                    .opacity(1 - progress)
                    .allowsHitTesting(progress == 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SpaceSwipe(state: state, width: geo.size.width + WindowState.spacesExtra))
            // The selector lives above the split view so it can grow past the sidebar.
            // In the coordinates of the overlays, which move down with the window below a menu bar.
            .onChange(of: geo.frame(in: .global), initial: true) { _, frame in
                state.sidebarFrame = frame.offsetBy(dx: 0, dy: -state.menuBarInset)
            }
        }
        .padding(.top, state.fullScreenTop)
        // Same behind-window blur as the preview instead of the wallpaper-tinted default.
        .background(SidebarMaterial().ignoresSafeArea())
    }
}

/// The space selector, sliding in from the left over the sidebar and `spacesExtra` points beyond it.
struct SpacesOverlay: View {
    let state: WindowState
    let workspace: Workspace?
    @State private var spaces: [URL] = []

    var body: some View {
        // Without a space the selector always shows.
        let progress = workspace == nil ? 1 : state.spacesProgress
        let frame = state.panelFrame
        let extra = WindowState.spacesExtra * progress
        // Always the open width, so labels never rewrap while it slides.
        let width = frame.width + WindowState.spacesExtra
        let offset = frame.minX - width * (1 - progress)
        ZStack(alignment: .topLeading) {
            // Unmounted while closed: over the split view it would swallow the divider's hover, cursor and drags.
            if state.selectorMounted {
                if state.sidebarVisible {
                    // Widens the sidebar's material into the detail column, which moves aside by as much.
                    SidebarMaterial()
                        .frame(width: extra)
                        .frame(maxHeight: .infinity)
                        .offset(x: frame.maxX)
                } else {
                    // Without a sidebar underneath, the selector brings all of its material along.
                    SidebarMaterial()
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
                        .offset(x: offset)
                }
                SpacesPane(state: state, workspace: workspace, current: workspace?.root.path, canClose: workspace != nil,
                           active: progress == 1, spaces: spaces) {
                    spaces = SpaceList.all
                }
                    .frame(width: width, height: frame.height)
                    .offset(x: offset, y: frame.minY)
                    .allowsHitTesting(progress == 1)
            }
            // Follows the selector's edge while that slides; a hidden sidebar has no divider to drag.
            if state.sidebarVisible {
                SidebarResizeHandle(state: state)
                    .frame(width: 9)
                    .frame(maxHeight: .infinity)
                    .offset(x: frame.maxX + extra - 4.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear { spaces = SpaceList.all }
        .onChange(of: state.spacesProgress > 0) { spaces = SpaceList.all }
        .onChange(of: workspace?.root) { spaces = SpaceList.all }
        .onReceive(NotificationCenter.default.publisher(for: SpaceList.didChange).receive(on: RunLoop.main)) { _ in
            spaces = SpaceList.all
        }
        .onChange(of: wanted, initial: true) { _, now in
            guard !now else {
                state.selectorMounted = true
                return
            }
            // Stay until the closing slide has played out.
            Task {
                try? await Task.sleep(for: .seconds(0.45))
                if !wanted { state.selectorMounted = false }
            }
        }
    }

    private var wanted: Bool {
        workspace == nil || state.spacesOpen || state.swipe != nil
    }
}

/// The spaces toggle; the file tree and the selector each carry their own copy, so it moves with both.
struct SpacesButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZenIcon(systemName: "square.stack", size: 28, active: active, idleFill: false)
        }
        .buttonStyle(ZenPressStyle())
        .help(active ? "Back to the space" : "Spaces")
    }
}

/// The sidebar's divider: a faint line that brightens while hovered or dragged, and resizes the sidebar.
private struct SidebarResizeHandle: View {
    let state: WindowState
    @State private var start: CGFloat?
    @State private var splitView: NSSplitView?

    @State private var hovered = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(hovered || start != nil ? 0.45 : 0.12))
                    .frame(width: 1)
                    .animation(.easeOut(duration: 0.15), value: hovered || start != nil)
            }
            .pointerStyle(.columnResize)
            // The text view sets its own cursor on every move.
            .background(CursorArea(cursor: .resizeLeftRight))
            .onHover { hovered = $0 }
            .background(SplitViewFinder { splitView = $0 })
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = start ?? state.sidebarFrame.maxX
                        self.start = start
                        splitView?.setPosition(start + value.translation.width, ofDividerAt: 0)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

/// Finds the window's split view, which SwiftUI doesn't expose.
private struct SplitViewFinder: NSViewRepresentable {
    let onFind: (NSSplitView?) -> Void

    func makeNSView(context: Context) -> FinderView { FinderView() }
    func updateNSView(_ view: FinderView, context: Context) { view.onFind = onFind }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FinderView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class FinderView: NSView {
        var onFind: (NSSplitView?) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let root = window?.contentView else { return }
            let found = Self.find(in: root)
            DispatchQueue.main.async { [onFind] in onFind(found) }
        }

        private static func find(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for sub in view.subviews { if let split = find(in: sub) { return split } }
            return nil
        }
    }
}

/// The spaces as Zen-style rows in the user's order, and the way to open another folder as a space.
struct SpacesPane: View {
    let state: WindowState
    let workspace: Workspace?
    let current: String?
    let canClose: Bool
    /// Fully open, so the arrow keys move through the list.
    let active: Bool
    let spaces: [URL]
    let onChange: () -> Void
    @State private var drag: (url: URL, offset: CGFloat)?
    /// The row the arrow keys are on; Return opens it.
    @State private var highlighted: URL?
    /// Who had focus before the selector took it, to hand it back on close.
    @State private var previousResponder: NSResponder?
    @FocusState private var focused: Bool
    /// The pointer while folders from Finder hover the list.
    @State private var externalDrop: CGPoint?
    /// The space whose name is being edited in place.
    @State private var renaming: URL?
    /// Shows each row's ⌘ number while ⌘ is held.
    @State private var shortcutHints = SpaceShortcutHints()
    @State private var scrolled = false
    private let sync = SyncService.shared

    private static let rowHeight: CGFloat = 42
    private static let pitch = rowHeight + 2

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: highlighted) { _, url in
                    guard let url else { return }
                    withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(url) }
                }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            guard let highlighted else { return .ignored }
            open(highlighted)
            return .handled
        }
        .onKeyPress(.escape) {
            guard canClose else { return .ignored }
            state.setSpacesOpen(false)
            return .handled
        }
        .onChange(of: active, initial: true) { _, active in
            active ? takeFocus() : giveBackFocus()
            updateShortcutHints()
        }
        // The palette and search take focus while they're over the selector.
        .onChange(of: state.overlay == nil) { _, closed in
            if closed && active { takeFocus() }
            updateShortcutHints()
        }
        .onChange(of: renaming) { updateShortcutHints() }
        .onChange(of: spaces) {
            if let highlighted, !spaces.contains(highlighted) { self.highlighted = nil }
        }
        .onAppear {
            shortcutHints.start(in: state.window)
            updateShortcutHints()
        }
        .onDisappear {
            shortcutHints.stop()
        }
        .animation(.easeOut(duration: 0.12), value: shortcutHints.visible)
    }

    private func updateShortcutHints() {
        shortcutHints.enabled = active && state.overlay == nil && renaming == nil
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Spaces")
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .frame(height: 34)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) { Divider().opacity(scrolled ? 1 : 0) }
            scrollList
            HStack {
                if canClose { SpacesButton(active: true) { state.setSpacesOpen(false) } }
                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .padding(10)
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var scrollList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(spaces.enumerated()), id: \.element) { index, url in
                    SpaceRow(url: url, isCurrent: url.path == current, isHighlighted: focused && highlighted == url,
                             isDragged: drag?.url == url, isSynced: sync.isSynced(url), isShared: sync.isShared(url), status: sync.status(for: url),
                             isRenaming: renaming == url, shortcut: shortcutHints.visible && index < 9 ? index + 1 : nil) {
                        open(url)
                    } onStartRename: {
                        renaming = url
                    } onRename: { name in
                        guard renaming == url else { return }
                        renaming = nil
                        if let name, Opener.shared.rename(space: url, to: name) != nil {
                            withAnimation(.smooth(duration: 0.2)) { onChange() }
                        }
                    } onForget: {
                        if SpaceList.isInRepository(url) {
                            Opener.shared.deleteSpace(url, in: state)
                            withAnimation(.smooth(duration: 0.3)) { onChange() }
                        } else {
                            Opener.shared.forgetSpace(url, in: state)
                        }
                    } onToggleSync: {
                        toggleSync(url)
                    } onRemoveEverywhere: {
                        if let id = sync.shareID(for: url) { removeEverywhere(id, name: url.lastPathComponent) }
                    } onInvite: {
                        Invites.share(url)
                    } onDrag: { offset in
                        drag = (url, offset)
                    } onDrop: {
                        drop()
                    }
                    .offset(y: offset(of: index))
                    .zIndex(drag?.url == url ? 1 : 0)
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .opacity.combined(with: .scale(scale: 0.9)).combined(with: .move(edge: .leading))))
                    .animation(drag?.url == url ? nil : .smooth(duration: 0.2), value: target)
                }
                if spaces.isEmpty {
                    Text("No spaces yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                }
                NewSpaceRow { Opener.shared.newSpace(in: state) } onImport: { Opener.shared.openPanel(in: state) }
                    .offset(y: externalDrop == nil ? 0 : Self.pitch)
                if !sync.elsewhere.isEmpty {
                    Text("On Other Devices")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    ForEach(sync.elsewhere) { share in
                        ElsewhereSpaceRow(name: share.name) {
                            download(share)
                        } onRemove: {
                            removeEverywhere(share.id, name: share.name)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .animation(.smooth(duration: 0.2), value: insertionIndex)
            .onDrop(of: [.fileURL], delegate: ExternalDrop(
                onMove: { externalDrop = $0 },
                onExit: { externalDrop = nil },
                onDrop: addDropped))
        }
        .clipped()
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 0.5 } action: { _, scrolled in
            self.scrolled = scrolled
        }
    }

    /// Starts on the open space, or the first one without.
    private func move(_ delta: Int) {
        guard !spaces.isEmpty else { return }
        guard let index = highlighted.flatMap(spaces.firstIndex(of:)) else {
            highlighted = spaces.first { $0.path == current } ?? spaces.first
            return
        }
        highlighted = spaces[min(max(index + delta, 0), spaces.count - 1)]
    }

    private func takeFocus() {
        highlighted = spaces.first { $0.path == current } ?? spaces.first
        guard let window = NSApp.keyWindow else { return }
        // The editor holds on to first responder until it's released; then the list can take focus.
        if !focused { previousResponder = window.firstResponder }
        window.makeFirstResponder(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            if active { focused = true }
        }
    }

    private func giveBackFocus() {
        guard focused else { return }
        focused = false
        // Only if it's still around; switching spaces replaces the editor.
        if let view = previousResponder as? NSView, let window = view.window {
            window.makeFirstResponder(view)
        }
        previousResponder = nil
    }

    private var source: Int? {
        drag.flatMap { d in spaces.firstIndex(of: d.url) }
    }

    /// Where the dragged row would land if dropped now.
    private var target: Int? {
        guard let drag, let source else { return nil }
        return min(max(source + Int((drag.offset / Self.pitch).rounded()), 0), spaces.count - 1)
    }

    /// Where folders dropped from Finder would be inserted.
    private var insertionIndex: Int? {
        externalDrop.map(index(at:))
    }

    private func index(at location: CGPoint) -> Int {
        min(max(Int(((location.y - 4) / Self.pitch).rounded()), 0), spaces.count)
    }

    /// Dropped folders become spaces at the drop position; dropped files add their folder.
    private func addDropped(_ urls: [URL], at location: CGPoint) {
        externalDrop = nil
        var index = index(at: location)
        var outside: [(url: URL, at: Int)] = []
        for url in urls {
            var isDir: ObjCBool = false
            let known = SpaceList.all.contains { $0.path == url.resolvingSymlinksInPath().path }
            if !known, !SpaceList.isInRepository(url), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                // Outside folders become spaces as the palette asks, at the drop position.
                outside.append((url, index))
                index += 1
                continue
            }
            let root = Workspace.root(of: url).resolvingSymlinksInPath()
            // Known spaces before the drop point shift the position by one when they move.
            if let from = SpaceList.all.firstIndex(where: { $0.path == root.path }), from < index { index -= 1 }
            SpaceList.add(root)
            SpaceList.move(root, to: index)
            index += 1
        }
        withAnimation(.smooth(duration: 0.25)) { onChange() }
        askToImport(outside[...])
    }

    /// One question at a time; cancelling one skips the rest.
    private func askToImport(_ folders: ArraySlice<(url: URL, at: Int)>) {
        guard let (url, at) = folders.first else { return }
        Opener.shared.askToImport(url, in: state) { space in
            SpaceList.move(space, to: at)
            withAnimation(.smooth(duration: 0.25)) { onChange() }
            askToImport(folders.dropFirst())
        }
    }

    /// The dragged row follows the pointer; the rows it passes make room for it.
    private func offset(of index: Int) -> CGFloat {
        if let insertionIndex { return index >= insertionIndex ? Self.pitch : 0 }
        guard let drag, let source, let target else { return 0 }
        if index == source { return drag.offset }
        if source < target, index > source, index <= target { return -Self.pitch }
        if target < source, index >= target, index < source { return Self.pitch }
        return 0
    }

    private func drop() {
        guard let drag, let target else { return }
        SpaceList.move(drag.url, to: target)
        withAnimation(.smooth(duration: 0.25)) {
            onChange()
            self.drag = nil
        }
    }

    /// Without an account, syncing starts in the Devices settings. Only spaces in the library sync.
    private func toggleSync(_ url: URL) {
        guard SpaceList.isInRepository(url) else { return }
        if sync.isSynced(url) {
            sync.stopSyncing(url)
        } else if !sync.isRunning {
            SettingsWindowController.shared.show(tab: 4)
        } else {
            sync.share(url)
        }
    }

    /// Every device stops syncing the space; their files stay where they are.
    private func removeEverywhere(_ id: String, name: String) {
        var detail = "Your devices stop syncing this space. Their copies of the files stay where they are."
        if sync.accountShares.contains(where: { $0.id == id && $0.shared }) {
            detail += " Others it's shared with keep syncing it among themselves."
        }
        let choice = PaletteDialog.choose("Remove “\(name)” from all devices?", detail: detail, choices: [
            PaletteDialog.Choice(id: "remove", title: "Remove", icon: "trash", destructive: true),
            PaletteDialog.Choice(id: "cancel", title: "Cancel", icon: "xmark"),
        ], over: state.window)
        guard choice == "remove" else { return }
        withAnimation(.smooth(duration: 0.2)) { sync.removeEverywhere(id) }
    }

    /// Spaces come back as spaces; a folder or file shared on another device asks where it goes. Opens it while its
    /// files arrive.
    private func download(_ share: AccountShare) {
        if share.kind == .space {
            join(share, at: sync.suggestedDestination(for: share))
        } else {
            LibraryDestination.choose(name: share.name, file: share.kind == .file, in: sync.repository, state: state) { destination in
                join(share, at: destination)
            }
        }
    }

    private func join(_ share: AccountShare, at destination: URL) {
        guard let joined = sync.join(share, at: destination) else {
            PaletteDialog.message("Couldn't download “\(share.name)”.", detail: sync.lastError, over: state.window)
            return
        }
        onChange()
        if share.kind == .space { Opener.shared.open(joined, in: state) } else { Invites.reveal(joined) }
    }

    private func open(_ url: URL) {
        if url.path == current {
            state.setSpacesOpen(false)
        } else {
            Opener.shared.open(url, in: state)
        }
    }
}

/// Zen-style tile with the space's name and location; click to open, drag to reorder.
private struct SpaceRow: View {
    let url: URL
    let isCurrent: Bool
    let isHighlighted: Bool
    let isDragged: Bool
    let isSynced: Bool
    let isShared: Bool
    let status: ShareStatus?
    let isRenaming: Bool
    /// The ⌘ number shown while ⌘ is held.
    let shortcut: Int?
    let onOpen: () -> Void
    let onStartRename: () -> Void
    let onRename: (String?) -> Void
    let onForget: () -> Void
    let onToggleSync: () -> Void
    let onRemoveEverywhere: () -> Void
    let onInvite: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDrop: () -> Void
    @State private var hovered = false
    @State private var pressed = false
    @State private var dragging = false

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "folder.fill" : "folder")
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    RenameField(name: url.lastPathComponent, base: url.lastPathComponent, onRename: onRename)
                } else {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if !inRepository { ExternalSpaceBadge() }
            if let shortcut {
                Text("⌘\(shortcut)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if isSynced {
                SyncStatusLabel(status: status, shared: isShared)
            }
            if shortcut == nil, SpaceFolders.isGitRepository(url) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help(SpaceFolders.gitRepositoryNote)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isCurrent ? .primary : .secondary)
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Self.shape.fill(isDragged ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.primary.opacity(fill))))
        .background(Self.shape.fill(Color.primary.opacity(isDragged ? fill : 0)))
        .shadow(color: .black.opacity(isDragged ? 0.2 : 0), radius: 8, y: 3)
        .contentShape(Self.shape)
        .scaleEffect(isDragged ? 1.03 : pressed ? 0.95 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: pressed)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragged)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
        .onHover { hovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    // A few points of vertical travel turn the press into a reorder.
                    if !dragging && abs(value.translation.height) > 4 { dragging = true }
                    pressed = !dragging
                    if dragging { onDrag(value.translation.height) }
                }
                .onEnded { value in
                    pressed = false
                    if dragging {
                        dragging = false
                        onDrop()
                    } else if abs(value.translation.width) < 40 {
                        onOpen()
                    }
                },
            // The name field gets its clicks while renaming.
            including: isRenaming ? .subviews : .all
        )
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Open in New Window") { Opener.shared.openInNewWindow(url) }
            Button("Rename…", action: onStartRename)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy Path") { copyPath(url) }
            Divider()
            if inRepository {
                Button(isSynced ? "Stop Syncing on This Mac" : "Sync Across Devices", action: onToggleSync)
                if isSynced {
                    Button("Remove From All Devices…", action: onRemoveEverywhere)
                }
                Button("Share…", action: onInvite)
                Divider()
                Button("Link to…") { Opener.shared.link(url) }
                Button("Show Recently Deleted") { RecentlyDeleted.show(in: url) }
                Divider()
                Button("Delete Space", action: onForget)
            } else {
                Button("Import Into Typewright…") { Opener.shared.askToImport(url, external: false) }
                Divider()
                Button("Remove From Spaces…", action: onForget)
            }
        }
        .help("Drag to reorder")
    }

    private var fill: Double {
        if isCurrent { return isHighlighted ? 0.16 : 0.12 }
        if isHighlighted { return 0.09 }
        return hovered ? 0.06 : 0
    }

    private var inRepository: Bool { SpaceList.isInRepository(url) }

    private var subtitle: String { SpaceList.subtitle(of: url) }
}

/// Like Zen's "New Tab" row: a quiet plus at the end of the list.
private struct NewSpaceRow: View {
    let action: () -> Void
    let onImport: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus").frame(width: 16)
                Text("New Space")
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovered ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ZenRowPressStyle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .contextMenu { Button("Import Folder as Space…", action: onImport) }
        .help("Make a new space")
    }
}

/// A space from the user's other devices; clicking downloads it.
private struct ElsewhereSpaceRow: View {
    let name: String
    let action: () -> Void
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.down").frame(width: 16)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovered ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ZenRowPressStyle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("Download “\(name)” from your other devices")
        .contextMenu {
            Button("Download…", action: action)
            Divider()
            Button("Remove From All Devices…", action: onRemove)
        }
    }
}

/// Rows zoom out slightly while held, like the file rows.
private struct ZenRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// Drives the selector with horizontal two-finger swipes: right reveals it, left returns to the space.
struct SpaceSwipe: NSViewRepresentable {
    let state: WindowState
    let width: CGFloat
    var floating = false

    func makeNSView(context: Context) -> SwipeView { SwipeView() }

    func updateNSView(_ view: SwipeView, context: Context) {
        view.state = state
        view.width = width
        view.floating = floating
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SwipeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class SwipeView: NSView {
        var state: WindowState?
        var width: CGFloat = 1
        var floating = false
        private var monitor: Any?
        /// nil until the gesture's direction is known.
        private var tracking: Bool?
        private var start: CGFloat = 0
        private var distance = CGSize.zero
        private var lastDelta: CGFloat = 0
        private var swallowMomentum = false
        private var horizontal = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard let state, event.window === window, event.hasPreciseScrollingDeltas, state.space != nil,
                  state.overlay == nil || tracking == true else { return event }
            let visible = floating ? !state.sidebarVisible && state.floatingSidebar : state.sidebarVisible
            guard visible, !isHiddenOrHasHiddenAncestor else {
                if tracking == true { state.swipe = nil }
                tracking = nil
                horizontal = false
                swallowMomentum = false
                return event
            }
            // The flick's momentum would otherwise scroll whatever is under the pointer.
            if event.momentumPhase != [] {
                let swallow = swallowMomentum
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled { swallowMomentum = false }
                return swallow ? nil : event
            }
            // Follow the fingers regardless of the natural scrolling setting.
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            switch event.phase {
            case .began:
                // The floating selector leaves scrolling in the document alone.
                let inside = bounds.contains(convert(event.locationInWindow, from: nil))
                tracking = inside || (!floating && state.spacesOpen) ? nil : false
                start = state.spacesProgress
                distance = CGSize(width: dx, height: event.scrollingDeltaY)
                lastDelta = 0
                swallowMomentum = false
                horizontal = tracking == nil && abs(distance.width) > abs(distance.height) * 1.5
                return horizontal ? nil : event
            case .changed:
                guard tracking != false else { return horizontal ? nil : event }
                distance.width += dx
                distance.height += event.scrollingDeltaY
                if tracking == nil {
                    horizontal = abs(distance.width) > abs(distance.height) * 1.5
                    guard abs(distance.width) + abs(distance.height) > 6 else { return horizontal ? nil : event }
                    let opening = distance.width > 0
                    tracking = horizontal && opening != state.spacesOpen
                    guard tracking == true else { return horizontal ? nil : event }
                    state.selectorMounted = true
                }
                if dx != 0 { lastDelta = dx }
                state.swipe = min(max(start + distance.width / max(width, 1), 0), 1)
                return nil
            case .ended, .cancelled:
                guard tracking == true else {
                    tracking = nil
                    swallowMomentum = horizontal
                    horizontal = false
                    return swallowMomentum ? nil : event
                }
                tracking = nil
                horizontal = false
                swallowMomentum = true
                let progress = state.swipe ?? start
                // A flick decides on its own; otherwise the halfway point does.
                let open = abs(lastDelta) > 3 ? lastDelta > 0 : progress > 0.5
                withAnimation(WindowState.spacesAnimation) {
                    state.spacesOpen = open
                    state.swipe = nil
                }
                return nil
            default:
                return event
            }
        }
    }
}
