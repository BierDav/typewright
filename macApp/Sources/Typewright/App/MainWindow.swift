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
    var spacesOpen = false {
        didSet {
            if spacesOpen {
                if !sidebarVisible { floatingSidebar = true }
                Popups.dismiss(in: window)
            }
        }
    }
    /// The command palette or full text search over the window.
    var overlay: WindowOverlay? {
        didSet {
            if overlay != nil {
                (workspace?.find.textView?.undoManager as? ActionUndoManager)?.checkpoint()
                undoManager.checkpoint()
                Popups.dismiss(in: window)
            }
        }
    }
    /// A question shown as a palette page instead of an alert; `overlay` names it by `id`.
    @ObservationIgnored var prompt: (id: String, page: PalettePage)?

    /// Asks `page` in the command palette; closing the palette is the answer "Cancel".
    func ask(_ page: PalettePage) {
        let id = "prompt.\(UUID().uuidString)"
        prompt = (id, page)
        overlay = .palette(page: id)
    }
    /// The window showing this state, whose popups close when something covers its content.
    @ObservationIgnored weak var window: NSWindow?
    /// Recovery stays visible even after its space closes.
    var deletionNotice: FileNotice?
    @ObservationIgnored private var deletionUndo: (() -> Void)?
    @ObservationIgnored private var deletionExpiry: Task<Void, Never>?

    func showDeletion(_ notice: FileNotice, undo: (() -> Void)? = nil) {
        deletionNotice = notice
        deletionUndo = undo ?? { [weak self] in self?.undoManager.undo() }
        deletionExpiry?.cancel()
        deletionExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if self?.deletionNotice?.id == notice.id { self?.dismissDeletion() }
        }
    }

    @discardableResult
    func undoDeletion() -> Bool {
        guard deletionNotice != nil, let undo = deletionUndo else { return false }
        dismissDeletion()
        undo()
        return true
    }

    func dismissDeletion() {
        deletionExpiry?.cancel()
        deletionExpiry = nil
        deletionNotice = nil
        deletionUndo = nil
    }

    /// A file and line to show once the window switched to its space.
    var pendingReveal: SourceLocation?
    /// A file to select once the window opened its space, keeping its saved caret.
    var pendingFile: URL?
    var historyFile: URL?
    var historyLines: Range<Int>?
    var pendingSession: WorkspaceSession?
    var renameNewSpace = false
    var relocatingSpace = false
    var sidebarVisible = true {
        didSet {
            if sidebarVisible { floatingSidebar = false }
            else if keepsFloatingSidebarOpen { floatingSidebar = true }
        }
    }
    /// The hidden sidebar floating over the space while the pointer is near the window's left edge.
    var floatingSidebar = false
    var keepsFloatingSidebarOpen: Bool { spacesOpen || swipe != nil }
    /// The window's content size, to place the selector and floating sidebar while the sidebar is hidden.
    var windowSize = CGSize(width: 1280, height: 820)
    /// Room for the window buttons at the top in full screen, where no toolbar holds them.
    var fullScreenTop: CGFloat = 0
    /// How far the menu bar reaches into a full screen window, on screens without a notch.
    var menuBarInset: CGFloat = 0
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
    /// File tree and space changes; the editor's text has its own.
    @ObservationIgnored let undoManager = ActionUndoManager()
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

    init(space: URL?, copying source: WindowState? = nil) {
        self.space = space
        pendingSession = source?.workspace?.session()
        sidebarVisible = source?.sidebarVisible ?? true
        let saved = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        initialSidebarWidth = source?.panelFrame.width ?? (saved >= Self.minSidebarWidth ? saved : 220)
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
    var onClose: (() -> Void)?
    private var deletionKeys: Any?

    init(space: URL?, file: URL? = nil, copying source: WindowState? = nil,
         restoring session: WindowSession? = nil, renameNewSpace: Bool = false) {
        state = WindowState(space: space, copying: source)
        state.pendingFile = file ?? session?.file
        if let saved = session?.workspace { state.pendingSession = WorkspaceSession(state: saved, buffers: [:]) }
        if let visible = session?.sidebarVisible { state.sidebarVisible = visible }
        state.renameNewSpace = renameNewSpace
        let host = NSHostingController(rootView: MainWindow(state: state))
        host.sceneBridgingOptions = .all
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        state.window = window
        window.delegate = self
        deletionKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.state.deletionNotice != nil else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "z", self.state.undoDeletion() { return nil }
            if !flags.contains(.command) { self.state.dismissDeletion() }
            return event
        }
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        if let deletionKeys { NSEvent.removeMonitor(deletionKeys) }
        deletionKeys = nil
        onClose?()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { state.undoManager }

    /// The frame before full screen, which a restored window comes back to when it leaves full screen.
    private(set) var windowedFrame: NSRect?

    func windowWillEnterFullScreen(_ notification: Notification) { windowedFrame = window?.frame }
    func windowDidEnterFullScreen(_ notification: Notification) { Opener.shared.saveSession() }
    func windowDidExitFullScreen(_ notification: Notification) {
        windowedFrame = nil
        Opener.shared.saveSession()
    }
    func windowDidMove(_ notification: Notification) { Opener.shared.saveSession() }
    func windowDidEndLiveResize(_ notification: Notification) { Opener.shared.saveSession() }

    // The empty toolbar would stay as an opaque strip; it comes down with the menu bar instead.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }
}

struct MainWindow: View {
    let state: WindowState
    @State private var workspace: Workspace?

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { state.sidebarVisible ? .all : .detailOnly },
                                                      set: { state.sidebarVisible = $0 != .detailOnly })) {
            SpacesSidebar(state: state, workspace: workspace)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if state.sidebarVisible { WindowNotifications(state: state, workspace: workspace, embedded: true) }
                }
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
            .offset(x: WindowState.spacesExtra * (workspace == nil ? 1 : state.sidebarVisible ? state.spacesProgress : 0))
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
        .overlay {
            if state.sidebarVisible || workspace == nil { SpacesOverlay(state: state, workspace: workspace) }
        }
        .overlay { WindowOverlayView(state: state, workspace: workspace) }
        .overlay(alignment: .bottomLeading) {
            if !state.sidebarVisible { WindowNotifications(state: state, workspace: workspace) }
        }
        // The whole window moves below the menu bar instead of hiding under it.
        .padding(.top, state.menuBarInset)
        .background(HiddenTitleBar(state: state,
                                   title: workspace?.selectedFile?.lastPathComponent ?? workspace?.name ?? "Typewright",
                                   subtitle: workspace?.name ?? ""))
        .onChange(of: state.space, initial: true) { _, url in
            let previous = workspace
            let next = url.map { Workspace(url: $0, session: state.pendingSession) }
            state.pendingSession = nil
            if let next { SpaceList.add(next.root) }
            if let next, let pending = state.pendingReveal, pending.url.path.hasPrefix(next.root.path + "/") {
                next.open(pending)
            }
            state.pendingReveal = nil
            if let next, let file = state.pendingFile, file.path.hasPrefix(next.root.path + "/") { next.select(file) }
            state.pendingFile = nil
            next?.fileOps.undoManager = state.undoManager
            next?.onNotice = { [weak state] notice in state?.showDeletion(notice) }
            next?.renamingSpace = state.renameNewSpace
            state.renameNewSpace = false
            // File changes undo within their space only.
            if let previous { state.undoManager.removeAllActions(withTarget: previous.fileOps) }
            state.workspace = next
            // The selector slides away while the new space zooms in behind it.
            if state.relocatingSpace {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { workspace = next }
                state.relocatingSpace = false
            } else {
                withAnimation(WindowState.spacesAnimation) {
                    workspace = next
                    state.spacesOpen = false
                }
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
        let progress = workspace == nil || !state.sidebarVisible ? 0 : state.spacesProgress
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
    @State private var spaces: [URL] = []
    @State private var hovering = false

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        let available = state.overlay == nil
        let progress = state.spacesProgress
        let sidebarWidth = state.panelFrame.width
        let openWidth = sidebarWidth + WindowState.spacesExtra
        let width = sidebarWidth + WindowState.spacesExtra * progress
        ZStack(alignment: .leading) {
            if available {
                // The strip that summons it; thin, so the editor's edge stays clickable.
                Color.clear
                    .frame(width: 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover(perform: hover)
            }
            if available && state.floatingSidebar {
                ZStack(alignment: .leading) {
                    SidebarView(workspace: workspace, onShowSpaces: { state.setSpacesOpen(true) },
                                onCreateFile: { Opener.shared.newFile(in: state, folder: $0) }) { name in
                        Opener.shared.rename(space: workspace.root, to: name)
                    }
                    .padding(.top, state.fullScreenTop)
                    .frame(width: sidebarWidth)
                    .opacity(1 - progress)
                    .allowsHitTesting(progress == 0)
                    if state.keepsFloatingSidebarOpen {
                        SpacesPane(state: state, workspace: workspace, current: workspace.root.path, canClose: true,
                                   active: progress == 1, spaces: spaces) { spaces = SpaceList.all }
                            .frame(width: openWidth)
                            .offset(x: -openWidth * (1 - progress))
                            .allowsHitTesting(progress == 1)
                    }
                }
                .frame(width: width, alignment: .leading)
                .clipped()
                .background(SpaceSwipe(state: state, width: openWidth, floating: true))
                // The card reaches up behind the traffic lights; the file tree stays below them.
                .background {
                    // Floats over the space, so it blurs the editor and preview beneath it.
                    SidebarMaterial(blending: .withinWindow)
                        .clipShape(Self.shape)
                        .overlay(Self.shape.stroke(Color.primary.opacity(0.12)))
                        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                        // The editor underneath would set its I-beam on every move.
                        .background(CursorArea())
                        .padding(.top, 8)
                        .ignoresSafeArea(edges: .top)
                }
                .padding([.leading, .bottom], 8)
                .onHover(perform: hover)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.25), value: state.floatingSidebar)
        .onAppear { spaces = SpaceList.all }
        .onChange(of: workspace.root) { spaces = SpaceList.all }
        .onChange(of: state.keepsFloatingSidebarOpen) { _, open in
            if open { show() } else if !hovering { scheduleHide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: SpaceList.didChange).receive(on: RunLoop.main)) { _ in
            spaces = SpaceList.all
        }
        .onDisappear { hideTask?.cancel() }
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside { show() } else { scheduleHide() }
    }

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        state.floatingSidebar = true
    }

    /// A short grace period, so brushing past its edge doesn't close it.
    private func scheduleHide() {
        hideTask?.cancel()
        guard !state.keepsFloatingSidebarOpen else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled, !state.keepsFloatingSidebarOpen else { return }
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
            Text("Select a space in the sidebar, create a new one, or import a folder.")
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
    let state: WindowState
    let title: String
    let subtitle: String

    func makeNSView(context: Context) -> NSView { WindowView(state: state) }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        window.title = title
        window.subtitle = subtitle
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }

    private final class WindowView: NSView {
        private let state: WindowState
        private var tracking: NSTrackingArea?
        private var stripObserver: (any NSObjectProtocol)?
        /// Title bar views hidden in full screen, shown again when it ends.
        private var hiddenInFullScreen: [NSView] = []

        init(state: WindowState) {
            self.state = state
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }
        // Live as long as the window, like this view.
        private var frameObserver: (any NSObjectProtocol)?
        private var fullScreenObservers: [any NSObjectProtocol] = []
        /// Full screen shows the buttons only with the menu bar, so they keep their colors there.
        private var isFullScreen = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            isFullScreen = window.styleMask.contains(.fullScreen)
            // An empty unified toolbar makes AppKit inset and center the window buttons itself, in full screen too.
            window.toolbar = NSToolbar(identifier: "SpaceTitleBar")
            window.toolbarStyle = .unified
            // The toolbar moves the buttons once it's laid out; SwiftUI builds the split view later too.
            DispatchQueue.main.async { [weak self] in
                self?.setUpTrafficLights()
                self?.disableEdgeReveal()
                if self?.isFullScreen == true { self?.enteredFullScreen() }
            }
            guard fullScreenObservers.isEmpty else { return }
            let center = NotificationCenter.default
            fullScreenObservers = [
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.isFullScreen = true
                        self.setHighlighted(false, animated: false)
                        self.disableEdgeReveal()
                    }
                },
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.enteredFullScreen() }
                },
                center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.leavingFullScreen() }
                },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isFullScreen = false
                        self?.setUpTrafficLights()
                    }
                },
            ]
        }

        /// The buttons live in a strip that slides down with the menu bar, keeping their inset; only its background goes.
        private func enteredFullScreen() {
            guard let titlebar = buttons.first?.superview, let strip = titlebar.window, strip !== window,
                  let container = titlebar.superview else { return }
            for view in container.subviews where view !== titlebar && !view.isHidden {
                view.isHidden = true
                hiddenInFullScreen.append(view)
            }
            state.fullScreenTop = strip.frame.height
            if let stripObserver { NotificationCenter.default.removeObserver(stripObserver) }
            stripObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: strip,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMenuBarInset() }
            }
            updateMenuBarInset()
        }

        private func leavingFullScreen() {
            if let stripObserver { NotificationCenter.default.removeObserver(stripObserver) }
            stripObserver = nil
            hiddenInFullScreen.forEach { $0.isHidden = false }
            hiddenInFullScreen = []
            state.fullScreenTop = 0
            state.menuBarInset = 0
        }

        /// Beside a notch the menu bar sits above the window; elsewhere it covers its top, so the window moves down.
        private func updateMenuBarInset() {
            guard let window, let strip = buttons.first?.window, strip !== window else { return }
            // The strip hangs below the menu bar: at the window's top beside a notch, lower with a menu bar over the window.
            let inset = max(window.frame.maxY - strip.frame.maxY, 0)
            guard inset != state.menuBarInset else { return }
            withAnimation(.smooth(duration: 0.2)) { state.menuBarInset = inset }
        }

        /// AppKit slides a hidden sidebar out at the screen's edge in full screen; the floating sidebar does that here.
        private func disableEdgeReveal() {
            guard let split = window?.contentView.flatMap(Self.splitView(in:)),
                  let controller = split.delegate as? NSSplitViewController else { return }
            let setter = NSSelectorFromString("setRevealsOnEdgeHoverInFullscreen:")
            for item in controller.splitViewItems where item.responds(to: setter) {
                item.setValue(false, forKey: "revealsOnEdgeHoverInFullscreen")
            }
        }

        private static func splitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for sub in view.subviews { if let found = splitView(in: sub) { return found } }
            return nil
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
                    let colored = on || isFullScreen
                    button.contentFilters = colored ? [] : [grey]
                    button.animator().alphaValue = colored ? 1 : 0.45
                }
            }
        }

    }
}
