import AppKit
import SwiftUI

/// Imports external spaces when requested from the command palette.
enum SpaceMigration {
    enum Choice: String, CaseIterable, Identifiable {
        case replaceWithLink, keepOriginal, deleteOriginal, leaveAsIs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .replaceWithLink: "Import and Replace With Link"
            case .keepOriginal: "Import and Keep Original"
            case .deleteOriginal: "Import and Delete Original"
            case .leaveAsIs: "Leave As Is"
            }
        }

        var mode: SpaceFolders.ImportMode? {
            switch self {
            case .replaceWithLink: .replaceWithLink
            case .keepOriginal: .keepOriginal
            case .deleteOriginal: .deleteOriginal
            case .leaveAsIs: nil
            }
        }
    }

    /// Git checkouts stay untracked inside the library anyway, so they default to staying where they are.
    static func defaultChoice(for url: URL) -> Choice {
        SpaceFolders.isGitRepository(url) ? .leaveAsIs : .replaceWithLink
    }

    static func externalSpaces(_ spaces: [URL], repository: URL) -> [URL] {
        let base = repository.resolvingSymlinksInPath().standardizedFileURL.path
        return spaces.filter { url in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return path != base && !path.hasPrefix(base + "/")
        }
    }

    @MainActor static func show() {
        let spaces = externalSpaces(SpaceList.all, repository: SpaceList.repository)
        guard !spaces.isEmpty, SpaceRepository.shared.isOpen else { return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: EmptyView()))
        window.styleMask = [.titled]
        let host = NSHostingController(rootView: MigrationSheet(spaces: spaces) { choices in
            if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
            guard let choices else { return }
            Task { await apply(choices, order: spaces) }
        })
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        if let parent = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// One after another, so each import's alert (if any) stands alone.
    @MainActor private static func apply(_ choices: [URL: Choice], order: [URL]) async {
        for url in order {
            guard let choice = choices[url] else { continue }
            if let mode = choice.mode {
                await Opener.shared.importSpace(url, mode: mode)
            }
        }
    }
}

/// Each external space can be imported or left where it is.
private struct MigrationSheet: View {
    let spaces: [URL]
    let done: ([URL: SpaceMigration.Choice]?) -> Void
    @State private var choices: [URL: SpaceMigration.Choice] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import External Spaces")
                .font(.headline)
            Text("Import external spaces into the library to keep a history of their changes and enable device sync. You can keep the original, replace it with a link, or move it to the Trash.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach(spaces, id: \.self) { url in
                    Picker(selection: binding(url)) {
                        ForEach(SpaceMigration.Choice.allCases) { Text($0.title).tag($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if SpaceFolders.isGitRepository(url) {
                                Label(SpaceFolders.gitRepositoryNote, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 120, maxHeight: 360)
            HStack {
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { done(spaces.reduce(into: [:]) { $0[$1] = choices[$1] ?? SpaceMigration.defaultChoice(for: $1) }) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func binding(_ url: URL) -> Binding<SpaceMigration.Choice> {
        Binding { choices[url] ?? SpaceMigration.defaultChoice(for: url) } set: { choices[url] = $0 }
    }
}
