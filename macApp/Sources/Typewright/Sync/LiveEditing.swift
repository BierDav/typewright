import AppKit
import Observation
import TypewrightCore

/// Another device's caret or selection in the shown file.
struct RemoteCursor: Equatable {
    let device: String
    let name: String
    let range: NSRange

    var color: NSColor {
        let palette: [NSColor] = [.systemPink, .systemOrange, .systemPurple, .systemTeal, .systemGreen, .systemBlue,
                                  .systemIndigo, .systemBrown]
        let hash = device.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

/// Keeps the shown file of a synced space in a live session with the account's other devices:
/// keystrokes go out as they happen and theirs come in as edits, with their cursors.
@MainActor @Observable
final class LiveEditing {
    /// Names of the other devices with the file open.
    private(set) var participants: [String] = []

    /// Set by the editor: applies remote edits in order, keeping the caret in place.
    @ObservationIgnored var applyEdits: (([LiveResult.Edit]) -> Bool)?
    /// Set by the editor to draw the other devices' cursors.
    @ObservationIgnored var showCursors: (([RemoteCursor]) -> Void)?
    /// Replaces the text when no editor shows it.
    @ObservationIgnored var replaceText: ((String) -> Void)?
    @ObservationIgnored var currentText: () -> String = { "" }

    @ObservationIgnored private let root: URL
    @ObservationIgnored private var path: String?
    @ObservationIgnored private var selection = NSRange(location: 0, length: 0)
    /// Set while remote edits are applied, whose echo needs no sync.
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    var isActive: Bool { path != nil }
    /// Files in a live session, as `root/path`.
    private static var sessions: Set<String> = []

    init(root: URL) {
        self.root = root
        observer = NotificationCenter.default.addObserver(forName: SyncService.liveDidChange, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? URL)?.standardizedFileURL == root.standardizedFileURL,
                      note.userInfo?["path"] as? String == self.path else { return }
                self.sync()
            }
        }
    }

    /// Ends the session for good, when the space closes.
    func stop() {
        close()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Starts sharing the file `path` (relative to the space) if the space syncs and the file is small enough.
    func open(_ path: String?, text: String) {
        guard path != self.path else { return }
        close()
        guard let path, SyncService.shared.isRunning, SyncService.shared.isSynced(root), text.utf8.count <= SyncService.liveLimit else { return }
        // The bridge keeps one session per file; another window with it open already shares it.
        guard Self.sessions.insert(root.standardizedFileURL.path + "/" + path).inserted else { return }
        self.path = path
        selection = NSRange(location: 0, length: 0)
        SyncService.shared.liveOpen(root: root, path: path, text: text)
    }

    func close() {
        guard let path else { return }
        Self.sessions.remove(root.standardizedFileURL.path + "/" + path)
        SyncService.shared.liveClose(root: root, path: path)
        self.path = nil
        participants = []
        showCursors?([])
    }

    func textDidChange() {
        if !isApplying { sync() }
    }

    func selectionDidChange(_ range: NSRange) {
        guard range != selection else { return }
        selection = range
        if !isApplying { sync() }
    }

    /// Undoes or redoes this device's own edits only, leaving the others' in place; false when not live.
    func undo(redo: Bool) -> Bool {
        guard isActive else { return false }
        sync(step: redo ? 2 : 1)
        return true
    }

    private func sync(step: Int32 = 0) {
        guard let path, let result = SyncService.shared.liveSync(root: root, path: path, text: currentText(),
                                                                 selection: selection, step: step) else { return }
        if let adopted = result.adopted {
            // Another device's session was first; this device's edits since opening merge into it.
            let mine = currentText()
            let merged = merge3(base: adopted.base, local: mine, remote: adopted.theirs)
            apply([Self.edit(from: mine, to: merged.conflicts == 0 ? merged.text : adopted.theirs)])
            sync()
            return
        }
        apply(result.edits)
        let names = result.cursors.map(\.name)
        if names != participants { participants = names }
        showCursors?(result.cursors.map {
            RemoteCursor(device: $0.device, name: $0.name, range: NSRange(location: $0.location, length: $0.length))
        })
    }

    private func apply(_ edits: [LiveResult.Edit]) {
        let edits = edits.filter { $0.length > 0 || !$0.text.isEmpty }
        guard !edits.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }
        if applyEdits?(edits) != true {
            let text = NSMutableString(string: currentText())
            for edit in edits where edit.location + edit.length <= text.length {
                text.replaceCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.text)
            }
            replaceText?(text as String)
        }
    }

    /// The one changed span between two texts.
    private static func edit(from old: String, to new: String) -> LiveResult.Edit {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        // Never split a surrogate pair.
        if prefix > 0, prefix < a.count, UTF16.isTrailSurrogate(a[prefix]) { prefix -= 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let inserted = String(utf16CodeUnits: Array(b[prefix..<(b.count - suffix)]), count: b.count - suffix - prefix)
        return LiveResult.Edit(location: prefix, length: a.count - suffix - prefix, text: inserted)
    }
}
