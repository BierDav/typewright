import AppKit

/// A file opened in the full text search's preview, editable with the same language features as the main editor.
/// Files of the open space go through its buffers; files of other spaces are saved to disk directly.
@MainActor
final class SearchPreviewDocument: EditorLanguage {
    let url: URL
    let space: URL
    let documentID: Int
    private(set) var text: String
    private weak var workspace: Workspace?
    private let ownClient: LanguageClient?
    private var saveTask: Task<Void, Never>?
    private var unsaved = false
    /// Opens a location in the main editor, closing the search.
    var onOpen: (SourceLocation) -> Void = { _ in }
    /// Shows a location of this file in the preview itself.
    var onReveal: (SourceLocation) -> Void = { _ in }

    // Far from the main editor's revisions, so the two never share a document ID.
    private static var nextID = 1_000_000

    init(url: URL, space: URL, workspace: Workspace?, client: LanguageClient?) {
        self.url = url
        self.space = space
        self.workspace = workspace
        ownClient = workspace == nil ? client : nil
        text = workspace?.bufferText(url) ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        Self.nextID += 1
        documentID = Self.nextID
        if kind == .typst { self.client?.open(url, text: text) }
    }

    var kind: FileKind { FileKind(url: url) }

    private var client: LanguageClient? { workspace?.sharedLanguageClient ?? ownClient }

    func textDidChange(_ new: String, live: Bool) {
        text = new
        if let workspace { return workspace.updateBuffer(url, text: new, live: live) }
        if kind == .typst { client?.change(url, text: new) }
        unsaved = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes edits to files outside the open space.
    func flush() {
        saveTask?.cancel()
        guard unsaved else { return }
        unsaved = false
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Replaces the whole text from outside the editor, e.g. a global replace.
    func replaceText(_ new: String) {
        textDidChange(new, live: false)
    }

    // MARK: - EditorLanguage

    func completions(at offset: Int) async -> [CompletionItem] {
        await client?.completions(in: url, text: text as NSString, at: offset) ?? []
    }

    func hover(at offset: Int) async -> (markdown: String, range: NSRange?)? {
        await client?.hover(in: url, text: text as NSString, at: offset)
    }

    func occurrences(at offset: Int) async -> [NSRange] {
        await client?.occurrences(in: url, text: text as NSString, at: offset) ?? []
    }

    func quickFixes(for diagnostic: Diagnostic) -> [QuickFix] {
        QuickFixes.fixes(for: diagnostic, root: space)
    }

    func formattingEdits() async -> [TextEdit] {
        let source = text
        let edits = await client?.format(url, text: source as NSString) ?? []
        return SolvengSupport.formattingEdits(source, context: "", preceding: edits)
    }

    func renameTarget(at offset: Int) async -> (range: NSRange, name: String)? {
        await client?.renameTarget(in: url, text: text as NSString, at: offset)
    }

    func rename(at offset: Int, to name: String) async -> [TextEdit] {
        guard let client else { return [] }
        let source = text as NSString
        var shown: [TextEdit] = []
        for (file, json) in await client.rename(in: url, text: source, at: offset, to: name) {
            if file == url {
                shown = LanguageClient.edits(json, in: source)
            } else if let workspace {
                workspace.applyEdits(json, to: file)
            } else if file.path.hasPrefix(space.path + "/"), let old = try? String(contentsOf: file, encoding: .utf8) {
                let new = TextEdit.apply(LanguageClient.edits(json, in: old as NSString), to: old)
                try? new.write(to: file, atomically: true, encoding: .utf8)
                client.change(file, text: new)
            }
        }
        return shown
    }

    func goToDefinition(at offset: Int) async -> [SymbolUsage] {
        let source = text as NSString
        guard let client, let target = await client.definition(in: url, text: source, at: offset) else {
            NSSound.beep()
            return []
        }
        let range = target.range(in: source)
        if target.url == url, NSLocationInRange(offset, range) || NSMaxRange(range) == offset {
            let usages = await client.references(in: url, text: source, at: offset)
                .filter { !($0.url == url && $0.range(in: source) == range) }
                .compactMap(usage)
            if usages.isEmpty { NSSound.beep() }
            return usages
        }
        guard target.url.path.hasPrefix(space.path + "/") else {
            NSSound.beep()
            return []
        }
        open(target)
        return []
    }

    func open(_ location: SourceLocation) {
        if location.url == url { return onReveal(location) }
        flush()
        onOpen(location)
    }

    private func usage(_ location: SourceLocation) -> SymbolUsage? {
        guard location.url.path.hasPrefix(space.path + "/") else { return nil }
        let source = location.url == url ? text
            : workspace?.bufferText(location.url) ?? (try? String(contentsOf: location.url, encoding: .utf8)) ?? ""
        let line = Workspace.lineText(location.line, in: source as NSString)
        return SymbolUsage(location: location, file: String(location.url.path.dropFirst(space.path.count + 1)),
                           preview: line.trimmingCharacters(in: .whitespaces))
    }
}

/// tinymist processes for spaces other than the open one, shared by the search's previews and stopped with it.
@MainActor
final class SearchLanguageClients {
    private var clients: [URL: LanguageClient] = [:]

    func client(for space: URL) -> LanguageClient? {
        if let client = clients[space], client.isRunning { return client }
        guard let binary = LanguageServerManager.shared.binary else { return nil }
        let client = LanguageClient(binary: binary, root: space, fontPaths: FontLibrary.shared.directories(for: space).map(\.path))
        clients[space] = client
        return client
    }

    func stop() {
        clients.values.forEach { $0.stop() }
        clients.removeAll()
    }
}
