import AppKit
import CoreImage
import Observation
import SwiftUI

@MainActor @Observable
final class WindowState {
    var space: URL?
    /// Whether the space selector covers the file tree.
    var spacesOpen = false
    /// Live selector progress while a two-finger swipe drives it.
    var swipe: CGFloat?
    /// Whether the selector overlay is in the view tree; it stays a moment after closing to animate out.
    var selectorMounted = false
    /// Where the sidebar's content sits in the window; the selector overlay lines up with it.
    var sidebarFrame = CGRect(x: 0, y: 52, width: 220, height: 700)

    static let spacesAnimation = Animation.smooth(duration: 0.35)
    /// How far the open selector reaches past the sidebar, pushing the space aside.
    static let spacesExtra: CGFloat = 150

    init(space: URL?) { self.space = space }

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
        // The sidebar can't be hidden: toggling and drag-collapsing have nothing to change.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SpacesSidebar(state: state, workspace: workspace)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            Group {
                if let workspace {
                    SpaceView(workspace: workspace)
                        .id(ObjectIdentifier(workspace))
                        .transition(Self.enter)
                } else {
                    NoSpaceView()
                        .transition(Self.enter)
                }
            }
            // Shifted, not squeezed; the window's edge cuts off what moves past it.
            .offset(x: WindowState.spacesExtra * (workspace == nil ? 1 : state.spacesProgress))
            .overlay { dimming }
        }
        .toolbar(removing: .sidebarToggle)
        .overlay { SpacesOverlay(state: state, workspace: workspace) }
        .background(HiddenTitleBar(title: workspace?.selectedFile?.lastPathComponent ?? workspace?.name ?? "Typewright",
                                   subtitle: workspace?.name ?? ""))
        .onChange(of: state.space, initial: true) { _, url in
            let previous = workspace
            let next = url.map { Workspace(url: $0) }
            if let next { SpaceList.add(next.root) }
            // The selector slides away while the new space zooms in behind it.
            withAnimation(WindowState.spacesAnimation) {
                workspace = next
                state.spacesOpen = false
            }
            previous?.close()
            Opener.shared.saveSession()
        }
        .onDisappear { workspace?.close() }
    }

    /// Spaces grow into place from slightly behind the selector.
    private static let enter = AnyTransition.opacity.combined(with: .scale(scale: 0.96))

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
