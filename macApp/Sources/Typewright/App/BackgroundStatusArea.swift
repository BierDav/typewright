import SwiftUI

struct BackgroundStatusArea: View {
    let workspace: Workspace?
    @State private var showsTasks = false

    private var isIndexing: Bool { workspace?.isIndexing == true }
    private var progress: SpaceIndex.Progress? { workspace?.indexProgress }

    private var title: String {
        switch progress?.phase {
        case .loading: return "Reading Index…"
        case .saving: return "Saving Index…"
        default: return workspace?.isRebuildingIndex == true ? "Rebuilding Index…" : "Indexing…"
        }
    }

    var body: some View {
        // Only shown while something runs; idle it would just be noise.
        if isIndexing { status.transition(.opacity) }
    }

    private var status: some View {
        Button { showsTasks.toggle() } label: {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                Text(title).lineLimit(1)
                if let progress, progress.items > 0 {
                    Text(progress.items.formatted()).monospacedDigit().lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Background Tasks")
        .accessibilityLabel("Background Tasks: \(title)")
        .dismissWithPopups { showsTasks = false }
        .popover(isPresented: $showsTasks, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Background Tasks").font(.headline)
                Text(title).font(.subheadline)
                if let workspace { Text(workspace.name).foregroundStyle(.secondary) }
                ProgressView().progressViewStyle(.linear)
                if let progress {
                    Text("\(progress.items.formatted()) items checked")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let path = progress.path {
                        Text(path).lineLimit(1).truncationMode(.middle).help(path)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .padding(16)
            .frame(width: 280, alignment: .leading)
        }
    }
}
