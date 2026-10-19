import AppKit
import SwiftUI

/// The window's sidebar: the space's file tree, which shrinks away while the selector covers it.
struct SpacesSidebar: View {
    let state: WindowState
    let workspace: Workspace?

    var body: some View {
        GeometryReader { geo in
            let progress = workspace == nil ? 1 : state.spacesProgress
            ZStack {
                if let workspace {
                    SidebarView(workspace: workspace, onShowSpaces: { state.setSpacesOpen(true) }) { name in
                        Opener.shared.rename(workspace, to: name, in: state)
                    }
                    .id(ObjectIdentifier(workspace))
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .scaleEffect(1 - 0.08 * progress)
                    .opacity(1 - progress)
                    .allowsHitTesting(progress == 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SpaceSwipe(state: state, width: geo.size.width + WindowState.spacesExtra))
            // The selector lives above the split view so it can grow past the sidebar.
            .onChange(of: geo.frame(in: .global), initial: true) { _, frame in state.sidebarFrame = frame }
        }
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
        let frame = state.sidebarFrame
        let extra = WindowState.spacesExtra * progress
        // Always the open width, so labels never rewrap while it slides.
        let width = frame.width + WindowState.spacesExtra
        ZStack(alignment: .topLeading) {
            // Unmounted while closed: over the split view it would swallow the divider's hover, cursor and drags.
            if state.selectorMounted {
                // Widens the sidebar's material into the detail column, which moves aside by as much.
                SidebarMaterial()
                    .frame(width: extra)
                    .frame(maxHeight: .infinity)
                    .offset(x: frame.maxX)
                SpacesPane(state: state, current: workspace?.root.path, canClose: workspace != nil, spaces: spaces) {
                    spaces = SpaceList.all
                }
                    .frame(width: width, height: frame.height)
                    .offset(x: frame.minX - width * (1 - progress), y: frame.minY)
                    .allowsHitTesting(progress == 1)
                if progress == 1 {
                    // The split view's own divider is covered, so the selector's edge takes over.
                    SidebarResizeHandle(state: state)
                        .frame(width: 8)
                        .frame(maxHeight: .infinity)
                        .offset(x: frame.maxX + WindowState.spacesExtra - 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear { spaces = SpaceList.all }
        .onChange(of: state.spacesProgress > 0) { spaces = SpaceList.all }
        .onChange(of: workspace?.root) { spaces = SpaceList.all }
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

/// Drags the sidebar's divider while the selector covers it.
private struct SidebarResizeHandle: View {
    let state: WindowState
    @State private var start: CGFloat?
    @State private var splitView: NSSplitView?

    @State private var hovered = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            // Same 1pt line the sidebar's own divider shows while hovered or dragged.
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.4))
                    .frame(width: 1)
                    .opacity(hovered || start != nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: hovered || start != nil)
            }
            .pointerStyle(.columnResize)
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
private struct SpacesPane: View {
    let state: WindowState
    let current: String?
    let canClose: Bool
    let spaces: [URL]
    let onChange: () -> Void
    @State private var drag: (url: URL, offset: CGFloat)?

    private static let rowHeight: CGFloat = 42
    private static let pitch = rowHeight + 2

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(spaces.enumerated()), id: \.element) { index, url in
                    SpaceRow(url: url, isCurrent: url.path == current, isDragged: drag?.url == url) {
                        open(url)
                    } onRemove: {
                        SpaceList.remove(url)
                        onChange()
                    } onDrag: { offset in
                        drag = (url, offset)
                    } onDrop: {
                        drop()
                    }
                    .offset(y: offset(of: index))
                    .zIndex(drag?.url == url ? 1 : 0)
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
                OpenSpaceRow { Opener.shared.openPanel(in: state) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Text("Spaces")
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .frame(height: 34)
            .padding(.bottom, 2)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if canClose { SpacesButton(active: true) { state.setSpacesOpen(false) } }
                Spacer()
            }
            .frame(height: 28)
            .padding(10)
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var source: Int? {
        drag.flatMap { d in spaces.firstIndex(of: d.url) }
    }

    /// Where the dragged row would land if dropped now.
    private var target: Int? {
        guard let drag, let source else { return nil }
        return min(max(source + Int((drag.offset / Self.pitch).rounded()), 0), spaces.count - 1)
    }

    /// The dragged row follows the pointer; the rows it passes make room for it.
    private func offset(of index: Int) -> CGFloat {
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
    let isDragged: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void
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
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
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
                }
        )
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy Path") { copyPath(url) }
            Divider()
            Button("Remove from Spaces", action: onRemove).disabled(isCurrent)
        }
        .help("Drag to reorder")
    }

    private var fill: Double {
        if isCurrent { return 0.12 }
        return hovered ? 0.06 : 0
    }

    private var subtitle: String {
        let path = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard let branch = SpaceList.branch(of: url) else { return path }
        return "\(path) · \(branch)"
    }
}

/// Like Zen's "New Tab" row: a quiet plus at the end of the list.
private struct OpenSpaceRow: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus").frame(width: 16)
                Text("Open Space…")
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
        .help("Open a folder as a space")
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
private struct SpaceSwipe: NSViewRepresentable {
    let state: WindowState
    let width: CGFloat

    func makeNSView(context: Context) -> SwipeView { SwipeView() }

    func updateNSView(_ view: SwipeView, context: Context) {
        view.state = state
        view.width = width
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SwipeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class SwipeView: NSView {
        var state: WindowState?
        var width: CGFloat = 1
        private var monitor: Any?
        /// nil until the gesture's direction is known.
        private var tracking: Bool?
        private var start: CGFloat = 0
        private var distance = CGSize.zero
        private var lastDelta: CGFloat = 0
        private var swallowMomentum = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let state, event.window === window, event.hasPreciseScrollingDeltas, state.space != nil else { return event }
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
                // Over the sidebar always; anywhere once the selector covers it, to swipe back.
                let inside = bounds.contains(convert(event.locationInWindow, from: nil))
                tracking = inside || state.spacesOpen ? nil : false
                start = state.spacesProgress
                distance = .zero
                lastDelta = 0
                swallowMomentum = false
                return event
            case .changed:
                guard tracking != false else { return event }
                distance.width += dx
                distance.height += event.scrollingDeltaY
                if tracking == nil {
                    guard abs(distance.width) + abs(distance.height) > 6 else { return event }
                    let opening = distance.width > 0
                    let horizontal = abs(distance.width) > abs(distance.height) * 1.5
                    tracking = horizontal && opening != state.spacesOpen
                    guard tracking == true else { return event }
                    state.selectorMounted = true
                }
                if dx != 0 { lastDelta = dx }
                state.swipe = min(max(start + distance.width / max(width, 1), 0), 1)
                return nil
            case .ended, .cancelled:
                guard tracking == true else {
                    tracking = nil
                    return event
                }
                tracking = nil
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
