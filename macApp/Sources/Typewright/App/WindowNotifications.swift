import SwiftUI

struct WindowNotification: Identifiable {
    enum Kind {
        case undo(FileNotice)
        case indexing(SpaceIndex.Progress?)
    }

    let id: String
    let title: String
    let kind: Kind

    @MainActor static func current(state: WindowState, workspace: Workspace?) -> [WindowNotification] {
        var notices: [WindowNotification] = []
        if let notice = state.deletionNotice {
            notices.append(.init(id: notice.id.uuidString, title: notice.text, kind: .undo(notice)))
        }
        if let workspace, workspace.isIndexing {
            let title: String
            switch workspace.indexProgress?.phase {
            case .loading: title = "Reading Index…"
            case .saving: title = "Saving Index…"
            default: title = workspace.isRebuildingIndex ? "Rebuilding Index…" : "Indexing…"
            }
            notices.append(.init(id: "indexing", title: title, kind: .indexing(workspace.indexProgress)))
        }
        return notices
    }
}

struct WindowNotifications: View {
    let state: WindowState
    let workspace: Workspace?
    var embedded = false
    @State private var showsIndexing = false

    var body: some View {
        let notices = WindowNotification.current(state: state, workspace: workspace).filter { notice in
            if case .indexing = notice.kind { return showsIndexing }
            return true
        }
        VStack(spacing: 0) {
            if !notices.isEmpty {
                VStack(spacing: 6) {
                    ForEach(notices) { notice in
                        WindowNotificationRow(notice: notice, state: state, workspace: workspace, embedded: embedded)
                    }
                }
                .frame(maxWidth: embedded ? .infinity : 480)
                .padding(embedded ? 8 : 16)
            }
        }
        .task(id: workspace?.isIndexing == true ? workspace?.indexStartedAt : nil) {
            guard workspace?.isIndexing == true, let started = workspace?.indexStartedAt else {
                showsIndexing = false
                return
            }
            showsIndexing = false
            do { try await Task.sleep(until: started.advanced(by: .milliseconds(500)), clock: .continuous) }
            catch { return }
            showsIndexing = true
        }
    }
}

private struct WindowNotificationRow: View {
    let notice: WindowNotification
    let state: WindowState
    let workspace: Workspace?
    let embedded: Bool
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if embedded, case .undo = notice.kind {
                Text(notice.title).lineLimit(2).truncationMode(.middle)
            }
            HStack(spacing: 8) {
                switch notice.kind {
                case .undo(let file):
                    if !embedded {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                        Text(notice.title).lineLimit(1).truncationMode(.middle)
                    }
                    Button("Undo") { state.undoDeletion() }
                    Spacer(minLength: 4)
                    if SpaceList.isInRepository(file.folder) {
                        Menu {
                            Button("Show Recently Deleted") {
                                RecentlyDeleted.show(in: file.folder)
                                state.dismissDeletion()
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                    }
                case .indexing(let progress):
                    Button { showsDetails.toggle() } label: {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                            Text(notice.title).lineLimit(1)
                            Spacer(minLength: 0)
                            if let progress, progress.items > 0 { Text(progress.items.formatted()).monospacedDigit() }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Background Tasks")
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .dismissWithPopups { showsDetails = false }
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Background Tasks").font(.headline)
                Text(notice.title).font(.subheadline)
                if let workspace { Text(workspace.name).foregroundStyle(.secondary) }
                ProgressView().progressViewStyle(.linear)
                if case .indexing(let progress) = notice.kind, let progress {
                    Text("\(progress.items.formatted()) items checked").monospacedDigit().foregroundStyle(.secondary)
                    if let path = progress.path {
                        Text(path).lineLimit(1).truncationMode(.middle).help(path).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .padding(16)
            .frame(width: 280, alignment: .leading)
        }
    }
}
