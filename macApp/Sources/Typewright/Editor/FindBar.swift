import AppKit
import Observation
import SwiftUI

/// Find and replace in the shown file, with plain or regular expression search.
@MainActor @Observable
final class FindModel {
    var isVisible = false
    var showsReplace = false
    var query = "" { didSet { if query != oldValue { search(selectNearest: true) } } }
    var replacement = ""
    var caseSensitive = false { didSet { if caseSensitive != oldValue { search(selectNearest: true) } } }
    var wholeWord = false { didSet { if wholeWord != oldValue { search(selectNearest: true) } } }
    var regex = false { didSet { if regex != oldValue { search(selectNearest: true) } } }
    private(set) var matches: [NSRange] = []
    private(set) var current: Int?
    /// Set when the regular expression doesn't compile.
    private(set) var error: String?
    /// Bumped to move keyboard focus into the search field.
    private(set) var focusRequest = 0

    @ObservationIgnored weak var textView: TypstTextView?
    /// Applies edits as one undo step; provided by the editor.
    @ObservationIgnored var applyEdits: (([TextEdit], String) -> Void)?
    /// Where the caret was when the search started; the first match after it is picked.
    @ObservationIgnored private var anchor = 0

    private static let limit = 10_000

    func show(replace: Bool) {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        anchor = selection.location
        // A short single-line selection becomes the search.
        if selection.length > 0, selection.length < 200 {
            let selected = (tv.string as NSString).substring(with: selection)
            if !selected.contains("\n") { query = regex ? NSRegularExpression.escapedPattern(for: selected) : selected }
        }
        isVisible = true
        if replace { showsReplace = true }
        focusRequest += 1
        search(selectNearest: true)
    }

    func close() {
        isVisible = false
        matches = []
        current = nil
        updateHighlights()
        if let tv = textView { tv.window?.makeFirstResponder(tv) }
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    /// Re-runs the search after the text changed, keeping the place.
    func textDidChange() {
        guard isVisible else { return }
        anchor = current.flatMap { matches.indices.contains($0) ? matches[$0].location : nil } ?? anchor
        search(selectNearest: false)
    }

    func replaceCurrent() {
        guard let tv = textView, let regex = expression(), let index = current, matches.indices.contains(index) else { return }
        let range = matches[index]
        let text = tv.string
        guard let match = regex.firstMatch(in: text, range: range), match.range == range else { return }
        let new = regex.replacementString(for: match, in: text, offset: 0, template: template)
        anchor = range.location + (new as NSString).length
        applyEdits?([TextEdit(range: range, newText: new)], "Replace")
        search(selectNearest: true)
    }

    func replaceAll() {
        guard let tv = textView, let regex = expression(), !matches.isEmpty else { return }
        let text = tv.string
        let edits = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .filter { $0.range.length > 0 }
            .map { TextEdit(range: $0.range, newText: regex.replacementString(for: $0, in: text, offset: 0, template: template)) }
        applyEdits?(edits, "Replace All")
        search(selectNearest: false)
    }

    var status: String {
        if error != nil { return "Invalid" }
        if query.isEmpty { return "" }
        if matches.isEmpty { return "No results" }
        let count = matches.count >= Self.limit ? "\(Self.limit)+" : "\(matches.count)"
        return current.map { "\($0 + 1) of \(count)" } ?? count
    }

    // MARK: - Searching

    /// Plain text replacements are literal; regex ones may use `$1` groups.
    private var template: String {
        regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    private func expression() -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    private func search(selectNearest: Bool) {
        guard isVisible, let tv = textView else { return }
        error = nil
        guard !query.isEmpty else {
            matches = []
            current = nil
            return updateHighlights()
        }
        guard let regex = expression() else {
            error = "Invalid regular expression"
            matches = []
            current = nil
            return updateHighlights()
        }
        let text = tv.string
        var found: [NSRange] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            // Empty matches like `^` can't be shown or stepped through.
            if let r = match?.range, r.length > 0 { found.append(r) }
            if found.count >= Self.limit { stop.pointee = true }
        }
        matches = found
        current = found.isEmpty ? nil : found.firstIndex { $0.location >= anchor } ?? 0
        updateHighlights()
        if selectNearest { reveal() }
    }

    private func step(by delta: Int) {
        guard !matches.isEmpty else { return NSSound.beep() }
        let index = ((current ?? (delta > 0 ? -1 : 0)) + delta + matches.count) % matches.count
        current = index
        anchor = matches[index].location
        updateHighlights()
        reveal()
    }

    private func reveal() {
        guard let tv = textView, let index = current, matches.indices.contains(index) else { return }
        let range = matches[index]
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
    }

    private func updateHighlights() {
        textView?.findMatches = matches
        textView?.currentFindMatch = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
    }
}

/// Floating find bar over the editor's top right corner.
struct FindBar: View {
    @Bindable var find: FindModel
    @FocusState private var focus: Field?

    private enum Field { case search, replace }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Find", text: $find.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                    .onSubmit {
                        if NSEvent.modifierFlags.contains(.shift) { find.previous() } else { find.next() }
                        focus = .search
                    }
                Text(find.status)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(find.error != nil || (find.matches.isEmpty && !find.query.isEmpty) ? .red : .secondary)
                    .frame(minWidth: 62, alignment: .trailing)
                ControlGroup {
                    Button(action: find.previous) { Image(systemName: "chevron.up") }
                        .help("Previous match (⇧⌘G)")
                    Button(action: find.next) { Image(systemName: "chevron.down") }
                        .help("Next match (⌘G)")
                }
                .frame(width: 56)
                Button(action: find.close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close (Esc)")
            }
            HStack(spacing: 12) {
                Toggle("Match Case", isOn: $find.caseSensitive)
                Toggle("Words", isOn: $find.wholeWord)
                Toggle("Regex", isOn: $find.regex)
                Spacer(minLength: 0)
                Toggle("Replace", isOn: $find.showsReplace.animation(.smooth(duration: 0.2)))
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            if find.showsReplace {
                HStack(spacing: 6) {
                    TextField(find.regex ? "Replace ($1 for groups)" : "Replace", text: $find.replacement)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .replace)
                        .onSubmit {
                            find.replaceCurrent()
                            focus = .replace
                        }
                    Button("Replace", action: find.replaceCurrent)
                        .disabled(find.current == nil)
                    Button("All", action: find.replaceAll)
                        .disabled(find.matches.isEmpty)
                }
                .controlSize(.small)
                .transition(.opacity)
            }
        }
        .controlSize(.small)
        .padding(10)
        .frame(width: 400)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(CursorArea())
        .onExitCommand(perform: find.close)
        // Checkboxes and buttons with keyboard focus don't pass Esc on to SwiftUI.
        .onEscapeWhenUnfocused(accepts: { $0 is NSButton }, find.close)
        .onChange(of: find.focusRequest, initial: true) {
            focusSearch()
        }
        .background {
            // Shortcuts that work while the bar has focus.
            Group {
                Button("") { find.next() }.keyboardShortcut("g")
                Button("") { find.previous() }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("") { withAnimation(.smooth(duration: 0.2)) { find.showsReplace = true }; focus = .replace }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("") { focusSearch() }.keyboardShortcut("f")
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    /// The editor holds on to first responder until it's released; then the field can take focus.
    private func focusSearch() {
        if !(find.textView?.window?.firstResponder is NSText) || find.textView?.window?.firstResponder === find.textView {
            find.textView?.window?.makeFirstResponder(nil)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            focus = .search
        }
    }
}
