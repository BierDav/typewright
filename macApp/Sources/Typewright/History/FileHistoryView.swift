import PDFKit
import SwiftUI
import TypewrightCore
import UniformTypeIdentifiers

/// A file's local history: versions by day on the left, the selected one's diff or preview on the right.
struct FileHistoryView: View {
    @State private var model: FileHistoryModel
    /// The space the file belongs to; nil in previews.
    let workspace: Workspace?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRestore = false
    @State private var failure: String?

    init(model: FileHistoryModel, workspace: Workspace?) {
        _model = State(initialValue: model)
        self.workspace = workspace
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                versionList.frame(width: 260)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 960, minHeight: 520, idealHeight: 640)
        .task { await model.load() }
        .confirmationDialog("Restore “\(model.file.lastPathComponent)” to this version?", isPresented: $confirmingRestore) {
            Button("Restore") { Task { await restore() } }
        } message: {
            Text("The current content stays in the history, so you can go back to it.")
        }
        .alert("Couldn't Restore the File", isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: - Versions

    @ViewBuilder
    private var versionList: some View {
        if model.isLoading && model.versions.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.versions.isEmpty {
            ContentUnavailableView {
                Label("No History", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(emptyDescription)
            }
        } else {
            List(selection: $model.selection) {
                ForEach(model.days) { day in
                    Section(Self.dayTitle(day.day)) {
                        ForEach(day.versions) { version in
                            VersionRow(version: version, path: model.path(of: version), current: model.path)
                                .tag(version.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var emptyDescription: String {
        if FileHistory.isLFS(model.file) {
            return "Large and binary files have no history; Typewright syncs them whole."
        }
        if FileHistory.isAvailable(for: model.file) || workspace == nil {
            return "Versions appear here a few seconds after the file changes."
        }
        if SpaceFolders.gitRepository(containing: model.file, below: SpaceRepository.shared.root) != nil {
            return SpaceFolders.gitRepositoryNote
        }
        return "History is kept for spaces in Typewright's library."
    }

    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.day().month(.wide).year())
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let version = model.selected {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.time.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Text(model.path(of: version)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Picker("Compare", selection: $model.comparison) {
                        ForEach(FileHistoryModel.Comparison.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                content(version)
            }
        } else if !model.versions.isEmpty {
            ContentUnavailableView("No Version Selected", systemImage: "clock")
        }
    }

    @ViewBuilder
    private func content(_ version: FileVersion) -> some View {
        if let rows = model.rows {
            if rows.allSatisfy({ if case .line(let line) = $0 { line.kind == .same } else { true } }) {
                // Fills the pane so the header stays at the top.
                ContentUnavailableView(model.comparison == .current ? "Same as Now" : "No Changes",
                                       systemImage: "equal.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffView(rows: rows) { model.expandedFolds.insert($0) }
            }
        } else if let content = model.content {
            VersionPreview(content: content, name: model.file.lastPathComponent)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private var footer: some View {
        HStack {
            Button("Copy", systemImage: "doc.on.doc", action: copy)
                .disabled(!hasContent)
                .help("Copy this version's content")
            Button("Open Read-Only", systemImage: "eye", action: openReadOnly)
                .disabled(!hasContent)
                .help("Open this version in its default app, without changing the file")
            Spacer()
            Button("Restore…") { confirmingRestore = true }
                .disabled(!hasContent || workspace == nil)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var hasContent: Bool {
        guard let content = model.content else { return false }
        return content != .missing
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch model.content {
        case .text(let text)?: pasteboard.setString(text, forType: .string)
        case .data(let data)?:
            if let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            } else if let url = try? temporaryCopy() {
                pasteboard.writeObjects([url as NSURL])
            }
        default: break
        }
    }

    private func openReadOnly() {
        guard let url = try? temporaryCopy() else { return }
        NSWorkspace.shared.open(url)
    }

    /// The selected version as a locked file in the temporary folder.
    private func temporaryCopy() throws -> URL {
        guard let version = model.selected else { throw CocoaError(.fileNoSuchFile) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("History/\(version.commit.prefix(12))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent((model.path(of: version) as NSString).lastPathComponent)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        switch model.content {
        case .text(let text)?: try Data(text.utf8).write(to: url)
        case .data(let data)?: try data.write(to: url)
        default: throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        return url
    }

    private func restore() async {
        guard let version = model.selected, let workspace else { return }
        // Unsaved edits would otherwise be written over the restored file.
        workspace.flushSaves()
        let repository = SpaceRepository.shared
        var restored: Bool
        if model.path(of: version) == model.path {
            restored = await repository.restore(model.file, from: version.commit)
        } else {
            // The version lived under an older name; its content goes to the file's current place.
            restored = false
            switch model.content {
            case .text(let text)?: restored = (try? Data(text.utf8).write(to: model.file, options: .atomic)) != nil
            case .data(let data)?: restored = (try? data.write(to: model.file, options: .atomic)) != nil
            default: break
            }
            if restored {
                await repository.commit("Restore \(model.path)")
                workspace.refreshFromDisk()
            }
        }
        guard restored else {
            failure = "The version couldn't be written back. Try again in a moment."
            return
        }
        // `restore` reloads editors through `didCommit`.
        dismiss()
    }
}

/// One version in the list: time, description and the size of the change.
private struct VersionRow: View {
    let version: FileVersion
    let path: String
    let current: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(version.time.formatted(date: .omitted, time: .shortened))
                Spacer()
                if version.added > 0 { Text("+\(version.added)").foregroundStyle(.green) }
                if version.removed > 0 { Text("−\(version.removed)").foregroundStyle(.red) }
            }
            .monospacedDigit()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch version.kind {
        case .added: return "Created"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed from \((version.from.map { ($0 as NSString).lastPathComponent }) ?? "another name")"
        case .modified:
            if path != current { return "As \((path as NSString).lastPathComponent)" }
            let text = version.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text == "Edit" ? "Edited" : text
        }
    }
}

/// Unified line diff with line numbers in two gutters and folded unchanged runs.
struct DiffView: View {
    let rows: [FileDiffRow]
    let onExpand: (Int) -> Void

    private var digits: Int {
        let last = rows.reversed().lazy.compactMap { row -> Int? in
            if case .line(let line) = row { return max(line.old ?? 0, line.new ?? 0) }
            return nil
        }.first ?? 1
        return max(2, String(last).count)
    }

    var body: some View {
        let width = CGFloat(digits) * 7.5 + 10
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    switch row {
                    case .line(let line): LineRow(line: line, gutter: width)
                    case .fold(let id, let count):
                        Button { onExpand(id) } label: {
                            Label("\(count) unchanged lines", systemImage: "arrow.up.and.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, width * 2 + 12)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.08))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show the unchanged lines")
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private struct LineRow: View {
        let line: FileDiffRow.Line
        let gutter: CGFloat

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(line.old)
                number(line.new)
                Text(marker).foregroundStyle(tint ?? .secondary).frame(width: 14)
                Text(line.text.isEmpty ? " " : line.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.vertical, 1)
            .padding(.trailing, 8)
            .background(tint.map { $0.opacity(0.14) } ?? .clear)
        }

        private func number(_ n: Int?) -> some View {
            Text(n.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .trailing)
                .padding(.trailing, 4)
        }

        private var marker: String {
            switch line.kind {
            case .added: "+"
            case .removed: "−"
            case .same: ""
            }
        }

        private var tint: Color? {
            switch line.kind {
            case .added: .green
            case .removed: .red
            case .same: nil
            }
        }
    }
}

/// An image, PDF or other binary version, which gets no diff.
private struct VersionPreview: View {
    let content: FileContent
    let name: String

    var body: some View {
        switch content {
        case .data(let data):
            let type = UTType(filenameExtension: (name as NSString).pathExtension)
            if type?.conforms(to: .pdf) == true, let document = PDFDocument(data: data) {
                PDFVersionView(document: document)
            } else if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Preview", systemImage: "doc",
                                       description: Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .missing:
            ContentUnavailableView("Not in This Version", systemImage: "doc.badge.ellipsis")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text):
            ScrollView { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding() }
        }
    }
}

private struct PDFVersionView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        view.documentView?.enclosingScrollView?.scrollerStyle = .overlay
        view.documentView?.enclosingScrollView?.autohidesScrollers = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        view.documentView?.enclosingScrollView?.scrollerStyle = .overlay
        view.documentView?.enclosingScrollView?.autohidesScrollers = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }
}

// MARK: - Previews

extension FileHistoryModel {
    /// Three edits of a short Typst file, for previews and tests.
    static func sample() -> FileHistoryModel {
        let texts = [
            "= Thesis\n\nIntro.\n",
            "= Thesis\n\nIntro, longer.\n\n== Method\n",
            "= My Thesis\n\nIntro, longer.\n\n== Method\nWe measure.\n",
        ]
        let now = Date.now.timeIntervalSince1970
        let json = """
        [{"commit": "c3", "time": \(now - 600), "description": "Edit", "kind": "modified", "added": 2, "removed": 1},
         {"commit": "c2", "time": \(now - 3_600), "description": "Edit", "kind": "modified", "added": 3, "removed": 1},
         {"commit": "c1", "time": \(now - 90_000), "description": "Edit", "kind": "added", "added": 3, "removed": 0}]
        """
        let versions = (try? JSONDecoder().decode([FileVersion].self, from: Data(json.utf8))) ?? []
        return FileHistoryModel(
            file: URL(fileURLWithPath: "/tmp/Thesis/main.typ"), path: "Thesis/main.typ",
            source: .init(versions: { versions }, content: { _, commit in
                .text(texts[(Int(commit.dropFirst()) ?? 1) - 1])
            }),
            currentText: { texts[2] + "\nMore.\n" }
        )
    }
}

#Preview("History") {
    FileHistoryView(model: .sample(), workspace: nil)
}

#Preview("Diff") {
    DiffView(rows: FileDiffRow.rows(
        old: (1...20).map { "line \($0)" }.joined(separator: "\n"),
        new: (1...20).map { $0 == 10 ? "changed" : "line \($0)" }.joined(separator: "\n")
    )) { _ in }
    .frame(width: 500, height: 400)
}
