import AppKit
import SwiftUI

struct SidebarView: View {
    let workspace: Workspace
    @State private var renaming: URL?

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
        content
            // Same behind-window blur as the preview instead of the wallpaper-tinted default.
            .background(SidebarMaterial().ignoresSafeArea())
    }

    private var content: some View {
        GeometryReader { geo in
            ScrollView {
                fileList
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    // Empty space moves the window; rows and buttons keep their own gestures.
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                ZenMenuButton(systemName: "plus", size: 28, rotatesWhenOpen: true, idleFill: false) {
                    createItems(in: nil)
                }
                .help("New file or folder")
            }
            .padding(10)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
        }
    }

    private var fileList: some View {
        LazyVStack(spacing: 2) {
            ForEach(rows) { row in
                FileRow(
                    node: row.node,
                    depth: row.depth,
                    isSelected: row.node.url == workspace.selectedFile,
                    isPreviewed: row.node.url == workspace.previewFile,
                    isExpanded: workspace.expanded.contains(row.node.url),
                    isRenaming: renaming == row.node.url,
                    onTap: { tap(row.node) },
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
    }

    /// Shared by the right-click menu and the row's ellipsis button.
    private func menuItems(for node: FileNode) -> [SidebarMenuItem] {
        var items: [SidebarMenuItem] = []
        if node.children != nil {
            items += createItems(in: node.url)
            items.append(.divider)
            items.append(.init("Rename Folder…", "pencil") { renaming = node.url })
        } else {
            if node.isTypst {
                let previewed = node.url == workspace.previewFile
                items.append(.init(previewed ? "Hide Preview" : "Preview", previewed ? "eye.slash" : "eye") {
                    workspace.togglePreview(node.url)
                })
            }
            items.append(.init("Rename File…", "pencil") { renaming = node.url })
        }
        items.append(.divider)
        items.append(.init("Reveal in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) })
        return items
    }

    private func createItems(in dir: URL?) -> [SidebarMenuItem] {
        [
            .init("New File", "doc.badge.plus") { create { workspace.createFile(in: dir) } },
            .init("New Folder", "folder.badge.plus") { create { workspace.createFolder(in: dir) } },
        ]
    }

    /// Expands the parent and starts renaming the new item.
    private func create(_ make: () -> URL) {
        let url = make()
        workspace.expanded.insert(url.deletingLastPathComponent().standardizedFileURL)
        renaming = url
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
        } else if node.isEditable {
            workspace.select(node.url)
        }
    }
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

private struct SidebarMenuContent: View {
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
private struct ZenPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Zen-style square icon button face with its own hover fill.
private struct ZenIcon: View {
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
private struct ZenMenuButton: View {
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
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
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

/// Zen-style tab row: rounded tile, hover fill, slight zoom while pressed.
private struct FileRow: View {
    let node: FileNode
    let depth: Int
    let isSelected: Bool
    let isPreviewed: Bool
    let isExpanded: Bool
    let isRenaming: Bool
    let onTap: () -> Void
    let onTogglePreview: () -> Void
    let onStartRename: () -> Void
    let onRename: (String?) -> Void
    let menuItems: () -> [SidebarMenuItem]
    @State private var hovered = false
    @State private var pressed = false
    @State private var menuOpen = false
    @State private var draft = ""
    @State private var selection: TextSelection?
    @State private var clickMonitor: Any?
    @FocusState private var focused: Bool

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }
    private var isFolder: Bool { node.children != nil }
    /// Only the selected file's name is editable by clicking it.
    private var canClickToRename: Bool { isSelected && node.isEditable && !isRenaming }

    var body: some View {
        HStack(spacing: 8) {
            leadingIcon
            if isRenaming {
                renameField
            } else {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .pointerStyle(canClickToRename ? .horizontalText : nil)
                    .gesture(TapGesture().onEnded(onStartRename), including: canClickToRename ? .all : .none)
            }
            Spacer(minLength: 0)
            if isFolder && !isRenaming && (hovered || menuOpen) {
                ZenMenuButton(systemName: "ellipsis", onOpenChange: { menuOpen = $0 }, items: menuItems)
                    .help("More")
            } else if node.isTypst && !isRenaming && (hovered || isPreviewed) {
                Button(action: onTogglePreview) {
                    ZenIcon(systemName: isPreviewed ? "eye.fill" : "eye", active: isPreviewed)
                }
                .buttonStyle(ZenPressStyle())
                .help(isPreviewed ? "Hide preview" : "Preview this file")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .opacity(node.isEditable || isFolder ? 1 : 0.5)
        .padding(.leading, 10 + CGFloat(depth) * 14)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(Self.shape.fill(Color.primary.opacity(fill)))
        .contentShape(Self.shape)
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: pressed)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { value in
                    pressed = false
                    // Releasing outside the row cancels, like a button.
                    if abs(value.translation.width) < 40 && abs(value.translation.height) < 17 { onTap() }
                },
            including: isRenaming ? .subviews : .all
        )
        .contextMenu { SidebarMenuContent(items: menuItems()) }
    }

    private var renameField: some View {
        TextField("Name", text: $draft, selection: $selection)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { onRename(draft) }
            .onExitCommand { onRename(nil) }
            .onChange(of: focused) { _, now in
                if now { selectBaseName() } else { onRename(draft) }
            }
            .onAppear {
                draft = node.name
                focused = true
                // Clicks elsewhere don't always take focus, so watch for them directly.
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                    if !Self.isTextField(event.window?.contentView?.hitTest(event.locationInWindow)) {
                        onRename(draft)
                    }
                    return event
                }
            }
            .onDisappear {
                if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
                clickMonitor = nil
            }
    }

    /// Preselects the name without its extension, like Finder.
    private func selectBaseName() {
        let base = isFolder ? node.name : node.url.deletingPathExtension().lastPathComponent
        let length = (base as NSString).length
        // Focusing selects everything, sometimes a beat later; override it once that settled.
        for delay in [0.0, 0.05] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard focused else { return }
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                    editor.setSelectedRange(NSRange(location: 0, length: min(length, (editor.string as NSString).length)))
                } else {
                    let end = draft.index(draft.startIndex, offsetBy: min(base.count, draft.count))
                    selection = TextSelection(range: draft.startIndex..<end)
                }
            }
        }
    }

    private static func isTextField(_ view: NSView?) -> Bool {
        var view = view
        while let current = view {
            if current is NSTextField || (current as? NSTextView)?.isFieldEditor == true { return true }
            view = current.superview
        }
        return false
    }

    /// Folders swap their icon for the disclosure chevron while hovered.
    @ViewBuilder
    private var leadingIcon: some View {
        if isFolder && (hovered || menuOpen) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 16)
        } else {
            Image(systemName: icon).frame(width: 16)
        }
    }

    private var fill: Double {
        if isSelected { return 0.12 }
        return hovered || menuOpen ? 0.06 : 0
    }

    private var icon: String {
        if isFolder { return "folder" }
        switch node.url.pathExtension.lowercased() {
        case "typ": return "t.square"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "bib": return "books.vertical"
        case "pdf": return "doc.richtext"
        default: return "doc.text"
        }
    }
}
