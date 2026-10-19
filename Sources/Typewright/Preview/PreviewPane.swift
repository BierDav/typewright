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
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

struct PreviewPane: View {
    let workspace: Workspace
    @State private var hovering = false
    private var preview: PreviewController { workspace.preview }
    private var htmlPreview: HTMLPreviewController { workspace.htmlPreview }
    private var compilers: CompilerManager { .shared }

    var body: some View {
        ZStack {
            switch workspace.renderMode {
            case .pdf: PDFViewHost(controller: preview)
            case .html: WebViewHost(controller: htmlPreview)
            }
            if compilers.activeBinary == nil {
                SetupCompilerView()
            } else if workspace.previewFile == nil {
                placeholder("No Typst file", "Create a .typ file to see a preview.")
            } else if !workspace.hasOutput {
                if workspace.isCompiling || (workspace.diagnostics.isEmpty && workspace.failureLog == nil) {
                    ProgressView().controlSize(.small)
                } else {
                    placeholder("Compilation failed", workspace.failureLog ?? "Fix the errors to see a preview.")
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(SidebarMaterial())
        // Overlay so the bar never drives the pane's size.
        .overlay(alignment: .bottom) {
            FloatingBar(isVisible: hovering && compilers.activeBinary != nil && workspace.previewFile != nil) { bar }
        }
        .onHover { hovering = $0 }
        .onChange(of: workspace.document) { _, doc in preview.show(doc) }
        .onChange(of: workspace.html) { _, html in htmlPreview.show(html, baseURL: baseURL) }
        .onAppear {
            preview.show(workspace.document)
            htmlPreview.show(workspace.html, baseURL: baseURL)
        }
    }

    private var baseURL: URL {
        workspace.previewFile?.deletingLastPathComponent() ?? workspace.root
    }

    @ViewBuilder
    private var bar: some View {
        switch workspace.renderMode {
        case .pdf: PDFZoomControls(controller: preview).disabled(workspace.document == nil)
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
                Group {
                    Toggle("A4 Pages", isOn: Bindable(htmlPreview).pages)
                    Toggle("Dark Mode", isOn: Bindable(htmlPreview).darkMode)
                }
                .disabled(workspace.renderMode != .html)
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
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error
            alert.runModal()
        }
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

struct HTMLZoomControls: View {
    let controller: HTMLPreviewController

    var body: some View {
        Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
            .help("Zoom out")
        Button { controller.resetZoom() } label: {
            Text("\(Int((controller.effectiveZoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 38)
        }
        .help("Actual size")
        Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
            .help("Zoom in")
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
            Text("Set up the Typst compiler").font(.title2.bold())
            Text("Typewright downloads the official Typst compiler to render your preview.")
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
