import AppKit
import SwiftUI

/// Native toolbar-tab preferences window; SwiftUI's Settings scene rebuilds its toolbar on every switch.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        func tab(_ title: String, _ symbol: String, _ view: some View) -> NSTabViewItem {
            let host = NSHostingController(rootView: view.frame(width: 560, height: 520))
            host.sizingOptions = []
            host.title = title
            host.preferredContentSize = NSSize(width: 560, height: 520)
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(tab("General", "gearshape", GeneralSettings()))
        tabs.addTabViewItem(tab("Editor", "textformat", EditorSettings()))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct GeneralSettings: View {
    @AppStorage("ignoreLibraryWarnings") private var ignoreLibraryWarnings = true
    @Bindable private var compilers = CompilerManager.shared

    var body: some View {
        Form {
            Section("Diagnostics") {
                Toggle("Ignore library warnings", isOn: $ignoreLibraryWarnings)
                Text("Hide warnings from imported packages (e.g. @preview/…). Errors are always shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Use", selection: $compilers.selection) {
                    Text("Built-in (Typst \(BuiltinCompiler.version))").tag(CompilerManager.builtin)
                    Text("Newest installed").tag(CompilerManager.automatic)
                    if compilers.systemBinary != nil {
                        Text("System typst").tag(CompilerManager.system)
                    }
                    ForEach(compilers.installed, id: \.self) { Text("Typst \($0)").tag($0) }
                }
                ForEach(compilers.releases) { release in
                    CompilerRow(release: release, isLatest: release == compilers.latestRelease)
                }
                if let system = compilers.systemBinary {
                    LabeledContent("System", value: system.path)
                }
            } header: {
                HStack {
                    Text("Typst Compiler")
                    Spacer()
                    Button { Task { await compilers.refreshReleases() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh releases")
                }
            } footer: {
                if let error = compilers.lastError {
                    Text(error).foregroundStyle(.red)
                } else if compilers.active != .builtin {
                    Label("External compilers are slower: every keystroke is saved to disk and recompiled by a separate typst process.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Compilers are downloaded from github.com/typst/typst.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CompilerRow: View {
    let release: TypstRelease
    let isLatest: Bool
    private var compilers: CompilerManager { .shared }

    var body: some View {
        let installed = compilers.installed.contains(release.version)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(release.version).font(.headline)
                    if isLatest { badge("Latest", .blue) }
                    if installed { badge("Installed", .green) }
                }
                Text(isLatest ? "The current Typst compiler. Recommended." : "For documents that don't build on the latest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = compilers.downloads[release.version] {
                ProgressView(value: progress).frame(width: 100)
            } else if installed {
                Button("Remove", role: .destructive) { compilers.remove(release.version) }
            } else {
                Button { Task { await compilers.download(release) } } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct EditorSettings: View {
    @AppStorage("editorFontSize") private var fontSize = 14.0

    var body: some View {
        Form {
            Section("Font") {
                Stepper("Size: \(Int(fontSize)) pt", value: $fontSize, in: 9...32)
                Text("#let greeting = \"Hello, Typst\"")
                    .font(.system(size: fontSize, design: .monospaced))
            }
        }
        .formStyle(.grouped)
    }
}
