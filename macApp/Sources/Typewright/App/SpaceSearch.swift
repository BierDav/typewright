import AppKit
import SwiftUI

/// One matching line.
struct SearchHit: Identifiable, Hashable {
    let id: Int
    let file: URL
    /// Zero-based line and UTF-16 column.
    let line: Int
    let column: Int
    let length: Int
    let text: String
}

/// The hits in one file of one space.
struct SearchFileResult: Identifiable {
    let file: URL
    let space: URL
    let hits: [SearchHit]
    var id: URL { file }
}

/// Full text search over space folders, off the main thread.
enum SpaceSearchEngine {
    static let hitLimit = 2_000
    private static let skippedFolders: Set<String> = ["node_modules", ".git", ".build", "target", "dist"]

    /// `overrides` holds unsaved buffers, which win over the disk.
    nonisolated static func search(_ regex: NSRegularExpression, in spaces: [URL], overrides: [URL: String]) -> [SearchFileResult] {
        var results: [SearchFileResult] = []
        var total = 0
        for space in spaces {
            let files = FileManager.default.enumerator(at: space, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = files?.nextObject() as? URL {
                if Task.isCancelled || total >= hitLimit { return results }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if skippedFolders.contains(url.lastPathComponent) { files?.skipDescendants() }
                    continue
                }
                guard (values?.fileSize ?? 0) < 2_000_000 else { continue }
                let file = url.standardizedFileURL
                guard FileKind(url: file).isEditable,
                      let text = overrides[file] ?? (try? String(contentsOf: file, encoding: .utf8)) else { continue }
                let hits = lines(matching: regex, in: text, file: file, firstID: total)
                guard !hits.isEmpty else { continue }
                total += hits.count
                results.append(SearchFileResult(file: file, space: space, hits: Array(hits.prefix(hitLimit))))
            }
        }
        return results
    }

    nonisolated static func lines(matching regex: NSRegularExpression, in text: String, file: URL, firstID: Int) -> [SearchHit] {
        let s = text as NSString
        var hits: [SearchHit] = []
        var line = 0
        var lineStart = 0
        var scanned = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: s.length)) { match, _, stop in
            guard let r = match?.range, r.length > 0 else { return }
            // Count the newlines up to this match, continuing from the last one.
            while scanned < r.location {
                if s.character(at: scanned) == 10 {
                    line += 1
                    lineStart = scanned + 1
                }
                scanned += 1
            }
            var lineRange = s.lineRange(for: NSRange(location: lineStart, length: 0))
            if lineRange.length > 0, s.character(at: NSMaxRange(lineRange) - 1) == 10 { lineRange.length -= 1 }
            hits.append(SearchHit(id: firstID + hits.count, file: file, line: line, column: r.location - lineStart,
                                  length: min(r.length, NSMaxRange(lineRange) - r.location), text: s.substring(with: lineRange)))
            if hits.count >= hitLimit { stop.pointee = true }
        }
        return hits
    }
}

/// Searches the contents of every file in the space, or in all spaces, with an editable preview of the selected hit
/// and replace across files.
struct SpaceSearchView: View {
    let state: WindowState
    let workspace: Workspace?
    let allSpaces: Bool
    let onClose: () -> Void
    @State private var query = ""
    @State private var replacement = ""
    @State private var showsReplace = false
    @State private var caseSensitive = false
    @State private var wholeWord = false
    @State private var regex = false
    @State private var results: [SearchFileResult] = []
    @State private var selection = 0
    @State private var isSearching = false
    @State private var error: String?
    /// Bumped when files change, so the results follow edits made in the preview.
    @State private var refresh = 0
    @State private var preview: SearchPreviewDocument?
    @State private var previewReveal: RevealRequest?
    @State private var previewFind: FindModel?
    @State private var clients: SearchLanguageClients?
    @State private var refreshTask: Task<Void, Never>?
    /// The last search's query, options and scope; reruns for edits keep the preview's cursor alone.
    @State private var lastSignature: String?
    @FocusState private var focus: Field?
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("glidingCursor") private var glidingCursor = true
    // Rebuilds the hidden shortcut buttons when the layout changes.
    @AppStorage(KeyLayout.defaultsKey) private var layoutID = BuiltinLayout.standard.rawValue
    @ObservedObject private var layouts = KeyLayoutStore.shared

    private enum Field { case search, replace }

    private static let width: CGFloat = 900

    private var hits: [SearchHit] { results.flatMap(\.hits) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                TextField(allSpaces ? "Search all spaces…" : "Search in \(workspace?.name ?? "space")…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focus, equals: .search)
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { onClose(); return .handled }
                if isSearching { ProgressView().controlSize(.small) }
                Toggle("Aa", isOn: $caseSensitive).help("Match case")
                Toggle("W", isOn: $wholeWord).help("Whole words")
                Toggle(".*", isOn: $regex).help("Regular expression")
                Toggle(isOn: $showsReplace.animation(.smooth(duration: 0.2))) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("Replace (⌥⌘F)")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .frame(height: 52)
            if showsReplace { replaceRow }
            Divider()
            list
            Divider()
            previewPane
            Divider()
            HStack {
                Text(summary).foregroundStyle(error == nil ? .secondary : Color.red)
                Spacer()
                Text("↑↓ to browse · ↩ opens in the editor · double-click opens too").foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 32)
        }
        .frame(width: Self.width)
        .onEscapeWhenUnfocused(onClose)
        .background {
            // The replace shortcut shows the replace field while the search has focus.
            Button("") {
                withAnimation(.smooth(duration: 0.2)) { showsReplace = true }
                focus = .replace
            }
            .keyboardShortcut(KeyLayout.current.shortcuts.replace)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .task {
            previewFind = previewFind ?? FindModel()
            clients = clients ?? SearchLanguageClients()
            // The editor holds on to first responder until it's released; then the field can take focus.
            NSApp.keyWindow?.makeFirstResponder(nil)
            try? await Task.sleep(for: .milliseconds(30))
            focus = .search
        }
        .task(id: SearchKey(query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex,
                            allSpaces: allSpaces, space: workspace?.root, refresh: refresh)) {
            await search()
        }
        .onDisappear {
            preview?.flush()
            clients?.stop()
            workspace?.reloadEditorIfNeeded()
        }
    }

    private struct SearchKey: Equatable {
        let query: String
        let caseSensitive: Bool
        let wholeWord: Bool
        let regex: Bool
        // Switching between the space and the overview reruns the search in the new scope.
        let allSpaces: Bool
        let space: URL?
        let refresh: Int
    }

    private var summary: String {
        if let error { return error }
        if query.isEmpty { return "Type to search file contents" }
        let count = hits.count
        let more = count >= SpaceSearchEngine.hitLimit ? "+" : ""
        return "\(count)\(more) results in \(results.count) files"
    }

    private var selectedHit: SearchHit? {
        let hits = hits
        return hits.indices.contains(selection) ? hits[selection] : nil
    }

    // MARK: Replace

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).frame(width: 18)
            TextField(regex ? "Replace with ($1 for groups)" : "Replace with", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .replace)
                .onSubmit(replaceCurrent)
            Button("Replace", action: replaceCurrent)
                .disabled(selectedHit == nil)
                .help("Replace the selected match")
            Button("Replace All", action: replaceAll)
                .disabled(hits.isEmpty)
                .help("Replace every match in every file listed")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    private var template: String {
        regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    /// Replaces the selected match in the preview's editor, so it can be undone there.
    private func replaceCurrent() {
        guard let hit = selectedHit, let expression = expression() else { return NSSound.beep() }
        showPreview(hit)
        guard let preview, preview.url == hit.file else { return }
        let text = preview.text
        let location = LanguageClient.offset(line: hit.line, character: hit.column, in: text as NSString)
        let range = NSRange(location: location, length: hit.length)
        guard let match = expression.firstMatch(in: text, range: range), match.range == range else { return NSSound.beep() }
        let new = expression.replacementString(for: match, in: text, offset: 0, template: template)
        if let apply = previewFind?.applyEdits {
            apply([TextEdit(range: range, newText: new)], "Replace")
        } else {
            preview.replaceText(TextEdit.apply([TextEdit(range: range, newText: new)], to: text))
        }
        refresh += 1
    }

    /// Replaces every match in every listed file after asking once.
    private func replaceAll() {
        guard let expression = expression(), !results.isEmpty else { return }
        let choice = PaletteDialog.choose("Replace \(hits.count) matches in \(results.count) files?",
            detail: "Files outside the open space are saved right away. This can't be undone in one step.",
            choices: [
                PaletteDialog.Choice(id: "replace", title: "Replace All", icon: "arrow.left.arrow.right"),
                PaletteDialog.Choice(id: "cancel", title: "Cancel", icon: "xmark"),
            ], over: state.window)
        guard choice == "replace" else { return }
        preview?.flush()
        for result in results {
            let inSpace = workspace?.isInSpace(result.file) == true
            guard let old = inSpace ? workspace?.bufferText(result.file) : try? String(contentsOf: result.file, encoding: .utf8)
            else { continue }
            let range = NSRange(location: 0, length: (old as NSString).length)
            let new = expression.stringByReplacingMatches(in: old, range: range, withTemplate: template)
            guard new != old else { continue }
            if inSpace { workspace?.updateBuffer(result.file, text: new) } else {
                try? new.write(to: result.file, atomically: true, encoding: .utf8)
            }
        }
        // The preview reloads with the replaced text.
        if let current = preview { openPreview(current.url, space: current.space) }
        refresh += 1
    }

    // MARK: List

    private var list: some View {
        let hits = hits
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        fileHeader(result)
                        ForEach(result.hits) { hit in
                            hitRow(hit, selected: hits.indices.contains(selection) && hits[selection].id == hit.id)
                                .id(hit.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open(hit) }
                                .onTapGesture {
                                    if let index = hits.firstIndex(where: { $0.id == hit.id }) {
                                        selection = index
                                        showPreview(hit)
                                    }
                                }
                        }
                    }
                    if results.isEmpty && !query.isEmpty && !isSearching && error == nil {
                        Text("No results").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
                    }
                }
                .padding(6)
                // The visible width, which shrinks by the scroller when scroll bars always show.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OverlayScrollers())
            }
            .frame(minHeight: 100, idealHeight: 220, maxHeight: 220)
            .onChange(of: selection) { _, index in
                if hits.indices.contains(index) { proxy.scrollTo(hits[index].id) }
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewPane: some View {
        if let preview, let find = previewFind {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: preview.kind == .typst ? "t.square" : MarkdownRenderer.isMarkdown(preview.url) ? "m.square" : "doc").foregroundStyle(.secondary)
                    Text(String(preview.url.path.dropFirst(preview.space.path.count + 1))).fontWeight(.medium)
                    if allSpaces { Text(preview.space.lastPathComponent).foregroundStyle(.tertiary) }
                    Spacer()
                    Button("Open in Editor") {
                        if let hit = selectedHit { open(hit) }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .frame(height: 28)
                CodeEditor(
                    documentID: preview.documentID,
                    text: preview.text,
                    fontSize: fontSize,
                    glidingCursor: glidingCursor,
                    find: find,
                    highlights: preview.kind == .typst,
                    markdown: MarkdownRenderer.isMarkdown(preview.url),
                    diagnostics: previewDiagnostics(preview),
                    reveal: previewReveal,
                    state: nil,
                    topInset: 0,
                    onChange: { text, live in
                        preview.textDidChange(text, live: live)
                        scheduleRefresh()
                    },
                    onStateChange: { _ in },
                    language: preview.kind == .typst ? preview : nil
                )
                .overlay(alignment: .topTrailing) {
                    if find.isVisible {
                        FindBar(find: find).padding(8)
                    }
                }
            }
            .frame(minHeight: 160, idealHeight: 360, maxHeight: 360)
        } else {
            Text(query.isEmpty ? "The selected result's file shows here, ready to edit." : "Select a result to preview its file.")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 160, idealHeight: 360, maxHeight: 360)
        }
    }

    private func previewDiagnostics(_ preview: SearchPreviewDocument) -> [Diagnostic] {
        guard let workspace, workspace.isInSpace(preview.url) else { return [] }
        return workspace.diagnostics.filter {
            !$0.isFromPackage && workspace.root.appendingPathComponent($0.path).standardizedFileURL == preview.url
        }
    }

    /// Loads the hit's file into the preview, or moves to the hit if it's already there.
    private func showPreview(_ hit: SearchHit?) {
        guard let hit else { return }
        let space = results.first { $0.file == hit.file }?.space ?? workspace?.root ?? hit.file.deletingLastPathComponent()
        if preview?.url != hit.file { openPreview(hit.file, space: space) }
        previewReveal = RevealRequest(line: hit.line + 1, column: hit.column + 1, length: hit.length, focus: false)
    }

    private func openPreview(_ url: URL, space: URL) {
        preview?.flush()
        let current = workspace.flatMap { $0.root.path == space.path ? $0 : nil }
        let document = SearchPreviewDocument(url: url, space: space, workspace: current,
                                             client: current == nil ? clients?.client(for: space) : nil)
        document.onOpen = { location in open(location, in: space) }
        document.onReveal = { location in
            previewReveal = RevealRequest(line: location.line + 1, column: location.character + 1,
                                          length: location.endCharacter - location.character)
        }
        preview = document
    }

    /// Edits in the preview move the results along once typing pauses.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            refresh += 1
        }
    }

    // MARK: Rows

    private func fileHeader(_ result: SearchFileResult) -> some View {
        let relative = String(result.file.path.dropFirst(result.space.path.count + 1))
        return HStack(spacing: 6) {
            Image(systemName: result.file.pathExtension == "typ" ? "t.square" : "doc")
                .foregroundStyle(.secondary)
            Text((relative as NSString).lastPathComponent).fontWeight(.medium)
            let dir = (relative as NSString).deletingLastPathComponent
            Text(allSpaces ? [result.space.lastPathComponent, dir].filter { !$0.isEmpty }.joined(separator: "/") : dir)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Text("\(result.hits.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func hitRow(_ hit: SearchHit, selected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(hit.line + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
            Text(Self.highlighted(hit))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(selected ? 0.1 : 0)))
    }

    /// The line with leading whitespace trimmed and the match marked; long lines are cut around the match.
    private static func highlighted(_ hit: SearchHit) -> AttributedString {
        let s = hit.text as NSString
        var start = 0
        while start < hit.column, let c = UnicodeScalar(s.character(at: start)), CharacterSet.whitespaces.contains(c) { start += 1 }
        if hit.column - start > 40 { start = hit.column - 30 }
        let before = s.substring(with: NSRange(location: start, length: hit.column - start))
        let match = s.substring(with: NSRange(location: hit.column, length: hit.length))
        let after = s.substring(from: hit.column + hit.length)
        var result = AttributedString((start > 0 && hit.column - start == 30 ? "…" : "") + before)
        var marked = AttributedString(match)
        marked.backgroundColor = Color.yellow.opacity(0.35)
        marked.inlinePresentationIntent = .stronglyEmphasized
        result += marked
        result += AttributedString(String(after.prefix(160)))
        return result
    }

    // MARK: Searching

    private func expression() -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    private func search() async {
        error = nil
        guard !query.isEmpty else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        guard let expression = expression() else {
            error = "Invalid regular expression"
            results = []
            return
        }
        let spaces = allSpaces ? SpaceList.all : workspace.map { [$0.root] } ?? []
        var overrides = workspace?.unsavedBuffers ?? [:]
        if let preview { overrides[preview.url] = preview.text }
        let previous = selectedHit
        isSearching = true
        let found = await Task.detached(priority: .userInitiated) {
            SpaceSearchEngine.search(expression, in: spaces, overrides: overrides)
        }.value
        isSearching = false
        guard !Task.isCancelled else { return }
        let signature = "\(query)|\(caseSensitive)|\(wholeWord)|\(regex)|\(allSpaces)"
        let isNewSearch = signature != lastSignature
        lastSignature = signature
        results = found
        // Stay on the same spot after edits; otherwise start at the top.
        let hits = found.flatMap(\.hits)
        selection = previous.flatMap { old in
            hits.firstIndex { $0.file == old.file && $0.line == old.line && $0.column == old.column }
                ?? hits.firstIndex { $0.file == old.file && $0.line >= old.line }
        } ?? 0
        if isNewSearch { showPreview(selectedHit) }
    }

    private func move(_ delta: Int) {
        let count = hits.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
        showPreview(selectedHit)
    }

    private func openSelected() {
        guard let hit = selectedHit else { return NSSound.beep() }
        open(hit)
    }

    private func open(_ hit: SearchHit) {
        let space = results.first { $0.file == hit.file }?.space
        open(SourceLocation(url: hit.file, line: hit.line, character: hit.column, length: hit.length), in: space)
    }

    /// Opens a location in the main editor, switching spaces if needed.
    private func open(_ location: SourceLocation, in space: URL?) {
        preview?.flush()
        onClose()
        if let workspace, workspace.isInSpace(location.url) {
            if state.spacesOpen { state.setSpacesOpen(false) }
            // Edits made in the preview show before jumping.
            workspace.reloadEditorIfNeeded()
            workspace.open(location)
        } else if let space {
            state.pendingReveal = location
            Opener.shared.open(space, in: state)
        }
    }
}
