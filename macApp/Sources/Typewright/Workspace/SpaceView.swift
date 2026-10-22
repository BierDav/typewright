import SwiftUI

struct SpaceView: View {
    let workspace: Workspace
    @State private var showIssues = false
    @State private var dragStart: Double?
    @State private var dragSplit: Double?
    @State private var dividerHovered = false
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("glidingCursor") private var glidingCursor = true
    @AppStorage("wrapGuide") private var wrapGuide = false
    @AppStorage("wrapColumn") private var wrapColumn = 80
    @AppStorage("vimMode") private var vimBindings = false
    @AppStorage("concealMath") private var concealMath = true
    @AppStorage("autoClose") private var autoClose = true
    @State private var vimMode: String?
    @AppStorage("ignoreLibraryWarnings") private var ignoreLibraryWarnings = true
    @AppStorage(PreviewPosition.defaultsKey) private var previewPosition = PreviewPosition.trailing
    private var compilers: CompilerManager { .shared }

    /// The code's top fade; text starts below it but scrolls under it.
    static let fadeHeight: CGFloat = 34

    private var diagnostics: [Diagnostic] {
        workspace.diagnostics.filter { !(ignoreLibraryWarnings && $0.isFromPackage && $0.severity == .warning) }
    }

    private var fileDiagnostics: [Diagnostic] {
        guard let file = workspace.selectedFile else { return [] }
        let compiled = diagnostics.filter { !$0.isFromPackage && workspace.root.appendingPathComponent($0.path).standardizedFileURL == file }
        // The compile reports solveng's problems too once it's caught up; the same message on a line counts once.
        let seen = Set(compiled.map { "\($0.line):\($0.message)" })
        return compiled + workspace.solvengDiagnostics.filter { !seen.contains("\($0.line):\($0.message)") }
    }

    /// The detail column of a space window; the file tree lives in `SpacesSidebar`.
    var body: some View {
        content
            .ignoresSafeArea(.container, edges: .top)
            .onAppear {
                workspace.scheduleCompile(delay: 0)
            }
            .onChange(of: compilers.active) { workspace.scheduleCompile(delay: 0) }
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

    /// Below this size a released divider closes the preview.
    private var closeLength: CGFloat { vertical ? 120 : 160 }

    private var vertical: Bool { previewPosition != .trailing }

    /// The preview comes before the editor in the stack.
    private var leadingPreview: Bool { previewPosition == .top }

    private var content: some View {
        GeometryReader { geo in
            let total = vertical ? geo.size.height : geo.size.width
            let editorL = showsPreview ? editorLength(total) : total
            // One layout for both directions keeps the editor's identity when the preview moves.
            let stack = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            stack {
                if showsPreview && leadingPreview { previewSide(stack, total: total, faded: total - editorL < closeLength) }
                // Same position in the builder either way, so the editor survives the preview moving.
                main
                    .frame(width: vertical ? nil : editorL, height: vertical ? editorL : nil)
                if showsPreview && !leadingPreview { previewSide(stack, total: total, faded: total - editorL < closeLength) }
            }
            .clipped()
            .animation(.smooth(duration: 0.3), value: showsPreview)
            .animation(.smooth(duration: 0.3), value: previewPosition)
        }
    }

    /// The preview with its separator on the editor's side.
    private func previewSide(_ stack: AnyLayout, total: CGFloat, faded: Bool) -> some View {
        let separator = Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
        return stack {
            if !leadingPreview { separator }
            PreviewPane(workspace: workspace)
                .opacity(faded ? 0.4 : 1)
            if leadingPreview { separator }
        }
        // Part of the pane so it slides out with it; centered on the separator, reaching into the editor too.
        .overlay(alignment: leadingPreview ? .bottom : vertical ? .top : .leading) {
            let offset = (leadingPreview ? -1 : 1) * (0.5 - Self.handleWidth / 2)
            dividerHandle(total).offset(x: vertical ? 0 : offset, y: vertical ? offset : 0)
        }
        // Above the editor, which comes after it in the stack when the preview is on top.
        .zIndex(1)
        .transition(.move(edge: previewPosition == .top ? .top : previewPosition == .bottom ? .bottom : .trailing))
    }

    /// Only Typst and Markdown files get the split view; other files use the full width.
    private var showsPreview: Bool {
        guard workspace.previewFile != nil else { return false }
        guard let file = workspace.selectedFile, let kind = workspace.selectedKind else { return true }
        return kind == .typst || MarkdownRenderer.isMarkdown(file)
    }

    @ViewBuilder
    private var main: some View {
        Group {
            switch workspace.selectedKind {
            case .pdf?:
                PDFFileView(controller: workspace.filePreview)
            case .image?:
                ImageFileView(controller: workspace.imagePreview)
            case .document?:
                if let url = workspace.selectedFile { DocumentPreview(url: url).id(workspace.revision) }
            case .font?:
                if let url = workspace.selectedFile {
                    FontPreview(url: url, initialOffset: workspace.fontOffset(for: url), onScroll: workspace.fontDidScroll)
                }
            default:
                editor.overlay(alignment: .top) { topFade }
            }
        }
        .transition(.opacity)
    }

    private func editorLength(_ total: CGFloat) -> CGFloat {
        let minEditor: CGFloat = vertical ? 160 : 220, minPreview: CGFloat = vertical ? 160 : 280
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

    private static let handleWidth: CGFloat = 14

    /// Invisible grab area centered on the divider; brightens the 1pt line while hovered or dragged.
    private func dividerHandle(_ total: CGFloat) -> some View {
        DividerLine(active: dividerHovered || dragStart != nil, vertical: vertical)
            .frame(width: vertical ? nil : Self.handleWidth, height: vertical ? Self.handleWidth : nil)
            .contentShape(Rectangle())
            // The cursor is forced since the text and PDF views set their own.
            .background(CursorArea(cursor: vertical ? .resizeUpDown : .resizeLeftRight))
            .background(HoverTracker { dividerHovered = $0 })
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? Double(editorLength(total) / max(total, 1))
                        dragStart = start
                        let delta = (vertical ? value.translation.height : value.translation.width) / max(total, 1)
                        // The split is the editor's share, which shrinks as a top divider moves down.
                        dragSplit = start + (leadingPreview ? -delta : delta)
                    }
                    .onEnded { _ in
                        let length = editorLength(total)
                        dragStart = nil
                        dragSplit = nil
                        if total - length < closeLength {
                            workspace.setPreview(nil)
                        } else {
                            workspace.split = Double(length / max(total, 1))
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
        .dismissWithPopups { showIssues = false }
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

    /// How the comment shortcuts treat the shown file's language.
    private var commentSyntax: CommentSyntax? {
        if workspace.selectedKind == .typst { return .typst }
        if workspace.selectedFile.map(MarkdownRenderer.isMarkdown) == true { return .markdown }
        return nil
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let file = workspace.selectedFile {
                CodeEditor(
                    documentID: workspace.revision,
                    text: workspace.text,
                    fontSize: fontSize,
                    glidingCursor: glidingCursor,
                    wrapColumn: wrapGuide ? wrapColumn : 0,
                    vim: vimBindings,
                    concealsMath: concealMath,
                    autoClose: autoClose,
                    find: workspace.selectedKind?.isEditable == true ? workspace.find : nil,
                    highlights: workspace.selectedKind == .typst,
                    markdown: workspace.selectedFile.map(MarkdownRenderer.isMarkdown) ?? false,
                    comments: commentSyntax,
                    diagnostics: fileDiagnostics,
                    reveal: workspace.reveal,
                    state: workspace.editorState(for: file),
                    topInset: Self.fadeHeight - 10,
                    onChange: workspace.textDidChange,
                    onStateChange: workspace.editorStateDidChange,
                    language: workspace.selectedKind == .typst ? workspace : nil,
                    live: workspace.live,
                    solvengRevision: workspace.solvengRevision,
                    onVimModeChange: { vimMode = $0 },
                    onJump: workspace.recordJump(from:),
                    onPasteImage: workspace.pasteImage(from:)
                )
                .overlay(alignment: .bottomTrailing) {
                    if workspace.previewFile != nil { issuesButton }
                }
                .overlay(alignment: .topTrailing) {
                    if workspace.find.isVisible && workspace.selectedKind?.isEditable == true {
                        FindBar(find: workspace.find)
                            .padding(.top, Self.fadeHeight)
                            .padding(.trailing, 16)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.smooth(duration: 0.2), value: workspace.find.isVisible)
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc")
            }
            Divider()
            HStack(spacing: 12) {
                if let vimMode { Text(vimMode).monospaced() }
                caretStatus
                if !workspace.live.participants.isEmpty {
                    Label(workspace.live.participants.joined(separator: ", "), systemImage: "person.2.fill")
                        .help("Also editing this file")
                }
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

extension SpaceView {
    /// Words, caret position and selection size, like Xcode's and VS Code's status bars.
    @ViewBuilder fileprivate var caretStatus: some View {
        let caret = workspace.caret
        if caret.characters > 0 {
            Text("\(caret.words) of \(workspace.wordCount) words")
        } else {
            Text("\(workspace.wordCount) words")
        }
        if workspace.selectedKind?.isEditable == true {
            Group {
                if caret.characters == 0 {
                    Text("Ln \(caret.line), Col \(caret.column)")
                } else if caret.lines > 1 {
                    Text("Ln \(caret.line), Col \(caret.column) (\(caret.lines) lines, \(caret.characters) selected)")
                } else {
                    Text("Ln \(caret.line), Col \(caret.column) (\(caret.characters) selected)")
                }
            }
            .monospacedDigit()
            .help("Caret position; offset \(workspace.selection.location)")
        }
    }
}

/// 1pt line that brightens over a divider while it's hovered or dragged.
private struct DividerLine: View {
    let active: Bool
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.4))
            .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
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
                // Messages are selectable for copying, so only the icon and location jump to the issue.
                List(diagnostics) { d in
                    HStack(alignment: .top) {
                        Button { onSelect(d) } label: {
                            Image(systemName: d.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(d.severity == .error ? .red : .yellow)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.message)
                                .textSelection(.enabled)
                            Button { onSelect(d) } label: {
                                Text("\(d.path):\(d.line):\(d.column)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .pointerStyle(.link)
                            .help("Go to the issue")
                        }
                    }
                }
                .frame(width: 420, height: 260)
            }
        }
    }
}
