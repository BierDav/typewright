import AppKit
import CoreImage
import Observation
import SwiftUI

enum WindowOverlay: Equatable {
    /// Opens on the page of the command with this id, like "file.move".
    case palette(page: String? = nil)
    /// Searches every space when true, the current space when false; nil follows the window, so the
    /// space overview searches all spaces and a space searches itself.
    case search(allSpaces: Bool?)
}

@MainActor @Observable
final class WindowState {
    var space: URL?
    /// Whether the space selector covers the file tree.
    var spacesOpen = false
    /// The command palette or full text search over the window.
    var overlay: WindowOverlay?
    /// A file and line to show once the window switched to its space.
    var pendingReveal: SourceLocation?
    /// A file to select once the window opened its space, keeping its saved caret.
    var pendingFile: URL?
    var sidebarVisible = true {
        didSet { if sidebarVisible { floatingSidebar = false } }
    }
    /// The hidden sidebar floating over the space while the pointer is near the window's left edge.
    var floatingSidebar = false
    /// The window's content size, to place the selector and floating sidebar while the sidebar is hidden.
    var windowSize = CGSize(width: 1280, height: 820)
    /// Set while switching with ⌘1–9: true moves to a later space in the list, so the new one slides in from the right.
    var switchForward: Bool?

    /// Spaces zoom in from behind the selector, or slide sideways when switched by number.
    var spaceTransition: AnyTransition {
        guard let switchForward else { return .opacity.combined(with: .scale(scale: 0.96)) }
        let shift: CGFloat = switchForward ? 70 : -70
        return .asymmetric(insertion: .offset(x: shift).combined(with: .opacity),
                           removal: .offset(x: -shift).combined(with: .opacity))
    }

    /// The space shown, for menu commands.
    @ObservationIgnored weak var workspace: Workspace?
    /// Live selector progress while a two-finger swipe drives it.
    var swipe: CGFloat?
    /// Whether the selector overlay is in the view tree; it stays a moment after closing to animate out.
    var selectorMounted = false
    /// Where the sidebar's content sits in the window; the selector overlay lines up with it.
    var sidebarFrame = CGRect(x: 0, y: 52, width: 220, height: 700) {
        didSet {
            // Remembered across launches; only real resizes count, not the first layout pass.
            guard sidebarFrame.width != oldValue.width, sidebarFrame.width >= Self.minSidebarWidth else { return }
            sidebarWidth = sidebarFrame.width
            UserDefaults.standard.set(Double(sidebarFrame.width), forKey: Self.sidebarWidthKey)
        }
    }
    /// The sidebar width the window opens with.
    let initialSidebarWidth: CGFloat
    /// The last real sidebar width; collapsing reports bogus frames.
    private var sidebarWidth: CGFloat

    /// Where the selector and the floating sidebar sit: over the sidebar, or along the left edge while it's hidden.
    var panelFrame: CGRect {
        guard !sidebarVisible else { return sidebarFrame }
        return CGRect(x: 0, y: sidebarFrame.minY, width: sidebarWidth, height: max(windowSize.height - sidebarFrame.minY, 0))
    }

    static let minSidebarWidth: CGFloat = 180
    private static let sidebarWidthKey = "sidebarWidth"

    static let spacesAnimation = Animation.smooth(duration: 0.35)
    /// How far the open selector reaches past the sidebar, pushing the space aside.
    static let spacesExtra: CGFloat = 150

    init(space: URL?) {
        self.space = space
        let saved = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        initialSidebarWidth = saved >= Self.minSidebarWidth ? saved : 220
        sidebarWidth = initialSidebarWidth
    }

    /// Opens or closes the selector with its slide.
    func setSpacesOpen(_ open: Bool) {
        guard open, !selectorMounted else {
            return withAnimation(Self.spacesAnimation) { spacesOpen = open }
        }
        // Mount it off-screen first, so it slides in instead of appearing in place.
        selectorMounted = true
        DispatchQueue.main.async {
            withAnimation(Self.spacesAnimation) { self.spacesOpen = true }
        }
    }

    /// 0 shows the file tree, 1 the selector.
    var spacesProgress: CGFloat {
        swipe ?? (spacesOpen ? 1 : 0)
    }
}

/// One window that shows a space, switching in place.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let state: WindowState

    init(space: URL?) {
        state = WindowState(space: space)
        let host = NSHostingController(rootView: MainWindow(state: state))
        host.sceneBridgingOptions = .all
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Opener.shared.closed(self)
    }
}

struct MainWindow: View {
    let state: WindowState
    @State private var workspace: Workspace?

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { state.sidebarVisible ? .all : .detailOnly },
                                                      set: { state.sidebarVisible = $0 != .detailOnly })) {
            SpacesSidebar(state: state, workspace: workspace)
                .navigationSplitViewColumnWidth(min: WindowState.minSidebarWidth, ideal: state.initialSidebarWidth)
        } detail: {
            Group {
                if let workspace {
                    SpaceView(workspace: workspace)
                        .id(ObjectIdentifier(workspace))
                        .transition(state.spaceTransition)
                } else {
                    NoSpaceView()
                        .transition(state.spaceTransition)
                }
            }
            // Shifted, not squeezed; the window's edge cuts off what moves past it.
            .offset(x: WindowState.spacesExtra * (workspace == nil ? 1 : state.spacesProgress))
            .overlay { dimming }
        }
        .toolbar(removing: .sidebarToggle)
        .background {
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size, initial: true) { _, size in state.windowSize = size }
            }
            .ignoresSafeArea()
        }
        .overlay {
            if let workspace, !state.sidebarVisible { FloatingSidebar(state: state, workspace: workspace) }
        }
        .overlay { SpacesOverlay(state: state, workspace: workspace) }
        .overlay { WindowOverlayView(state: state, workspace: workspace) }
        .background(HiddenTitleBar(title: workspace?.selectedFile?.lastPathComponent ?? workspace?.name ?? "Typewright",
                                   subtitle: workspace?.name ?? ""))
        .onChange(of: state.space, initial: true) { _, url in
            let previous = workspace
            let next = url.map { Workspace(url: $0) }
            if let next { SpaceList.add(next.root) }
            if let next, let pending = state.pendingReveal, pending.url.path.hasPrefix(next.root.path + "/") {
                next.open(pending)
            }
            state.pendingReveal = nil
            if let next, let file = state.pendingFile, file.path.hasPrefix(next.root.path + "/") { next.select(file) }
            state.pendingFile = nil
            state.workspace = next
            // The selector slides away while the new space zooms in behind it.
            withAnimation(WindowState.spacesAnimation) {
                workspace = next
                state.spacesOpen = false
            }
            previous?.close()
            Opener.shared.saveSession()
            // Back to the zoom once the slide has played.
            if state.switchForward != nil {
                Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    if state.space == url { state.switchForward = nil }
                }
            }
        }
        .onDisappear { workspace?.close() }
    }

    /// Blurs and darkens the space behind the selector; clicking it returns to the space.
    private var dimming: some View {
        let progress = workspace == nil ? 0 : state.spacesProgress
        // A material rather than `.blur`, which can't reach the AppKit editor and PDF views underneath.
        // Its blur strength is fixed, so a half-transparent material reads as a light blur.
        return Rectangle()
            .fill(.ultraThinMaterial)
            .opacity(0.5)
            .overlay(Color.black.opacity(0.35))
            .opacity(progress)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            // The text and PDF views underneath would otherwise keep showing their own cursors.
            // Leaves the selector's strip free for its resize handle.
            .overlay {
                if progress > 0 {
                    CursorArea(isModal: true)
                        .padding(.leading, WindowState.spacesExtra * progress)
                        .ignoresSafeArea()
                }
            }
            .onTapGesture {
                state.setSpacesOpen(false)
            }
            .allowsHitTesting(progress > 0)
    }
}

/// The hidden sidebar as a floating card; it slides in while the pointer is at the window's left edge.
private struct FloatingSidebar: View {
    let state: WindowState
    let workspace: Workspace
    @State private var hideTask: Task<Void, Never>?

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        let available = state.spacesProgress == 0 && state.overlay == nil
        ZStack(alignment: .leading) {
            if available {
                // The strip that summons it; thin, so the editor's edge stays clickable.
                Color.clear
                    .frame(width: 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in inside ? show() : scheduleHide() }
            }
            if available && state.floatingSidebar {
                SidebarView(workspace: workspace, onShowSpaces: {
                    state.floatingSidebar = false
                    state.setSpacesOpen(true)
                }) { name in
                    Opener.shared.rename(space: workspace.root, to: name)
                }
                .frame(width: state.panelFrame.width)
                .background(SidebarMaterial())
                .clipShape(Self.shape)
                .overlay(Self.shape.stroke(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                .padding([.leading, .bottom], 8)
                .onHover { inside in inside ? show() : scheduleHide() }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.25), value: state.floatingSidebar)
        .onDisappear { hideTask?.cancel() }
    }

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        state.floatingSidebar = true
    }

    /// A short grace period, so brushing past its edge doesn't close it.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            state.floatingSidebar = false
        }
    }
}

/// Grayscale icon and a hint while the window has no space.
private struct NoSpaceView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .saturation(0)
                .opacity(0.55)
            Text("No Space Open")
                .font(.title3.weight(.semibold))
            Text("Select a space in the sidebar, or open a folder to use as a new one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Makes the title bar transparent with inset window buttons.
/// The title still feeds the Window menu.
private struct HiddenTitleBar: NSViewRepresentable {
    let title: String
    let subtitle: String

    func makeNSView(context: Context) -> NSView { WindowView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        window.title = title
        window.subtitle = subtitle
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }

    private final class WindowView: NSView {
        private var tracking: NSTrackingArea?
        // Lives as long as the window, like this view.
        private var frameObserver: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // An empty unified toolbar makes AppKit inset and center the window buttons itself.
            window.toolbar = NSToolbar(identifier: "SpaceTitleBar")
            window.toolbarStyle = .unified
            // The toolbar moves the buttons once it's laid out.
            DispatchQueue.main.async { [weak self] in self?.setUpTrafficLights() }
        }

        private var buttons: [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
        }

        /// The traffic lights stay quiet grey dots until the pointer is over them.
        private func setUpTrafficLights() {
            guard let close = buttons.first, let container = close.superview else { return }
            for button in buttons {
                button.wantsLayer = true
                button.layerUsesCoreImageFilters = true
            }
            setHighlighted(false, animated: false)
            close.postsFrameChangedNotifications = true
            if frameObserver == nil {
                frameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: close, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.updateTracking() } }
            }
            updateTracking(in: container)
        }

        private func updateTracking(in container: NSView? = nil) {
            guard let container = container ?? buttons.first?.superview else { return }
            if let tracking { container.removeTrackingArea(tracking) }
            let rect = buttons.map(\.frame).reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -4, dy: -4)
            let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
            container.addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { setHighlighted(true, animated: true) }
        override func mouseExited(with event: NSEvent) { setHighlighted(false, animated: true) }

        private var highlighted = false

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            setHighlighted(highlighted, animated: false)
        }

        private func setHighlighted(_ on: Bool, animated: Bool) {
            highlighted = on
            // One flat grey for all three; desaturating would keep each color's own brightness.
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let level: CGFloat = dark ? 0.55 : 0.45
            let grey = CIFilter(name: "CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: level, y: level, z: level, w: 0),
            ])!
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.15 : 0
                for button in buttons {
                    button.contentFilters = on ? [] : [grey]
                    button.animator().alphaValue = on ? 1 : 0.45
                }
            }
        }

    }
}
