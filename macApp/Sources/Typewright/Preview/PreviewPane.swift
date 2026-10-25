import PDFKit
import SwiftUI
import WebKit

struct PDFViewHost: NSViewRepresentable {
    let controller: PreviewController
    func makeNSView(context: Context) -> PDFView { controller.view }
    func updateNSView(_ view: PDFView, context: Context) {}

    // PDFView's fitting size changes with the document; don't let it drive layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }
}

struct WebViewHost: NSViewRepresentable {
    let controller: HTMLPreviewController
    func makeNSView(context: Context) -> WKWebView { controller.view }
    func updateNSView(_ view: WKWebView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }
}

/// Behind-window blur, so the preview reads as a translucent sidebar.
struct SidebarMaterial: NSViewRepresentable {
    /// `.withinWindow` blurs the app's own content instead of the desktop.
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Where the preview sits next to the editor; a setting, switchable from the command palette.
enum PreviewPosition: String, CaseIterable, Identifiable {
    case trailing, top, bottom
    static let defaultsKey = "previewPosition"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .trailing: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }

    /// How the palette phrases moving the preview here.
    var place: String {
        switch self {
        case .trailing: "on the Right"
        case .top: "at the Top"
        case .bottom: "at the Bottom"
        }
    }

    var icon: String {
        switch self {
        case .trailing: "rectangle.righthalf.filled"
        case .top: "rectangle.tophalf.filled"
        case .bottom: "rectangle.bottomhalf.filled"
        }
    }
}

struct PreviewPane: View {
    let workspace: Workspace
    @State private var hovering = false
    @AppStorage(DarkModeWarning.defaultsKey) private var warnsAboutDarkMode = true
    @State private var darkModeWarningDismissed = false
    @Environment(\.colorScheme) private var colorScheme
    private var preview: PreviewController { workspace.preview }
    private var htmlPreview: HTMLPreviewController { workspace.htmlPreview }
    private var markdownPreview: HTMLPreviewController { workspace.markdownPreview }
    private var compilers: CompilerManager { .shared }
    private var markdown: Bool { workspace.previewIsMarkdown }

    var body: some View {
        ZStack {
            if markdown {
                WebViewHost(controller: markdownPreview)
            } else {
                switch workspace.renderMode {
                case .pdf, .svg: PDFViewHost(controller: preview)
                case .html: WebViewHost(controller: htmlPreview)
                }
            }
            if compilers.active == nil && !markdown {
                SetupCompilerView()
            } else if workspace.previewFile == nil {
                placeholder("No Typst file", "Create a .typ file to see a preview.")
            } else if !workspace.hasOutput {
                if workspace.isCompiling || (workspace.diagnostics.isEmpty && workspace.failureLog == nil) {
                    ProgressView().controlSize(.small)
                } else {
                    placeholder("Compilation failed", workspace.failureLog ?? firstError ?? "Fix the errors to see a preview.")
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(SidebarMaterial())
        // Overlay so the bar never drives the pane's size.
        .overlay(alignment: .bottom) {
            FloatingBar(isVisible: hovering && (compilers.active != nil || markdown) && workspace.previewFile != nil) { bar }
        }
        .overlay(alignment: .top) {
            if showsDarkModeWarning {
                // An existing import decides the version; only the show rule is missing.
                DarkModeWarning(letmeout: workspace.previewImportsLetmeout ? [""] : PackageLibrary.shared.newestSpecs(of: "letmeout"),
                                add: workspace.addLetmeout,
                                dismiss: { darkModeWarningDismissed = true }, suppress: { warnsAboutDarkMode = false })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsDarkModeWarning)
        // Dismissing lasts while this preview stays up; coming back to it warns again.
        .onChange(of: wouldWarnAboutDarkMode) { _, warns in if !warns { darkModeWarningDismissed = false } }
        .onChange(of: workspace.previewFile) { darkModeWarningDismissed = false }
        .onDisappear { darkModeWarningDismissed = false }
        .onHover { hovering = $0 }
        .onChange(of: workspace.document) { _, doc in preview.show(doc) }
        .onChange(of: workspace.html) { _, html in htmlPreview.show(html, baseURL: baseURL) }
        .onChange(of: workspace.markdownHTML) { _, html in markdownPreview.show(html, baseURL: baseURL) }
        .onAppear {
            preview.show(workspace.document)
            htmlPreview.show(workspace.html, baseURL: baseURL)
            markdownPreview.show(workspace.markdownHTML, baseURL: baseURL)
        }
    }

    /// Dark HTML preview of a document that doesn't style itself for dark mode.
    private var showsDarkModeWarning: Bool { wouldWarnAboutDarkMode && !darkModeWarningDismissed }

    private var wouldWarnAboutDarkMode: Bool {
        warnsAboutDarkMode && !markdown && workspace.renderMode == .html && htmlPreview.darkMode && colorScheme == .dark
            && workspace.html != nil && !htmlPreview.handlesColorScheme
    }

    private var firstError: String? {
        guard let d = workspace.diagnostics.first(where: { $0.severity == .error }) else { return nil }
        return "\(d.path):\(d.line): \(d.message)"
    }

    private var baseURL: URL {
        workspace.previewFile?.deletingLastPathComponent() ?? workspace.root
    }

    @ViewBuilder
    private var bar: some View {
        if markdown {
            HTMLZoomControls(controller: markdownPreview).disabled(workspace.markdownHTML == nil)
            Divider().frame(height: 16)
            Menu {
                Toggle("Dark Mode", isOn: Bindable(markdownPreview).darkMode)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        } else {
            typstBar
        }
    }

    @ViewBuilder
    private var typstBar: some View {
        switch workspace.renderMode {
        case .pdf, .svg: PDFZoomControls(controller: preview).disabled(workspace.document == nil)
        case .html: HTMLZoomControls(controller: htmlPreview).disabled(workspace.html == nil)
        }
        if workspace.isCompiling {
            ProgressView().controlSize(.mini)
        }
        Divider().frame(height: 16)
        Menu {
            Section("Render As") {
                Picker("Render As", selection: Bindable(workspace).renderMode) {
                    Text("PDF").tag(RenderMode.pdf)
                    Text("HTML").tag(RenderMode.html)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Toggle("Dark Mode", isOn: Bindable(htmlPreview).darkMode).disabled(workspace.renderMode != .html)
            }
            Divider()
            Button("Export PDF…", action: exportPDF)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private func placeholder(_ title: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: "doc.text", description: Text(message))
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (workspace.previewFile?.deletingPathExtension().lastPathComponent ?? workspace.name) + ".pdf"
        panel.directoryURL = workspace.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let error = await workspace.exportPDF(to: url) else { return }
            PaletteDialog.message("Export failed", detail: error)
        }
    }
}

/// Explains that dark mode only switches the page's color scheme, which typst's own HTML doesn't follow.
struct DarkModeWarning: View {
    static let defaultsKey = "htmlDarkModeWarning"
    /// The newest letmeout of each namespace that has one, like `@preview/letmeout:0.2.0`; `[""]` when it's imported already.
    let letmeout: [String]
    let add: (String) -> Void
    let dismiss: () -> Void
    let suppress: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This document ignores dark mode", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .symbolRenderingMode(.multicolor)
            Text("Typewright only sets the browser's color scheme. Typst's HTML output doesn't adapt to it, so it's recommended to use a package that handles dark mode, like letmeout.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Don't Show Again", action: suppress)
                Spacer()
                Button("Dismiss", action: dismiss)
                if letmeout.count > 1 {
                    // The same package in several namespaces; which one is the user's call.
                    Menu("Add letmeout") {
                        ForEach(letmeout, id: \.self) { spec in Button(spec) { add(spec) } }
                    }
                    .fixedSize()
                } else if let spec = letmeout.first {
                    Button("Add letmeout") { add(spec) }
                        .help(spec.isEmpty ? "Adds #show: letmeout below its import" : spec)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 440)
        .background(StillArea())
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(12)
    }
}

/// Takes clicks between controls, so they don't drag the window.
private struct StillArea: NSViewRepresentable {
    final class Still: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {}
    }

    func makeNSView(context: Context) -> Still { Still() }
    func updateNSView(_ view: Still, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Still, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Glass capsule pinned to the bottom of a preview, shown while the pointer is inside.
struct FloatingBar<Content: View>: View {
    let isVisible: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .fixedSize()
            .glassEffect(.regular, in: .capsule)
            .background(CursorArea())
            .padding(.bottom, 24)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .animation(.easeOut(duration: 0.2), value: isVisible)
    }
}

struct PDFZoomControls: View {
    let controller: PreviewController

    var body: some View {
        let percent = "\(Int((controller.scale * 100).rounded()))%"
        Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
            .help("Zoom out")
        Button { controller.setAutoScales(true) } label: {
            Text(controller.autoScales ? "Auto (\(percent))" : percent).monospacedDigit().frame(minWidth: 38)
        }
        .help(controller.autoScales ? "Fitting to width" : "Fit to width")
        Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
            .help("Zoom in")
        if controller.pageCount > 0 {
            Divider().frame(height: 16)
            Text("Page \(controller.page + 1) of \(controller.pageCount)").monospacedDigit()
        }
    }
}

/// HTML uses browser zoom; Markdown shares its text size across previews.
struct HTMLZoomControls: View {
    let controller: HTMLPreviewController

    var body: some View {
        if !controller.isMarkdown {
            let percent = "\(Int((controller.zoomScale * 100).rounded()))%"
            Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button { controller.resetZoom() } label: {
                Text(percent).monospacedDigit().frame(minWidth: 38)
            }
            .help("Actual size")
            Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
        } else {
            Button { controller.zoomOut() } label: { Image(systemName: "textformat.size.smaller") }
                .help("Smaller text")
            Button { controller.resetZoom() } label: {
                Text("\(Int(controller.textSize.rounded())) px").monospacedDigit().frame(minWidth: 38)
            }
            .help("Standard text size")
            Button { controller.zoomIn() } label: { Image(systemName: "textformat.size.larger") }
                .help("Larger text")
        }
    }
}

/// Full-width viewer for a PDF file in the project.
struct PDFFileView: View {
    let controller: PreviewController
    @State private var hovering = false

    var body: some View {
        PDFViewHost(controller: controller)
            .background(SidebarMaterial())
            .overlay(alignment: .bottom) {
                FloatingBar(isVisible: hovering) { PDFZoomControls(controller: controller) }
            }
            .onHover { hovering = $0 }
    }
}

struct SetupCompilerView: View {
    private var compilers: CompilerManager { .shared }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Selected Typst compiler is missing").font(.title2.bold())
            Text("Download it, or switch back to the faster built-in compiler.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let latest = compilers.latestRelease {
                if let progress = compilers.downloads[latest.version] {
                    ProgressView(value: progress).frame(width: 220)
                } else {
                    Button("Download Typst \(latest.version)") {
                        Task { await compilers.download(latest) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Use built-in Typst \(BuiltinCompiler.version)") { compilers.selection = CompilerManager.builtin }
                .buttonStyle(.link)
            if let system = compilers.systemBinary {
                Button("Use installed typst (\(system.path))") { compilers.selection = CompilerManager.system }
                    .buttonStyle(.link)
            }
            if let error = compilers.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { if compilers.releases.isEmpty { await compilers.refreshReleases() } }
    }
}
