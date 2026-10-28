import AppKit
import SwiftUI

/// The space's file tree under its header.
struct SidebarView: View {
    let workspace: Workspace
    let onShowSpaces: () -> Void
    let onCreateFile: (URL) -> Void
    let onCreateFolder: (URL) -> Void
    var onExternalDrag: (Bool) -> Void = { _ in }
    var dropIDPrefix = "file"
    let onRenameSpace: (String) -> Void
    @State private var renaming: URL?
    @State private var scrolled = false
    @State private var scrollOffset: CGFloat = 0
    @State private var revealRequest = 0
    /// Hovering the header springs open the spaces list.
    @State private var upTask: Task<Void, Never>?
    @State private var expandTask: Task<Void, Never>?
    @State private var springOpened: Set<URL> = []
    /// The row briefly tinted after revealing the selected file.
    @State private var flashed: URL?
    /// The pointer while files from another app hover the tree.
    @State private var externalDrop: CGPoint?

    private static let rowPitch: CGFloat = 36

    private struct Row: Identifiable {
        let node: FileNode
        let depth: Int
        var id: URL { node.url }
    }

    private var rows: [Row] {
        func walk(_ nodes: [FileNode], _ depth: Int) -> [Row] {
            nodes.flatMap { node -> [Row] in
                let children = node.children.map { workspace.expanded.contains(node.url) ? walk($0, depth + 1) : [] } ?? []
                return [Row(node: node, depth: depth)] + children
            }
        }
        return walk(workspace.tree, 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            FileDropArea(id: "\(dropIDPrefix)HeaderDrop", onMove: { _ in hoverUp() }, onExit: {
                upTask?.cancel()
                upTask = nil
                onExternalDrag(false)
            }, onDrop: { urls, _, copy in
                workspace.importItems(urls, into: workspace.root, copy: copy)
            }) {
                if FileDragSession.shared.isDragging {
                    Label("Spaces", systemImage: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onShowSpaces)
                } else {
                    SpaceHeader(name: workspace.name,
                                url: workspace.root,
                                renaming: Binding(get: { workspace.renamingSpace }, set: { workspace.renamingSpace = $0 }),
                                isExternal: !SpaceList.isInRepository(workspace.root),
                                isDropTarget: dropTarget?.path == workspace.root.path,
                                canReveal: workspace.selectedFile.map(isInTree) ?? false,
                                onReveal: { revealRequest += 1 },
                                onRename: onRenameSpace, onShowSpaces: onShowSpaces, menuItems: spaceMenuItems)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                        .overlay(alignment: .bottom) { Divider().opacity(scrolled ? 1 : 0) }
                }
            }
            .frame(height: 36)
            GeometryReader { geo in
                FileDropArea(id: "\(dropIDPrefix)TreeDrop", onMove: { location in
                    onExternalDrag(true)
                    hoverMoved { externalDrop = CGPoint(x: location.x, y: location.y + scrollOffset) }
                }, onExit: {
                    expandTask?.cancel()
                    externalDrop = nil
                    closeSpringFolders()
                    onExternalDrag(false)
                }, onDrop: { urls, location, copy in
                    importDropped(urls, at: CGPoint(x: location.x, y: location.y + scrollOffset), copy: copy)
                }) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            fileList
                                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                                .contentShape(Rectangle())
                                .background(WindowMoveArea())
                        }
                        .clipped()
                        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                            scrolled = offset > 0.5
                            scrollOffset = offset
                        }
                        .onChange(of: revealRequest) { revealSelected(proxy) }
                        .scrollIndicators(CGFloat(rows.count) * Self.rowPitch + 8 > geo.size.height ? .automatic : .never)
                    }
                }
            }
            FileDropArea(id: "\(dropIDPrefix)FooterDrop", onMove: { _ in onExternalDrag(true) }, onExit: {
                onExternalDrag(false)
            }, onDrop: { urls, _, copy in
                workspace.importItems(urls, into: workspace.root, copy: copy)
            }) {
                HStack {
                    SpacesButton(active: false, action: onShowSpaces)
                    Spacer(minLength: 0)
                    ZenMenuButton(systemName: "plus", size: 28, rotatesWhenOpen: true, idleFill: false) {
                        createItems(in: nil)
                    }
                    .help("New file or folder")
                }
                .padding(10)
                .contentShape(Rectangle())
                .background(WindowMoveArea())
            }
            .frame(height: 48)
        }
        .onChange(of: FileDragSession.shared.isDragging) { _, active in
            if !active {
                upTask?.cancel()
                upTask = nil
                externalDrop = nil
                closeSpringFolders()
                onExternalDrag(false)
            }
        }
        .onDisappear { upTask?.cancel(); expandTask?.cancel(); closeSpringFolders() }
    }

    private var fileList: some View {
        LazyVStack(spacing: 2) {
            ForEach(rows) { row in
                FileRow(
                    node: row.node,
                    depth: row.depth,
                    isSelected: row.node.url == workspace.selectedFile,
                    isPreviewed: row.node.url == workspace.previewFile,
                    previewMode: workspace.previewMode,
                    isExpanded: workspace.expanded.contains(row.node.url),
                    isRenaming: renaming == row.node.url,
                    isDragged: FileDragSession.shared.urls.contains(row.node.url),
                    isDropTarget: dropTarget?.path == row.node.url.path || flashed == row.node.url,
                    onTap: { tap(row.node) },
                    onDrag: {
                        workspace.flushSaves()
                        onExternalDrag(true)
                        FileDragSession.shared.begin([row.node.url])
                    },
                    onTogglePreview: { workspace.togglePreview(row.node.url) },
                    onStartRename: { renaming = row.node.url },
                    onRename: { name in
                        // Submit, focus loss and outside clicks all report; only the first counts.
                        guard renaming == row.node.url else { return }
                        renaming = nil
                        if let name { workspace.rename(row.node.url, to: name) }
                    },
                    menuItems: { menuItems(for: row.node) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.12), value: dropTarget)
    }

    private var dropTarget: URL? { externalDrop.map(folder(at:)) }

    private func hoverUp() {
        onExternalDrag(true)
        guard upTask == nil else { return }
        upTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            onShowSpaces()
        }
    }

    private func folder(at location: CGPoint) -> URL {
        let index = Int(((location.y - 4) / Self.rowPitch).rounded(.down))
        guard rows.indices.contains(index) else { return workspace.root }
        let node = rows[index].node
        return node.children != nil ? node.url : node.url.deletingLastPathComponent()
    }

    /// Applies a pointer move; hovering a closed folder for a moment opens it, so deeper folders can be reached.
    private func hoverMoved(_ update: () -> Void) {
        let before = dropTarget
        update()
        guard let target = dropTarget, target.path != before?.path else { return }
        let leaving = springOpened.filter { target != $0 && !target.path.hasPrefix($0.path + "/") }
        withAnimation(.smooth(duration: 0.2)) {
            workspace.expanded.subtract(leaving)
            springOpened.subtract(leaving)
        }
        expandTask?.cancel()
        expandTask = Task {
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled, externalDrop != nil, dropTarget?.path == target.path,
                  target.path != workspace.root.path else { return }
            withAnimation(.smooth(duration: 0.2)) {
                if workspace.expanded.insert(target.standardizedFileURL).inserted { springOpened.insert(target.standardizedFileURL) }
            }
        }
    }

    private func closeSpringFolders() {
        withAnimation(.smooth(duration: 0.2)) {
            workspace.expanded.subtract(springOpened)
            springOpened.removeAll()
        }
    }

    /// Files from Finder move in like Finder does on the same disk; holding Option copies them.
    private func importDropped(_ urls: [URL], at location: CGPoint, copy: Bool) {
        expandTask?.cancel()
        externalDrop = nil
        springOpened.removeAll()
        onExternalDrag(false)
        let target = folder(at: location)
        withAnimation(.smooth(duration: 0.25)) { workspace.importItems(urls, into: target, copy: copy) }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Shared by the right-click menu and the row's ellipsis button.
    private func menuItems(for node: FileNode) -> [SidebarMenuItem] {
        var items: [SidebarMenuItem] = []
        if node.children != nil {
            items += createItems(in: node.url)
            items.append(.divider)
            items.append(.init("Rename Folder…", "pencil") { renaming = node.url })
        } else {
            if node.isPreviewable {
                let previewed = node.url == workspace.previewFile
                items.append(.init(previewed ? workspace.previewMode.nextTitle : "Preview", previewed ? workspace.previewMode.icon : "eye") {
                    workspace.togglePreview(node.url)
                })
            }
            items.append(.init("Rename File…", "pencil") { renaming = node.url })
            items.append(.init("Open in New Window", "macwindow.badge.plus") {
                Opener.shared.openInNewWindow(workspace.root, file: node.url)
            })
            if FileHistory.isAvailable(for: node.url) {
                items.append(.init("Show History…", "clock.arrow.circlepath") { FileHistory.show(node.url, in: workspace) })
            }
            if SpaceRepository.shared.hasConflict(node.url) {
                items.append(.init("Resolve Conflict…", "arrow.triangle.merge") { FileHistory.resolve(node.url, in: workspace) })
            }
        }
        items.append(.divider)
        items.append(.init("Reveal in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) })
        if SpaceList.isInRepository(workspace.root) {
            items.append(.init("Link to…", "link") { Opener.shared.link(node.url) })
            items.append(.init("Share…", "person.badge.plus") { Invites.share(node.url) })
        }
        items.append(.init("Copy Absolute Path", "doc.on.doc") { copyPath(node.url) })
        items.append(.init("Copy Relative Path", "doc.on.doc") {
            copyPath(String(node.url.path.dropFirst(workspace.root.path.count + 1)))
        })
        items.append(.divider)
        items.append(.init("Duplicate", "plus.square.on.square") { treeAction { workspace.duplicate(node.url) } })
        if SpaceList.isInRepository(workspace.root) {
            if node.children != nil {
                items.append(.init("Show Recently Deleted in This Folder", "trash.slash") { RecentlyDeleted.show(in: node.url) })
            }
            items.append(.init("Delete", "trash") { treeAction { workspace.delete(node.url) } })
        } else {
            items.append(.init("Move to Trash", "trash") { treeAction { workspace.delete(node.url) } })
        }
        return items
    }

    private func spaceMenuItems(rename: @escaping () -> Void) -> [SidebarMenuItem] {
        createItems(in: nil) + [
            .divider,
            .init("Rename Space…", "pencil", action: rename),
            .init("Reveal in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.root]) },
            .init("Copy Path", "doc.on.doc") { copyPath(workspace.root) },
        ] + (SpaceList.isInRepository(workspace.root) ? [
            .init("Link to…", "link") { Opener.shared.link(workspace.root) },
            .init("Share…", "person.badge.plus") { Invites.share(workspace.root) },
            .init("Show Recently Deleted", "trash.slash") { RecentlyDeleted.show(in: workspace.root) },
        ] : []) + [
            .divider,
            .init("Open in New Window", "macwindow.badge.plus") { Opener.shared.openInNewWindow(workspace.root) },
            .init("Close Space", "xmark") { Opener.shared.closeSpace() },
        ]
    }

    private func createItems(in dir: URL?) -> [SidebarMenuItem] {
        [
            .init("New File", "doc.badge.plus") { onCreateFile(dir ?? workspace.root) },
            .init("New Folder", "folder.badge.plus") { onCreateFolder(dir ?? workspace.root) },
        ]
    }

    /// A change made in the tree: ⌘Z should undo it, so the editor gives up the keyboard.
    private func treeAction(_ body: () -> Void) {
        withAnimation(.smooth(duration: 0.2)) { body() }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func isInTree(_ url: URL) -> Bool { url.path.hasPrefix(workspace.root.path + "/") }

    /// Opens the folders around the selected file, scrolls to it and tints it for a moment.
    private func revealSelected(_ proxy: ScrollViewProxy) {
        guard let file = workspace.selectedFile, isInTree(file) else { return }
        var folders: [URL] = []
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while dir.path != workspace.root.path, dir.path.hasPrefix(workspace.root.path + "/") {
            folders.append(dir)
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
        withAnimation(.smooth(duration: 0.2)) { workspace.expanded.formUnion(folders) }
        // Scroll once the opened rows exist.
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(file, anchor: .center) }
            withAnimation(.easeOut(duration: 0.15)) { flashed = file }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeOut(duration: 0.5)) { if flashed == file { flashed = nil } }
            }
        }
    }

    private func tap(_ node: FileNode) {
        if node.children != nil {
            withAnimation(.smooth(duration: 0.2)) {
                if workspace.expanded.contains(node.url) {
                    workspace.expanded.remove(node.url)
                } else {
                    workspace.expanded.insert(node.url)
                }
            }
        } else if node.kind.isOpenable {
            withAnimation(.smooth(duration: 0.3)) { workspace.select(node.url) }
            // The row's drag gesture sees every click, so a double click is read off the mouse-up.
            if node.isPreviewable, (NSApp.currentEvent?.clickCount ?? 1) >= 2 { workspace.previewSelectedFile(ifEnabled: true) }
        }
    }
}

/// Accepts file URLs from other apps and reports the pointer while they hover.
struct ExternalDrop: DropDelegate {
    let onMove: (CGPoint) -> Void
    let onExit: () -> Void
    let onDrop: ([URL], CGPoint, Bool) -> Void

    func dropEntered(info: DropInfo) { onMove(info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onMove(info.location)
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func dropExited(info: DropInfo) { onExit() }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let location = info.location
        let copy = NSEvent.modifierFlags.contains(.option)
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.load(provider) { urls.append(url) }
            }
            onDrop(urls, location, copy)
        }
        return true
    }

    private static func load(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }
}

func copyPath(_ url: URL) { copyPath(url.path) }

func copyPath(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}

/// One menu entry, rendered as a SwiftUI context menu and as an NSMenu so both stay identical.
struct SidebarMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let image: String?
    let action: (() -> Void)?

    init(_ title: String, _ image: String?, action: @escaping () -> Void) {
        self.title = title
        self.image = image
        self.action = action
    }

    private init() {
        title = ""
        image = nil
        action = nil
    }

    static var divider: SidebarMenuItem { SidebarMenuItem() }

    static func menu(_ items: [SidebarMenuItem]) -> NSMenu {
        let menu = NSMenu()
        for item in items {
            guard let action = item.action else {
                menu.addItem(.separator())
                continue
            }
            let entry = ActionMenuItem(title: item.title, handler: action)
            entry.image = item.image.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        return menu
    }

    private final class ActionMenuItem: NSMenuItem {
        private let handler: () -> Void

        init(title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError() }

        @objc private func run() { handler() }
    }
}

struct SidebarMenuContent: View {
    let items: [SidebarMenuItem]

    var body: some View {
        ForEach(items) { item in
            if let action = item.action {
                Button(action: action) {
                    if let image = item.image { Label(item.title, systemImage: image) } else { Text(item.title) }
                }
            } else {
                Divider()
            }
        }
    }
}

/// Zen-style press feedback: the button shrinks while held and springs back.
struct ZenPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Zen-style square icon button face with its own hover fill.
struct ZenIcon: View {
    let systemName: String
    var size: CGFloat = 24
    var active = false
    var idleFill = true
    var rotation: Double = 0
    @State private var hovered = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .medium))
            .rotationEffect(.degrees(rotation))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: rotation)
            .foregroundStyle(active ? .primary : .secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Color.primary.opacity(fill)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var fill: Double {
        if hovered || active { return 0.14 }
        return idleFill ? 0.07 : 0
    }
}

/// Icon button that pops up an NSMenu, so it knows when the menu is open.
struct ZenMenuButton: View {
    let systemName: String
    var size: CGFloat = 24
    var rotatesWhenOpen = false
    var idleFill = true
    var onOpenChange: (Bool) -> Void = { _ in }
    let items: () -> [SidebarMenuItem]
    @State private var isOpen = false
    @State private var anchor = MenuAnchor.Box()

    init(systemName: String, size: CGFloat = 24, rotatesWhenOpen: Bool = false, idleFill: Bool = true,
         onOpenChange: @escaping (Bool) -> Void = { _ in }, items: @escaping () -> [SidebarMenuItem]) {
        self.systemName = systemName
        self.size = size
        self.rotatesWhenOpen = rotatesWhenOpen
        self.idleFill = idleFill
        self.onOpenChange = onOpenChange
        self.items = items
    }

    var body: some View {
        Button(action: open) {
            ZenIcon(systemName: systemName, size: size, active: isOpen, idleFill: idleFill,
                    rotation: rotatesWhenOpen && isOpen ? 45 : 0)
        }
        .buttonStyle(ZenPressStyle())
        .background(MenuAnchor(box: anchor))
    }

    private func open() {
        let menu = SidebarMenuItem.menu(items())
        isOpen = true
        onOpenChange(true)
        // Defer so the open state renders before the menu's tracking loop starts.
        DispatchQueue.main.async {
            if let view = anchor.view {
                Popups.show(menu, at: NSPoint(x: 0, y: -4), in: view)
            }
            isOpen = false
            onOpenChange(false)
        }
    }
}

/// Exposes the button's NSView so the menu can be placed below it.
private struct MenuAnchor: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Space name above the file tree; clicking it renames the space folder.
private struct SpaceHeader: View {
    let name: String
    let url: URL
    @Binding var renaming: Bool
    let isExternal: Bool
    var isDropTarget = false
    let canReveal: Bool
    let onReveal: () -> Void
    let onRename: (String) -> Void
    let onShowSpaces: () -> Void
    let menuItems: (_ rename: @escaping () -> Void) -> [SidebarMenuItem]
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onShowSpaces) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ZenPressStyle())
            .help("Spaces (\(KeyLayout.current.shortcuts.showSpaces.display))")
            if renaming {
                RenameField(name: name, base: name, weight: .semibold) { new in
                    guard renaming else { return }
                    renaming = false
                    if let new { onRename(new) }
                }
            } else {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .pointerStyle(.horizontalText)
            }
            Spacer(minLength: 0)
            if isExternal { ExternalSpaceBadge() }
            SharingBadge(url: url)
            if hovered && canReveal && !renaming {
                Button(action: onReveal) {
                    ZenIcon(systemName: "scope", size: 24, idleFill: false)
                }
                .buttonStyle(ZenPressStyle())
                .help("Reveal the open file")
                .transition(.opacity)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isDropTarget ? AnyShapeStyle(Color.accentColor.opacity(0.2))
                : AnyShapeStyle(Color.primary.opacity(hovered && !renaming ? 0.06 : 0))))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onTapGesture { renaming = true }
        .help("Rename space")
        .contextMenu { SidebarMenuContent(items: menuItems { renaming = true }) }
    }
}

/// Native field editing keeps focus and selection stable while the tree redraws.
struct RenameField: NSViewRepresentable {
    let name: String
    let base: String
    var weight: NSFont.Weight = .regular
    let onRename: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRename: onRename) }

    func makeNSView(context: Context) -> NSTextField {
        let field = Field(string: name)
        field.baseLength = (base as NSString).length
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13, weight: weight)
        field.delegate = context.coordinator
        field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onRename = onRename
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: nsView.intrinsicContentSize.height)
    }

    final class Field: NSTextField {
        var baseLength = 0
        private var selectedName = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !selectedName else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, !self.selectedName else { return }
                guard window.makeFirstResponder(self), let editor = self.currentEditor() else { return }
                editor.selectedRange = NSRange(location: 0, length: min(self.baseLength, (editor.string as NSString).length))
                self.selectedName = true
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onRename: (String?) -> Void
        private var finished = false

        init(onRename: @escaping (String?) -> Void) { self.onRename = onRename }

        private func finish(_ name: String?) {
            guard !finished else { return }
            finished = true
            onRename(name)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.cancelOperation(_:)):
                finish(nil)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                finish(textView.string)
            default:
                return false
            }
            return true
        }
    }
}

/// Floating label under the pointer while a file is dragged.
private struct FileRow: View {
    let node: FileNode
    let depth: Int
    let isSelected: Bool
    let isPreviewed: Bool
    let previewMode: PreviewMode
    let isExpanded: Bool
    let isRenaming: Bool
    let isDragged: Bool
    let isDropTarget: Bool
    let onTap: () -> Void
    let onDrag: () -> Void
    let onTogglePreview: () -> Void
    let onStartRename: () -> Void
    let onRename: (String?) -> Void
    let menuItems: () -> [SidebarMenuItem]
    @State private var hovered = false
    @State private var pressed = false
    @State private var menuOpen = false

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }
    private var isFolder: Bool { node.children != nil }
    /// Only the selected file's name is editable by clicking it.
    private var canClickToRename: Bool { isSelected && node.kind.isOpenable && !isRenaming }

    var body: some View {
        HStack(spacing: 8) {
            leadingIcon
            if isRenaming {
                RenameField(name: node.name, base: isFolder ? node.name : node.url.deletingPathExtension().lastPathComponent,
                            onRename: onRename)
            } else {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .pointerStyle(canClickToRename ? .horizontalText : nil)
                    .gesture(TapGesture().onEnded(onStartRename), including: canClickToRename ? .all : .none)
            }
            Spacer(minLength: 0)
            if SpaceRepository.shared.hasConflict(node.url) && !(isFolder && (hovered || menuOpen)) { ConflictBadge() }
            SharingBadge(url: node.url)
            if isFolder && !isRenaming && (hovered || menuOpen) {
                ZenMenuButton(systemName: "ellipsis", onOpenChange: { menuOpen = $0 }, items: menuItems)
                    .help("More")
            } else if node.isPreviewable && !isRenaming && (hovered || isPreviewed) {
                Button(action: onTogglePreview) {
                    ZenIcon(systemName: isPreviewed ? previewMode.icon : "eye", active: isPreviewed)
                }
                .buttonStyle(ZenPressStyle())
                .help(isPreviewed ? previewMode.nextTitle : "Preview this file")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .opacity(node.kind == .binary ? 0.5 : 1)
        .padding(.leading, 10 + CGFloat(depth) * 14)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(Self.shape.fill(isDropTarget ? AnyShapeStyle(Color.accentColor.opacity(0.2))
            : AnyShapeStyle(Color.primary.opacity(fill))))
        // The source stays visible while the system draws the drag image.
        .opacity(isDragged ? 0.4 : 1)
        .contentShape(Self.shape)
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: pressed)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture(perform: onTap)
        .gesture(FileDragGesture(url: node.url, enabled: !isRenaming, onBegin: onDrag))
        .contextMenu { SidebarMenuContent(items: menuItems()) }
    }

    /// Folders swap their icon for the disclosure chevron while hovered.
    @ViewBuilder
    private var leadingIcon: some View {
        if isFolder && (hovered || menuOpen) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 16)
        } else if node.isTypst {
            // Typst sources stand out in the tree in Typst's teal.
            Image(systemName: "t.square.fill")
                .foregroundStyle(Self.typstColor)
                .frame(width: 16)
        } else if MarkdownRenderer.isMarkdown(node.url) {
            Image(systemName: "m.square.fill")
                .foregroundStyle(Self.markdownColor)
                .frame(width: 16)
        } else {
            Image(systemName: icon).frame(width: 16)
        }
    }

    static let typstColor = Color(red: 0.14, green: 0.62, blue: 0.68)
    static let markdownColor = Color(red: 0.35, green: 0.47, blue: 0.85)

    private var fill: Double {
        if isSelected { return 0.12 }
        return hovered || menuOpen ? 0.06 : 0
    }

    static func documentIcon(_ ext: String) -> String {
        switch ext {
        case "xls", "xlsx", "xlsm", "xlt", "xltx", "numbers", "ods": return "tablecells"
        case "ppt", "pptx", "pptm", "pot", "potx", "pps", "ppsx", "key", "odp": return "rectangle.on.rectangle"
        default: return "doc.text.image"
        }
    }

    private var icon: String {
        switch node.kind {
        case .folder: return "folder"
        case .typst: return "t.square.fill"
        case .pdf: return "doc.richtext"
        case .font: return "textformat"
        case .document: return Self.documentIcon(node.url.pathExtension.lowercased())
        case .image: return "photo"
        case .text, .binary:
            switch node.url.pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tiff": return "photo"
            case "bib": return "books.vertical"
            default: return node.kind == .text ? "doc.text" : "doc"
            }
        }
    }
}
