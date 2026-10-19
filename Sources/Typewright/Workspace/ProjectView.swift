import SwiftUI

struct ProjectView: View {
    let workspace: Workspace
    @State private var showIssues = false
    @State private var dragStart: Double?
    @State private var dragSplit: Double?
    @State private var dividerHovered = false
    @State private var sidebarEdgeHovered = false
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("ignoreLibraryWarnings") private var ignoreLibraryWarnings = true
    private var compilers: CompilerManager { .shared }

    /// The code's top fade; text starts below it but scrolls under it.
    static let fadeHeight: CGFloat = 34

    private var diagnostics: [Diagnostic] {
        workspace.diagnostics.filter { !(ignoreLibraryWarnings && $0.isFromPackage && $0.severity == .warning) }
    }

    private var fileDiagnostics: [Diagnostic] {
        guard let file = workspace.selectedFile else { return [] }
        return diagnostics.filter { !$0.isFromPackage && workspace.root.appendingPathComponent($0.path).standardizedFileURL == file }
    }

    var body: some View {
        // The sidebar can't be hidden: toggling and drag-collapsing have nothing to change.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 160, ideal: 210)
        } detail: {
            content
                .ignoresSafeArea(.container, edges: .top)
                .overlay(alignment: .leading) { sidebarEdge }
        }
        .toolbar(removing: .sidebarToggle)
        .background(HiddenTitleBar(title: workspace.selectedFile?.lastPathComponent ?? workspace.name,
                                   subtitle: workspace.name))
        .onAppear {
            workspace.scheduleCompile(delay: 0)
        }
        .onChange(of: compilers.activeBinary) { workspace.scheduleCompile(delay: 0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refreshFromDisk()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            workspace.flushSaves()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            workspace.flushSaves()
            workspace.persist()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            workspace.close()
        }
    }

    /// Below this width a released divider closes the preview.
    private static let closeWidth: CGFloat = 160

    private var content: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let editorW = showsPreview ? editorWidth(total) : total
            HStack(spacing: 0) {
                main
                    .frame(width: editorW)
                if showsPreview {
                    HStack(spacing: 0) {
                        Divider()
                        PreviewPane(workspace: workspace)
                            .opacity(total - editorW < Self.closeWidth ? 0.4 : 1)
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            // Above both panes so the grab area reaches into the PDF side too.
            .overlay(alignment: .leading) {
                if showsPreview {
                    dividerHandle(total).offset(x: editorW + 0.5 - Self.handleWidth / 2)
                }
            }
            .clipped()
            .animation(.smooth(duration: 0.3), value: showsPreview)
        }
    }

    /// Only Typst files get the split view; other files use the full width.
    private var showsPreview: Bool {
        workspace.previewFile != nil && (workspace.selectedKind == nil || workspace.selectedKind == .typst)
    }

    @ViewBuilder
    private var main: some View {
        Group {
            switch workspace.selectedKind {
            case .pdf?:
                PDFFileView(controller: workspace.filePreview)
            case .font?:
                if let url = workspace.selectedFile { FontPreview(url: url) }
            default:
                editor.overlay(alignment: .top) { topFade }
            }
        }
        .transition(.opacity)
    }

    private func editorWidth(_ total: CGFloat) -> CGFloat {
        let minEditor: CGFloat = 220, minPreview: CGFloat = 280
        // While dragging the preview may shrink past its minimum to show it will close.
        if let dragSplit { return min(max(total * dragSplit, minEditor), total) }
        guard total > minEditor + minPreview else { return total / 2 }
        return min(max(total * workspace.split, minEditor), total - minPreview)
    }

    /// Soft blur that fades out from the window edge, like the scroll edge effect above the file tree.
    private var topFade: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            // The editor color on top neutralizes the material's wallpaper tint.
            .overlay(Color(nsColor: .textBackgroundColor).opacity(0.7))
            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            .frame(height: Self.fadeHeight)
            .allowsHitTesting(false)
    }

    /// Highlights the sidebar's native resize edge like the preview divider.
    private var sidebarEdge: some View {
        DividerLine(active: sidebarEdgeHovered)
            .frame(width: 6, alignment: .leading)
            .background(HoverTracker { sidebarEdgeHovered = $0 })
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    private static let handleWidth: CGFloat = 14

    /// Invisible grab area centered on the divider; brightens the 1pt line while hovered or dragged.
    private func dividerHandle(_ total: CGFloat) -> some View {
        DividerLine(active: dividerHovered || dragStart != nil)
            .frame(width: Self.handleWidth)
            .contentShape(Rectangle())
            // The cursor is forced since the text and PDF views set their own.
            .background(CursorArea(cursor: .resizeLeftRight))
            .background(HoverTracker { dividerHovered = $0 })
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? Double(editorWidth(total) / max(total, 1))
                        dragStart = start
                        dragSplit = start + value.translation.width / max(total, 1)
                    }
                    .onEnded { _ in
                        let width = editorWidth(total)
                        dragStart = nil
                        dragSplit = nil
                        if total - width < Self.closeWidth {
                            workspace.setPreview(nil)
                        } else {
                            workspace.split = Double(width / max(total, 1))
                        }
                    }
            )
    }

    private var issuesButton: some View {
        Button { showIssues.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: issueSymbol)
                if !diagnostics.isEmpty { Text("\(diagnostics.count)").monospacedDigit() }
            }
            .font(.caption)
            .foregroundStyle(issueColor)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .glassEffect(.regular.interactive(), in: .capsule)
            .background(CursorArea())
        }
        .buttonStyle(.plain)
        .help("Errors and warnings")
        .padding(.bottom, 10)
        .padding(.trailing, 16)
        .popover(isPresented: $showIssues, arrowEdge: .bottom) {
            IssuesView(diagnostics: diagnostics) { d in
                showIssues = false
                workspace.reveal(d)
            }
        }
    }

    private var issueSymbol: String {
        if diagnostics.contains(where: { $0.severity == .error }) { return "xmark.circle.fill" }
        return diagnostics.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var issueColor: Color {
        if diagnostics.contains(where: { $0.severity == .error }) { return .red }
        return diagnostics.isEmpty ? .green : .yellow
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let file = workspace.selectedFile {
                CodeEditor(
                    documentID: workspace.revision,
                    text: workspace.text,
                    fontSize: fontSize,
                    highlights: workspace.selectedKind == .typst,
                    diagnostics: fileDiagnostics,
                    reveal: workspace.reveal,
                    state: workspace.editorState(for: file),
                    topInset: Self.fadeHeight - 10,
                    onChange: workspace.textDidChange,
                    onStateChange: workspace.editorStateDidChange
                )
                .overlay(alignment: .bottomTrailing) {
                    if workspace.previewFile != nil { issuesButton }
                }
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc")
            }
            Divider()
            HStack(spacing: 12) {
                Text("\(workspace.wordCount) words")
                Spacer()
                if let previewed = workspace.previewFile {
                    Label(previewed.lastPathComponent, systemImage: "eye").help("Previewed file")
                }
                Text(compilers.activeDescription)
                if let ms = workspace.lastDuration {
                    Text("\(Int(ms * 1000)) ms").monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
        }
    }
}

/// 1pt line that brightens over a divider while it's hovered or dragged.
private struct DividerLine: View {
    let active: Bool

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.4))
            .frame(width: 1)
            .opacity(active ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: active)
    }
}

/// Tracks hover with an AppKit tracking area; SwiftUI's hover can stick after drags over AppKit views.
private struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrackingView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Makes the title bar transparent with inset window buttons while a project is shown.
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
        private weak var attached: NSWindow?
        private var previous: (toolbar: NSToolbar?, style: NSWindow.ToolbarStyle)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                attached = window
                previous = (window.toolbar, window.toolbarStyle)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                // An empty unified toolbar makes AppKit inset and center the window buttons itself.
                window.toolbar = NSToolbar(identifier: "ProjectTitleBar")
                window.toolbarStyle = .unified
            } else if let attached {
                if let previous {
                    attached.toolbar = previous.toolbar
                    attached.toolbarStyle = previous.style
                }
                attached.titlebarAppearsTransparent = false
                attached.titleVisibility = .visible
                self.attached = nil
            }
        }
    }
}

struct IssuesView: View {
    let diagnostics: [Diagnostic]
    let onSelect: (Diagnostic) -> Void

    var body: some View {
        Group {
            if diagnostics.isEmpty {
                Label("No issues", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(diagnostics) { d in
                    Button { onSelect(d) } label: {
                        HStack(alignment: .top) {
                            Image(systemName: d.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(d.severity == .error ? .red : .yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.message)
                                Text("\(d.path):\(d.line):\(d.column)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 420, height: 260)
            }
        }
    }
}
