import Foundation
import Observation
import TypewrightCore

/// Finds or downloads tinymist, the Typst language server.
@MainActor @Observable
final class LanguageServerManager {
    static let shared = LanguageServerManager()

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "languageServerEnabled")
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            if isEnabled { Task { await setUp() } }
        }
    }
    private(set) var isDownloading = false
    private(set) var lastError: String?
    private(set) var downloadedVersion: String?
    let systemBinary: URL?

    private let directory = URL.applicationSupportDirectory.appending(path: "Typewright/tinymist", directoryHint: .isDirectory)
    var downloadedBinary: URL { directory.appending(path: "tinymist") }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: "languageServerEnabled") as? Bool ?? true
        systemBinary = ["/opt/homebrew/bin/tinymist", "/usr/local/bin/tinymist"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        downloadedVersion = try? String(contentsOf: directory.appending(path: "version"), encoding: .utf8)
    }

    /// The binary to run; a system install wins over the downloaded copy.
    var binary: URL? {
        guard isEnabled else { return nil }
        if let systemBinary { return systemBinary }
        return FileManager.default.isExecutableFile(atPath: downloadedBinary.path) ? downloadedBinary : nil
    }

    /// Downloads tinymist on first launch, like the typst compiler.
    func setUp() async {
        guard isEnabled, systemBinary == nil, !FileManager.default.isExecutableFile(atPath: downloadedBinary.path) else { return }
        await download()
    }

    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        defer { isDownloading = false }
        lastError = nil
        #if arch(arm64)
        let asset = "tinymist-darwin-arm64"
        #else
        let asset = "tinymist-darwin-x64"
        #endif
        let url = URL(string: "https://github.com/Myriad-Dreamin/tinymist/releases/latest/download/\(asset)")!
        do {
            let (location, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: downloadedBinary)
            try fm.moveItem(at: location, to: downloadedBinary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloadedBinary.path)
            let binary = downloadedBinary
            if let version = await Task.detached(operation: { Self.version(of: binary) }).value {
                try? version.write(to: directory.appending(path: "version"), atomically: true, encoding: .utf8)
                downloadedVersion = version
            }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        } catch {
            lastError = "Could not download tinymist: \(error.localizedDescription)"
        }
    }

    /// Reads "Build Git Describe:  v0.15.10" from `tinymist --version`.
    private nonisolated static func version(of binary: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = binary
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n")
            .first { $0.hasPrefix("Build Git Describe:") }
            .map { $0.dropFirst("Build Git Describe:".count).trimmingCharacters(in: CharacterSet(charactersIn: " v")) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        downloadedVersion = nil
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Posted when the binary appears, goes away or is switched off.
    static let didChange = Notification.Name("LanguageServerDidChange")
}

/// A replacement of a UTF-16 range, from formatting or renaming.
struct TextEdit: Equatable {
    let range: NSRange
    let newText: String

    /// Applies edits that don't overlap; later ones first so earlier ranges stay valid.
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        applyTextEdits(edits: edits.map {
            TypewrightCore.TextEdit(range: TextRange(location: Int32($0.range.location), length: Int32($0.range.length)),
                                    newText: $0.newText)
        }, text: text)
    }
}

/// A range in some file, in LSP's zero-based lines and UTF-16 characters.
struct SourceLocation: Equatable {
    let url: URL
    let line: Int
    let character: Int
    let endLine: Int
    let endCharacter: Int

    init(url: URL, line: Int, character: Int, length: Int = 0) {
        self.url = url.standardizedFileURL
        self.line = line
        self.character = character
        endLine = line
        endCharacter = character + length
    }

    init?(uri: String, range: [String: Any]) {
        guard let url = URL(string: uri), let start = range["start"] as? [String: Any] else { return nil }
        let end = range["end"] as? [String: Any] ?? start
        self.url = url.standardizedFileURL
        line = start["line"] as? Int ?? 0
        character = start["character"] as? Int ?? 0
        endLine = end["line"] as? Int ?? line
        endCharacter = end["character"] as? Int ?? character
    }

    func range(in text: NSString) -> NSRange {
        let a = LanguageClient.offset(line: line, character: character, in: text)
        let b = LanguageClient.offset(line: endLine, character: endCharacter, in: text)
        return NSRange(location: a, length: max(b - a, 0))
    }
}

/// One completion proposal, already reduced to what the editor needs.
struct CompletionItem: Equatable {
    enum Kind { case function, variable, constant, keyword, snippet, file, font, field, other }

    let label: String
    let detail: String?
    let kind: Kind
    /// Text matched against what was typed.
    let filterText: String
    let sortText: String
    /// Snippet syntax (`${1:x}`) when `isSnippet`.
    let newText: String
    let isSnippet: Bool
    /// UTF-16 range the item replaces, relative to the document; nil means the word before the cursor.
    let range: NSRange?
    /// Markdown docs, shown beside the list on F1.
    var documentation: String? = nil
    /// The server's item, sent back to resolve docs it left out.
    var raw: Data? = nil
}

/// A stdio JSON-RPC client for one tinymist process serving one space.
@MainActor
final class LanguageClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Any?, Never>] = [:]
    /// Messages wait here until the server answered `initialize`.
    private var outbox: [Data] = []
    private var ready = false
    private var versions: [URL: Int] = [:]
    private(set) var isRunning = false
    private var resolvesCompletions = false

    init?(binary: URL, root: URL, fontPaths: [String]) {
        process.executableURL = binary
        process.arguments = ["lsp"]
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminated() }
        }
        let reader = FrameReader()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let messages = reader.feed(data)
            guard !messages.isEmpty else { return }
            Task { @MainActor in messages.forEach { self?.handle($0) } }
        }
        do { try process.run() } catch { return nil }
        isRunning = true

        let options: [String: Any] = ["exportPdf": "never", "fontPaths": fontPaths, "formatterMode": "typstyle"]
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": root.absoluteString,
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
            "initializationOptions": options,
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "textDocument": [
                    "completion": ["completionItem": ["snippetSupport": true, "labelDetailsSupport": true,
                                                       "documentationFormat": ["markdown", "plaintext"],
                                                       "resolveSupport": ["properties": ["documentation", "detail"]]]],
                    "definition": ["linkSupport": true],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "signatureHelp": ["signatureInformation": ["documentationFormat": ["markdown", "plaintext"]]],
                ],
            ],
        ]
        Task {
            let result = await request("initialize", params, force: true) as? [String: Any]
            let capabilities = result?["capabilities"] as? [String: Any]
            resolvesCompletions = (capabilities?["completionProvider"] as? [String: Any])?["resolveProvider"] as? Bool ?? false
            ready = true
            write(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
            outbox.forEach(send)
            outbox.removeAll()
        }
    }

    func stop() {
        guard isRunning else { return }
        Task {
            _ = await request("shutdown", nil)
            notify("exit", nil)
            // A server that hangs on shutdown still goes.
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Documents

    func open(_ url: URL, text: String) {
        guard versions[url] == nil else { return change(url, text: text) }
        versions[url] = 1
        notify("textDocument/didOpen", ["textDocument": [
            "uri": url.absoluteString, "languageId": "typst", "version": 1, "text": text,
        ]])
    }

    /// Sends the whole buffer; Typst files are small and this can't drift out of sync.
    func change(_ url: URL, text: String) {
        guard let version = versions[url] else { return open(url, text: text) }
        versions[url] = version + 1
        notify("textDocument/didChange", [
            "textDocument": ["uri": url.absoluteString, "version": version + 1],
            "contentChanges": [["text": text]],
        ])
    }

    func forget(_ url: URL) {
        guard versions.removeValue(forKey: url) != nil else { return }
        notify("textDocument/didClose", ["textDocument": ["uri": url.absoluteString]])
    }

    // MARK: - Features

    func completions(in url: URL, text: NSString, at offset: Int) async -> [CompletionItem] {
        let result = await request("textDocument/completion", Self.position(url, text, offset))
        let list = (result as? [String: Any])?["items"] ?? result
        guard let items = list as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let edit = item["textEdit"] as? [String: Any]
            let range = (edit?["range"] as? [String: Any]).flatMap { Self.range($0, in: text) }
            let newText = edit?["newText"] as? String ?? item["insertText"] as? String ?? label
            return CompletionItem(
                label: label,
                detail: (item["labelDetails"] as? [String: Any])?["description"] as? String ?? item["detail"] as? String,
                // Font families come back as quoted string values.
                kind: label.hasPrefix("\"") && (item["detail"] as? String)?.contains("variant") == true
                    ? .font : Self.kind(item["kind"] as? Int),
                filterText: item["filterText"] as? String ?? label,
                sortText: item["sortText"] as? String ?? label,
                newText: newText,
                isSnippet: item["insertTextFormat"] as? Int == 2,
                range: range,
                documentation: Self.markdown(item["documentation"]),
                raw: try? JSONSerialization.data(withJSONObject: item))
        }
    }

    /// Docs of a completion item, asking the server when the list came without them.
    func documentation(of item: CompletionItem) async -> String? {
        if let docs = item.documentation { return docs }
        guard resolvesCompletions, let raw = item.raw, let object = try? JSONSerialization.jsonObject(with: raw) else { return nil }
        let resolved = await request("completionItem/resolve", object) as? [String: Any]
        return Self.markdown(resolved?["documentation"])
    }

    /// Docs of a completion as its hover shows them, for servers that leave them out of the list and resolve, like tinymist.
    /// Hovers the item's name in a hidden copy of the file with the name filled in, so imports still count.
    func hoverDocumentation(of item: CompletionItem, in url: URL, text: NSString) async -> String? {
        guard var range = item.range, NSMaxRange(range) <= text.length, !item.label.isEmpty else { return nil }
        // The list stays open while typing, so the range may end before the rest of the word typed since.
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        while NSMaxRange(range) < text.length, let scalar = UnicodeScalar(text.character(at: NSMaxRange(range))),
              word.contains(scalar) { range.length += 1 }
        let filled = text.replacingCharacters(in: range, with: item.label) as NSString
        // Beside the file, so relative imports resolve the same; it never reaches the disk.
        let scratch = url.deletingLastPathComponent().appendingPathComponent(".typewright-docs-\(url.lastPathComponent)")
        open(scratch, text: filled as String)
        let offset = range.location + (item.label as NSString).length - 1
        return await hover(in: scratch, text: filled, at: offset)?.markdown
    }

    /// A string or MarkupContent; nil when empty.
    private static func markdown(_ value: Any?) -> String? {
        let text = value as? String ?? (value as? [String: Any])?["value"] as? String
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    /// Where the symbol or path at `offset` is defined, as a file and a zero-based line and column.
    func definition(in url: URL, text: NSString, at offset: Int) async -> SourceLocation? {
        let result = await request("textDocument/definition", Self.position(url, text, offset))
        let first = (result as? [[String: Any]])?.first ?? result as? [String: Any]
        guard let first, let uri = (first["targetUri"] ?? first["uri"]) as? String,
              let range = (first["targetSelectionRange"] ?? first["range"]) as? [String: Any] else { return nil }
        return SourceLocation(uri: uri, range: range)
    }

    /// Every use of the symbol at `offset` across the space.
    func references(in url: URL, text: NSString, at offset: Int) async -> [SourceLocation] {
        var params = Self.position(url, text, offset)
        params["context"] = ["includeDeclaration": false]
        let result = await request("textDocument/references", params) as? [[String: Any]] ?? []
        return result.compactMap { location in
            guard let uri = location["uri"] as? String, let range = location["range"] as? [String: Any] else { return nil }
            return SourceLocation(uri: uri, range: range)
        }
    }

    /// Signature and docs of what's at `offset`, as Markdown, and the range they describe.
    func hover(in url: URL, text: NSString, at offset: Int) async -> (markdown: String, range: NSRange?)? {
        guard let result = await request("textDocument/hover", Self.position(url, text, offset)) as? [String: Any] else { return nil }
        func plain(_ value: Any?) -> String? {
            if let s = value as? String { return s }
            guard let d = value as? [String: Any], let v = d["value"] as? String else { return nil }
            // Old-style MarkedStrings carry a language and are code.
            if let language = d["language"] as? String { return "```\(language)\n\(v)\n```" }
            return v
        }
        let contents = result["contents"]
        let markdown = (contents as? [Any]).map { $0.compactMap(plain).joined(separator: "\n\n") } ?? plain(contents)
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (markdown, (result["range"] as? [String: Any]).flatMap { Self.range($0, in: text) })
    }

    /// Docs of the named argument at `offset`, like `unit` in `solve(x, unit: "min")`, which hover doesn't cover.
    func parameterDocs(in url: URL, text: NSString, at offset: Int) async -> (markdown: String, range: NSRange?)? {
        guard let argument = namedArgument(text: text as String, offset: Int32(clamping: offset)),
              let result = await request("textDocument/signatureHelp", Self.position(url, text, offset)) as? [String: Any],
              let signatures = result["signatures"] as? [[String: Any]], !signatures.isEmpty else { return nil }
        let signature = signatures[min(result["activeSignature"] as? Int ?? 0, signatures.count - 1)]
        let label = signature["label"] as? String ?? ""
        let parameters = signature["parameters"] as? [[String: Any]] ?? []
        guard let parameter = parameters.first(where: { ($0["label"] as? String)?.trimmingCharacters(in: [":"]) == argument.name })
        else { return nil }
        let docs = parameter["documentation"].flatMap { ($0 as? String) ?? ($0 as? [String: Any])?["value"] as? String } ?? ""
        let type = parameterType(signature: label, name: argument.name).map { ": \($0)" } ?? ""
        let range = NSRange(location: Int(argument.range.location), length: Int(argument.range.length))
        return ("```typc\n\(argument.name)\(type)\n```" + (docs.isEmpty ? "" : "\n\n" + docs), range)
    }

    /// Every use of the symbol at `offset` in the same file, its definition included.
    func occurrences(in url: URL, text: NSString, at offset: Int) async -> [NSRange] {
        var params = Self.position(url, text, offset)
        params["context"] = ["includeDeclaration": true]
        let result = await request("textDocument/references", params) as? [[String: Any]] ?? []
        return result.compactMap { location in
            guard let uri = location["uri"] as? String, URL(string: uri)?.standardizedFileURL == url.standardizedFileURL,
                  let range = location["range"] as? [String: Any] else { return nil }
            return Self.range(range, in: text)
        }
    }

    /// Whole-file formatting with typstyle.
    func format(_ url: URL, text: NSString) async -> [TextEdit] {
        let params: [String: Any] = ["textDocument": ["uri": url.absoluteString],
                                     "options": ["tabSize": 2, "insertSpaces": true]]
        let result = await request("textDocument/formatting", params) as? [[String: Any]] ?? []
        return Self.edits(result, in: text)
    }

    /// The symbol at `offset` that can be renamed, and its current name.
    func renameTarget(in url: URL, text: NSString, at offset: Int) async -> (range: NSRange, name: String)? {
        guard let result = await request("textDocument/prepareRename", Self.position(url, text, offset)) as? [String: Any] else {
            return nil
        }
        // Either a bare range or a range with a placeholder.
        let rangeJSON = result["range"] as? [String: Any] ?? result
        guard let range = Self.range(rangeJSON, in: text) else { return nil }
        return (range, result["placeholder"] as? String ?? text.substring(with: range))
    }

    /// Rename edits per file, still as LSP JSON since other files' texts are needed to place them.
    func rename(in url: URL, text: NSString, at offset: Int, to name: String) async -> [URL: [[String: Any]]] {
        var params = Self.position(url, text, offset)
        params["newName"] = name
        guard let result = await request("textDocument/rename", params) as? [String: Any] else { return [:] }
        var edits: [URL: [[String: Any]]] = [:]
        for (uri, list) in result["changes"] as? [String: [[String: Any]]] ?? [:] {
            if let file = URL(string: uri) { edits[file.standardizedFileURL, default: []] += list }
        }
        for change in result["documentChanges"] as? [[String: Any]] ?? [] {
            guard let doc = change["textDocument"] as? [String: Any], let uri = doc["uri"] as? String, let file = URL(string: uri),
                  let list = change["edits"] as? [[String: Any]] else { continue }
            edits[file.standardizedFileURL, default: []] += list
        }
        return edits
    }

    nonisolated static func edits(_ json: [[String: Any]], in text: NSString) -> [TextEdit] {
        json.compactMap { edit in
            guard let range = (edit["range"] as? [String: Any]).flatMap({ Self.range($0, in: text) }) else { return nil }
            return TextEdit(range: range, newText: edit["newText"] as? String ?? "")
        }
    }

    // MARK: - Positions

    private static func position(_ url: URL, _ text: NSString, _ offset: Int) -> [String: Any] {
        let (line, character) = lineAndCharacter(of: offset, in: text)
        return ["textDocument": ["uri": url.absoluteString], "position": ["line": line, "character": character]]
    }

    nonisolated static func lineAndCharacter(of offset: Int, in text: NSString) -> (Int, Int) {
        let p = textPosition(offset: Int32(clamping: offset), text: text as String)
        return (Int(p.line), Int(p.character))
    }

    nonisolated static func offset(line: Int, character: Int, in text: NSString) -> Int {
        Int(textOffset(line: Int32(clamping: line), character: Int32(clamping: character), text: text as String))
    }

    private nonisolated static func range(_ json: [String: Any], in text: NSString) -> NSRange? {
        guard let start = json["start"] as? [String: Any], let end = json["end"] as? [String: Any] else { return nil }
        let a = offset(line: start["line"] as? Int ?? 0, character: start["character"] as? Int ?? 0, in: text)
        let b = offset(line: end["line"] as? Int ?? 0, character: end["character"] as? Int ?? 0, in: text)
        return NSRange(location: a, length: max(b - a, 0))
    }

    private static func kind(_ raw: Int?) -> CompletionItem.Kind {
        switch raw {
        case 2, 3, 4: return .function
        case 6: return .variable
        case 5, 10: return .field
        case 21, 20, 12: return .constant
        case 14: return .keyword
        case 15: return .snippet
        case 17, 19: return .file
        default: return .other
        }
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, _ params: Any?, force: Bool = false) async -> Any? {
        guard isRunning else { return nil }
        nextID += 1
        let id = nextID
        return await withCheckedContinuation { cont in
            pending[id] = cont
            var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
            if let params { message["params"] = params }
            write(message, force: force)
        }
    }

    private func notify(_ method: String, _ params: Any?) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        write(message)
    }

    private func write(_ message: [String: Any], force: Bool = false) {
        guard isRunning, let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        if ready || force { send(frame) } else { outbox.append(frame) }
    }

    private func send(_ frame: Data) {
        try? input.fileHandleForWriting.write(contentsOf: frame)
    }

    private func handle(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let id = message["id"] as? Int
        if let method = message["method"] as? String {
            // Requests from the server need an answer, even an empty one.
            guard let id else { return }
            var result: Any = NSNull()
            if method == "workspace/configuration" {
                let count = ((message["params"] as? [String: Any])?["items"] as? [Any])?.count ?? 0
                result = Array(repeating: ["exportPdf": "never", "formatterMode": "typstyle"], count: count)
            }
            write(["jsonrpc": "2.0", "id": id, "result": result], force: true)
        } else if let id, let cont = pending.removeValue(forKey: id) {
            cont.resume(returning: message["result"])
        }
    }

    private func terminated() {
        isRunning = false
        output.fileHandleForReading.readabilityHandler = nil
        pending.values.forEach { $0.resume(returning: nil) }
        pending.removeAll()
    }

    /// Splits the server's output into `Content-Length` framed messages.
    private final class FrameReader: @unchecked Sendable {
        private var buffer = Data()
        private let lock = NSLock()

        func feed(_ data: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            var messages: [Data] = []
            let separator = Data("\r\n\r\n".utf8)
            while let headerEnd = buffer.range(of: separator) {
                let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                let length = header.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                guard buffer.count - (headerEnd.upperBound - buffer.startIndex) >= length else { break }
                let bodyStart = headerEnd.upperBound
                messages.append(Data(buffer[bodyStart..<bodyStart + length]))
                buffer = Data(buffer[(bodyStart + length)...])
            }
            return messages
        }
    }
}
