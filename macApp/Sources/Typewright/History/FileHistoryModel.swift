import Foundation
import Observation
import TypewrightCore

/// One row of a rendered line diff: a line, or a run of unchanged lines folded away.
enum FileDiffRow: Identifiable, Equatable {
    case line(Line)
    case fold(id: Int, count: Int)

    struct Line: Equatable {
        let id: Int
        let kind: DiffKind
        let text: String
        /// Line numbers in the old and new text; nil on the side the line doesn't exist.
        let old: Int?
        let new: Int?
    }

    var id: Int {
        switch self {
        case .line(let line): line.id
        case .fold(let id, _): -1 - id
        }
    }

    /// Diff rows from `old` to `new`; unchanged runs keep `context` lines around changes, the rest fold unless in `expanded`.
    static func rows(old: String, new: String, context: Int = 3, expanded: Set<Int> = []) -> [FileDiffRow] {
        rows(lineDiff(old: old, new: new), context: context, expanded: expanded)
    }

    static func rows(_ hunks: [DiffHunk], context: Int = 3, expanded: Set<Int> = []) -> [FileDiffRow] {
        var rows: [FileDiffRow] = []
        var (old, new, id) = (1, 1, 0)
        func add(_ kind: DiffKind, _ text: String) {
            let line = Line(id: id, kind: kind, text: text, old: kind == .added ? nil : old, new: kind == .removed ? nil : new)
            rows.append(.line(line))
            id += 1
            if kind != .added { old += 1 }
            if kind != .removed { new += 1 }
        }
        for (index, hunk) in hunks.enumerated() {
            guard hunk.kind == .same else {
                hunk.lines.forEach { add(hunk.kind, $0) }
                continue
            }
            // No context is needed before the first change or after the last one.
            let head = index == 0 ? 0 : context
            let tail = index == hunks.count - 1 ? 0 : context
            let hidden = hunk.lines.count - head - tail
            // Folding a line or two saves nothing.
            guard hidden > 1, !expanded.contains(index) else {
                hunk.lines.forEach { add(.same, $0) }
                continue
            }
            hunk.lines.prefix(head).forEach { add(.same, $0) }
            rows.append(.fold(id: index, count: hidden))
            id += hidden
            old += hidden
            new += hidden
            hunk.lines.suffix(tail).forEach { add(.same, $0) }
        }
        return rows
    }
}

/// Versions of one file, grouped by day.
struct FileVersionDay: Identifiable, Equatable {
    let day: Date
    let versions: [FileVersion]
    var id: Date { day }

    static func group(_ versions: [FileVersion], calendar: Calendar = .current) -> [FileVersionDay] {
        var days: [FileVersionDay] = []
        for version in versions {
            let day = calendar.startOfDay(for: version.time)
            if let last = days.last, last.day == day {
                days[days.count - 1] = FileVersionDay(day: day, versions: last.versions + [version])
            } else {
                days.append(FileVersionDay(day: day, versions: [version]))
            }
        }
        return days
    }
}

extension FileVersion {
    /// Repository paths the file had in each version (newest first), following renames back from `current`.
    static func paths(of versions: [FileVersion], current: String) -> [String] {
        var path = current
        return versions.map { version in
            defer { if version.kind == .renamed, let from = version.from { path = from } }
            return path
        }
    }
}

/// The history sheet's state: the versions, the selected one and its diff.
@MainActor @Observable
final class FileHistoryModel {
    enum Comparison: String, CaseIterable, Identifiable {
        case current, previous
        var id: String { rawValue }
        var title: String { self == .current ? "Compared to Now" : "Changes in Version" }
    }

    /// Where versions and their contents come from; the repository, or samples in previews.
    struct Source {
        var versions: () async -> [FileVersion]
        var content: (_ path: String, _ commit: String) async -> FileContent
    }

    let file: URL
    /// The file's repository path, which older versions may not share after renames.
    let path: String
    private(set) var versions: [FileVersion] = []
    private(set) var isLoading = true
    var selection: FileVersion.ID? { didSet { if selection != oldValue { loadSelection() } } }
    var comparison = Comparison.current { didSet { if comparison != oldValue { loadSelection() } } }
    /// The selected version's content and what it's compared against.
    private(set) var content: FileContent?
    private(set) var base: FileContent?
    private(set) var hunks: [DiffHunk]?
    var expandedFolds: Set<Int> = []

    @ObservationIgnored private let source: Source
    /// The file's text now, with unsaved edits.
    @ObservationIgnored private let currentText: () -> String?
    @ObservationIgnored private var paths: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(file: URL, path: String, source: Source, currentText: @escaping () -> String?) {
        self.file = file
        self.path = path
        self.source = source
        self.currentText = currentText
    }

    convenience init(file: URL, workspace: Workspace?) {
        let repository = SpaceRepository.shared
        let path = repository.relativePath(of: file) ?? file.lastPathComponent
        self.init(
            file: file, path: path,
            source: Source(
                versions: { await repository.history(of: file) },
                content: { path, commit in await repository.content(of: repository.url(of: path), at: commit) }
            ),
            currentText: { workspace?.bufferText(file) ?? (try? String(contentsOf: file, encoding: .utf8)) }
        )
    }

    var days: [FileVersionDay] { FileVersionDay.group(versions) }

    var selected: FileVersion? { versions.first { $0.id == selection } }

    /// Older versions of a renamed file live under their old path.
    func path(of version: FileVersion) -> String {
        versions.firstIndex(of: version).map { paths[$0] } ?? path
    }

    func load() async {
        isLoading = true
        versions = await source.versions()
        paths = FileVersion.paths(of: versions, current: path)
        isLoading = false
        if selection == nil || selected == nil { selection = versions.first?.id }
        else { loadSelection() }
    }

    /// The selection's line diff, when both sides are text (a missing side counts as empty).
    var rows: [FileDiffRow]? { hunks.map { FileDiffRow.rows($0, expanded: expandedFolds) } }

    /// Whether the selection is text, so it gets a diff rather than a preview.
    var isText: Bool { hunks != nil }

    private static func text(_ content: FileContent?) -> String? {
        switch content {
        case .text(let text)?: text
        case .missing?: ""
        default: nil
        }
    }

    private func loadSelection() {
        loadTask?.cancel()
        content = nil
        base = nil
        hunks = nil
        expandedFolds = []
        guard let version = selected, let index = versions.firstIndex(of: version) else {
            content = nil
            base = nil
            hunks = nil
            return
        }
        let comparison = comparison
        let older = versions.indices.contains(index + 1) && version.kind != .added ? index + 1 : nil
        let path = paths[index]
        loadTask = Task {
            let content = await source.content(path, version.commit)
            let base: FileContent
            if case .data = content {
                base = .missing
            } else if comparison == .current {
                base = currentText().map(FileContent.text) ?? .missing
            } else if let older {
                base = await source.content(paths[older], versions[older].commit)
            } else {
                base = .missing
            }
            var hunks: [DiffHunk]?
            if let version = Self.text(content), let other = Self.text(base) {
                // Compared to now the version is the old side; otherwise it's the new side of its own change.
                hunks = comparison == .current ? lineDiff(old: version, new: other) : lineDiff(old: other, new: version)
            }
            guard !Task.isCancelled else { return }
            self.content = content
            self.base = base
            self.hunks = hunks
        }
    }
}
