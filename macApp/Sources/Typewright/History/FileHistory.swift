import SwiftUI
import TypewrightCore

/// Routes history and conflicts from menus, the palette and the sidebar.
@MainActor
enum FileHistory {
    static let showHistory = Notification.Name("FileHistoryShowHistory")
    static let showConflict = Notification.Name("FileHistoryShowConflict")

    static func show(_ file: URL, in workspace: Workspace, selectedLines: Range<Int>? = nil) {
        var info: [String: Any] = ["file": file]
        info["lines"] = selectedLines
        NotificationCenter.default.post(name: showHistory, object: workspace, userInfo: info)
    }

    static func selectedLines(in workspace: Workspace) -> Range<Int>? {
        guard let tv = workspace.find.textView, tv.selectedRange().length > 0 else { return nil }
        let selection = tv.selectedRange()
        let start = textPosition(offset: Int32(clamping: selection.location), text: tv.string).line
        let end = textPosition(offset: Int32(clamping: NSMaxRange(selection) - 1), text: tv.string).line
        return Int(start)..<(Int(end) + 1)
    }

    static func resolve(_ file: URL, in workspace: Workspace) {
        NotificationCenter.default.post(name: showConflict, object: workspace, userInfo: ["file": file])
    }

    /// History is only kept for files in the space repository, outside git checkouts (jj skips those).
    static func isAvailable(for file: URL) -> Bool {
        let repository = SpaceRepository.shared
        return repository.contains(file) && SpaceFolders.gitRepository(containing: file, below: repository.root) == nil
    }

    /// Whole-file versions have previews instead of line diffs.
    static func isLFS(_ file: URL) -> Bool {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if Double(size) > SyncService.shared.lfsThresholdMB * 1_048_576 { return true }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8192))?.contains(0) ?? false
    }
}

extension SpaceRepository {
    /// Whether `url`, or for a folder anything inside it, has a conflict; links into the repository count too.
    func hasConflict(_ url: URL) -> Bool {
        guard !conflicted.isEmpty, let path = relativePath(of: url) else { return false }
        let base = root.path + "/"
        return conflicted.contains { file in
            let other = file.path.hasPrefix(base) ? String(file.path.dropFirst(base.count)) : file.path
            return other == path || other.hasPrefix(path + "/")
        }
    }
}

/// A file shown in one of the sheets.
private struct SheetFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Presents history in the palette and conflicts in a sheet for this workspace.
struct HistoryPresenter: ViewModifier {
    let workspace: Workspace
    @State private var conflict: SheetFile?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: FileHistory.showHistory)) { note in
                guard note.object as? Workspace === workspace, let url = note.userInfo?["file"] as? URL else { return }
                if let state = Opener.shared.keyState, state.workspace === workspace {
                    state.historyFile = url
                    state.historyLines = note.userInfo?["lines"] as? Range<Int>
                    state.overlay = .palette(page: "file.history")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: FileHistory.showConflict)) { note in
                guard note.object as? Workspace === workspace, let url = note.userInfo?["file"] as? URL else { return }
                conflict = SheetFile(url: url)
            }
            .task(id: workspace.root) { await SpaceRepository.shared.refreshConflicts() }
            .sheet(item: $conflict) { file in
                ConflictResolveView(file: file.url, workspace: workspace)
            }
    }
}
