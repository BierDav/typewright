import Observation
import SwiftUI

@MainActor @Observable
final class UndoPreviewSelection {
    var before: String?
    var after: String?
    var detail = "Select a change to preview it."
}

struct UndoChangePreview: View {
    let selection: UndoPreviewSelection
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selection.detail).font(.caption).foregroundStyle(.secondary).padding(12)
            if let before = selection.before, let after = selection.after {
                DiffView(rows: FileDiffRow.rows(old: before, new: after, expanded: expanded)) { expanded.insert($0) }
            } else {
                ContentUnavailableView("File Operation", systemImage: "folder",
                                       description: Text(selection.detail))
            }
        }
        .onChange(of: selection.after) { expanded = [] }
    }
}
