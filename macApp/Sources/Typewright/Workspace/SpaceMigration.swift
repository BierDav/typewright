import AppKit
import SwiftUI

/// The one-time question for spaces from before the repository: move them in, or leave them where they are.
enum SpaceMigration {
    enum Choice: String, CaseIterable, Identifiable {
        case replaceWithLink, keepOriginal, leaveAsIs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .replaceWithLink: "Import and Replace With Link"
            case .keepOriginal: "Import and Keep Original"
            case .leaveAsIs: "Leave As Is"
            }
        }
    }

    private static let key = "spaceMigrationAnswered"

    /// Git checkouts stay untracked inside the library anyway, so they default to staying where they are.
    static func defaultChoice(for url: URL) -> Choice {
        SpaceFolders.isGitRepository(url) ? .leaveAsIs : .replaceWithLink
    }

    /// Spaces outside the repository that haven't been asked about.
    static func pending(_ spaces: [URL], repository: URL, answered: Set<String>) -> [URL] {
        let base = repository.resolvingSymlinksInPath().standardizedFileURL.path
        return spaces.filter { url in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return !path.hasPrefix(base + "/") && !answered.contains(path)
        }
    }

    static func answered(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func markAnswered(_ url: URL, in defaults: UserDefaults = .standard) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        defaults.set(Array(answered(in: defaults).union([path])).sorted(), forKey: key)
    }

    /// Asks once, after the session is back, if any space still needs an answer.
    @MainActor static func askIfNeeded() {
        let spaces = pending(SpaceList.all, repository: SpaceList.repository, answered: answered())
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
            switch choice {
            case .leaveAsIs:
                markAnswered(url)
            case .replaceWithLink, .keepOriginal:
                if await Opener.shared.importSpace(url, replace: choice == .replaceWithLink, warnAboutGit: false) != nil { markAnswered(url) }
            }
        }
    }
}

/// Lists the old spaces with a choice each.
private struct MigrationSheet: View {
    let spaces: [URL]
    let done: ([URL: SpaceMigration.Choice]?) -> Void
    @State private var choices: [URL: SpaceMigration.Choice] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move Spaces Into Typewright?")
                .font(.headline)
            Text("Typewright now keeps spaces in its own folder, where every change is kept in a history. A link can take an imported folder's place, so you still find it where it was; the original goes to the Trash.")
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
                Button("Ask Later") { done(nil) }
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
