import SwiftUI

struct ProjectView: View {
    let workspace: Workspace
    let onClose: () -> Void
    @State private var showIssues = false
    @AppStorage("showPreview") private var showPreview = true
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("ignoreLibraryWarnings") private var ignoreLibraryWarnings = true
    private var compilers: CompilerManager { .shared }

    private var diagnostics: [Diagnostic] {
        workspace.diagnostics.filter { !(ignoreLibraryWarnings && $0.isFromPackage && $0.severity == .warning) }
    }

    private var fileDiagnostics: [Diagnostic] {
        guard let file = workspace.selectedFile else { return [] }
        return diagnostics.filter { !$0.isFromPackage && workspace.root.appendingPathComponent($0.path).standardizedFileURL == file }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 160, ideal: 210)
        } detail: {
            editor
        }
        .inspector(isPresented: $showPreview) {
            PreviewPane(workspace: workspace)
                .inspectorColumnWidth(min: 300, ideal: 560, max: 1400)
        }
        .navigationTitle(workspace.selectedFile?.lastPathComponent ?? workspace.name)
        .navigationSubtitle(workspace.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onClose) { Label("Home", systemImage: "house") }
                    .help("Close project and return home")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showPreview.toggle() } label: {
                    Label("Preview", systemImage: "sidebar.right")
                }
                .help(showPreview ? "Hide preview" : "Show preview")
            }
        }
        .onAppear {
            workspace.scheduleCompile(delay: 0)
        }
        .onChange(of: compilers.activeBinary) { workspace.scheduleCompile(delay: 0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refreshFromDisk()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            workspace.flushSaves()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            workspace.close()
        }
    }

    private var issuesButton: some View {
        Button { showIssues.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: issueSymbol)
                if !diagnostics.isEmpty { Text("\(diagnostics.count)").monospacedDigit() }
            }
            .foregroundStyle(issueColor)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Errors and warnings")
        .padding(12)
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
            if workspace.selectedFile != nil {
                CodeEditor(
                    documentID: workspace.revision,
                    text: workspace.text,
                    fontSize: fontSize,
                    diagnostics: fileDiagnostics,
                    reveal: workspace.reveal,
                    onChange: workspace.textDidChange
                )
                .overlay(alignment: .topTrailing) { issuesButton }
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc")
            }
            Divider()
            HStack(spacing: 12) {
                Text("\(workspace.wordCount) words")
                Spacer()
                if let main = workspace.mainFile {
                    Label(main.lastPathComponent, systemImage: "star.fill").help("Main file")
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
