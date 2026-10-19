import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class WindowState {
    var project: URL?
    init(project: URL?) { self.project = project }
}

/// One window that shows Home or a project, switching in place.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let state: WindowState

    init(project: URL?) {
        state = WindowState(project: project)
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
        Group {
            if let workspace {
                ProjectView(workspace: workspace)
            } else {
                HomeView()
            }
        }
        .onChange(of: state.project, initial: true) { _, url in
            workspace?.close()
            workspace = url.map { Workspace(url: $0) }
            if let url { Recents.add(url) }
            Opener.shared.saveSession()
        }
        .onDisappear { workspace?.close() }
    }
}
