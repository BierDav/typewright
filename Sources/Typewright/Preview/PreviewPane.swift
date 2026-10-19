import PDFKit
import SwiftUI

struct PDFViewHost: NSViewRepresentable {
    let controller: PreviewController
    func makeNSView(context: Context) -> PDFView { controller.view }
    func updateNSView(_ view: PDFView, context: Context) {}

    // PDFView's fitting size changes with the document; don't let it drive layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }
}

struct PreviewPane: View {
    let workspace: Workspace
    private var preview: PreviewController { workspace.preview }
    private var compilers: CompilerManager { .shared }

    var body: some View {
        ZStack {
            PDFViewHost(controller: preview)
            if compilers.activeBinary == nil {
                SetupCompilerView()
            } else if workspace.mainFile == nil {
                placeholder("No Typst file", "Create a .typ file to see a preview.")
            } else if workspace.document == nil {
                if workspace.isCompiling || workspace.diagnostics.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    placeholder("Compilation failed", "Fix the errors to see a preview.")
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // Use the inspector's title bar strip for the page too.
        .ignoresSafeArea(.container, edges: .top)
        // Overlay so the bar never drives the pane's size.
        .overlay(alignment: .bottom) { bar }
        .onChange(of: workspace.document) { _, doc in preview.show(doc) }
        .onAppear { preview.show(workspace.document) }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Button { preview.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Text("\(Int((preview.scale * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 38)
            Button { preview.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button { preview.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit to width")
            if preview.pageCount > 0 {
                Divider().frame(height: 16)
                Text("Page \(preview.page + 1) of \(preview.pageCount)").monospacedDigit()
            }
            Divider().frame(height: 16)
            if workspace.isCompiling {
                ProgressView().controlSize(.mini)
            }
            Button(action: exportPDF) { Image(systemName: "square.and.arrow.up") }
                .help("Export PDF")
                .disabled(workspace.document == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 14)
        .opacity(workspace.document == nil ? 0 : 1)
    }

    private func placeholder(_ title: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: "doc.text", description: Text(message))
            .background(.background)
    }

    private func exportPDF() {
        guard let doc = workspace.document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (workspace.mainFile?.deletingPathExtension().lastPathComponent ?? workspace.name) + ".pdf"
        panel.directoryURL = workspace.root
        if panel.runModal() == .OK, let url = panel.url { doc.write(to: url) }
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
        .background(.background)
        .task { if compilers.releases.isEmpty { await compilers.refreshReleases() } }
    }
}
