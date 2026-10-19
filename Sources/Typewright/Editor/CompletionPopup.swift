import AppKit

/// Language server completions in a menu-like panel under the caret, filtered as you type.
@MainActor
final class CompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var textView: NSTextView?
    var provider: ((Int) async -> [CompletionItem])?

    private var items: [CompletionItem] = []
    private var shown: [CompletionItem] = []
    /// Cursor when the items were requested; ranges reaching past it stretch along as you type.
    private var requestCursor = 0
    private var generation = 0
    private var requestTask: Task<Void, Never>?
    /// Set while the controller edits the text itself, so that change doesn't count as typing.
    private(set) var isEditing = false

    private lazy var panel = makePanel()
    private let table = NSTableView()

    private static let rowHeight: CGFloat = 22
    private static let width: CGFloat = 380
    private static let maxRows = 9
    private static let identifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    /// tinymist's trigger characters.
    private static let triggers: Set<Character> = ["#", "(", "<", ",", ".", ":", "/", "\"", "@"]

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
    }

    var isVisible: Bool { panel.isVisible && !shown.isEmpty }

    // MARK: - Triggers

    /// Reacts to what was typed: more of a word refilters, a trigger character asks the server again.
    func textDidChange(typed: String?) {
        guard let tv = textView, provider != nil else { return }
        guard let typed else { return hide() }
        let cursor = tv.selectedRange().location
        if typed.isEmpty {
            // Deleting keeps the list while still inside the completed word.
            if isVisible, cursor >= anchor { refilter() } else { hide() }
            return
        }
        guard let last = typed.last else { return }
        if Self.triggers.contains(last) {
            request(force: false)
        } else if last.unicodeScalars.allSatisfy(Self.identifier.contains) {
            if isVisible { refilter() } else { request(force: false) }
        } else {
            hide()
        }
    }

    /// Asks the server for completions at the cursor; `force` shows them even without a typed prefix.
    func request(force: Bool) {
        guard let tv = textView, let provider else { return }
        generation += 1
        let current = generation
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            // A short pause lets fast typing settle before the server is asked.
            if !force { try? await Task.sleep(for: .milliseconds(40)) }
            guard !Task.isCancelled else { return }
            let cursor = tv.selectedRange().location
            let result = await provider(cursor)
            guard let self, current == self.generation, tv.selectedRange().location == cursor else { return }
            self.items = result
            self.requestCursor = cursor
            self.refilter()
        }
    }

    func hide() {
        generation += 1
        requestTask?.cancel()
        shown = []
        if panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    /// Selection moves outside the word being completed close the list.
    func selectionDidChange() {
        guard isVisible, !isEditing, let tv = textView else { return }
        let sel = tv.selectedRange()
        if sel.length > 0 || sel.location < anchor || sel.location > (tv.string as NSString).length { hide() }
    }

    // MARK: - Keys

    /// Handles navigation keys while the list is open.
    func handle(_ selector: Selector) -> Bool {
        guard isVisible else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): accept()
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    private func move(by delta: Int) {
        let row = min(max(table.selectedRow + delta, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: - Filtering

    /// Start of the text being completed.
    private var anchor: Int {
        let starts = items.compactMap { $0.range?.location }
        return starts.min() ?? wordStart
    }

    private var wordStart: Int {
        guard let tv = textView else { return 0 }
        let s = tv.string as NSString
        var i = min(tv.selectedRange().location, s.length)
        while i > 0, let scalar = UnicodeScalar(s.character(at: i - 1)), Self.identifier.contains(scalar) { i -= 1 }
        return i
    }

    private func start(of item: CompletionItem) -> Int { item.range?.location ?? wordStart }

    private func refilter() {
        guard let tv = textView else { return }
        let s = tv.string as NSString
        let cursor = tv.selectedRange().location
        let scored = items.compactMap { item -> (Int, CompletionItem)? in
            let start = start(of: item)
            guard start <= cursor, cursor <= s.length else { return nil }
            let typed = s.substring(with: NSRange(location: start, length: cursor - start)).lowercased()
            let key = item.filterText.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
            guard let score = Self.score(typed, key) else { return nil }
            return (score, item)
        }
        shown = scored.sorted { a, b in
            a.0 != b.0 ? a.0 < b.0 : a.1.sortText < b.1.sortText
        }.map(\.1)
        // A list that only repeats what's typed is noise.
        if shown.isEmpty || (shown.count == 1 && Self.plain(shown[0]) == s.substring(with: NSRange(location: start(of: shown[0]),
                                                                                                      length: cursor - start(of: shown[0])))) {
            return hide()
        }
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        show()
    }

    /// Lower is better: prefix, then substring, then scattered letters; nil if it doesn't match.
    private static func score(_ typed: String, _ key: String) -> Int? {
        if typed.isEmpty || key.hasPrefix(typed) { return 0 }
        if key.contains(typed) { return 1 }
        var rest = Substring(key)
        for c in typed {
            guard let i = rest.firstIndex(of: c) else { return nil }
            rest = rest[rest.index(after: i)...]
        }
        return 2
    }

    // MARK: - Accepting

    private func accept() {
        guard let tv = textView, shown.indices.contains(table.selectedRow) else { return hide() }
        let item = shown[table.selectedRow]
        let s = tv.string as NSString
        let cursor = tv.selectedRange().location
        let start = start(of: item)
        let tail = item.range.map { max(NSMaxRange($0) - requestCursor, 0) } ?? 0
        let range = NSRange(location: start, length: min(cursor + tail, s.length) - start)
        let (text, caret) = item.isSnippet ? Self.expand(item.newText)
            : (item.newText, NSRange(location: (item.newText as NSString).length, length: 0))
        hide()
        isEditing = true
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            // A placeholder like `alignment` is selected, so typing replaces it.
            tv.setSelectedRange(NSRange(location: start + caret.location, length: caret.length))
        }
        isEditing = false
        // Functions land inside their parentheses; offer their arguments right away.
        let after = tv.string as NSString
        let location = tv.selectedRange().location
        if tv.selectedRange().length == 0, location > 0, location <= after.length, after.character(at: location - 1) == 40 {
            request(force: true)
        }
    }

    /// Turns snippet syntax into plain text and the selection for the first placeholder, covering its default text.
    nonisolated static func expand(_ snippet: String) -> (String, NSRange) {
        var out = ""
        var first: (index: Int, offset: Int, length: Int)?
        var chars = Array(snippet)
        var i = 0
        func mark(_ n: Int) {
            let offset = (out as NSString).length
            // $0 is the final position; any numbered stop comes before it.
            let rank = n == 0 ? Int.max : n
            if first == nil || rank < first!.index { first = (rank, offset, 0) }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(chars[i + 1])
                i += 2
            } else if c == "$", i + 1 < chars.count, chars[i + 1].isNumber {
                var j = i + 1, n = 0
                while j < chars.count, let d = chars[j].wholeNumberValue { n = n * 10 + d; j += 1 }
                mark(n)
                i = j
            } else if c == "$", i + 1 < chars.count, chars[i + 1] == "{" {
                var j = i + 2, n = 0
                while j < chars.count, let d = chars[j].wholeNumberValue { n = n * 10 + d; j += 1 }
                mark(n)
                let start = (out as NSString).length
                if j < chars.count, chars[j] == ":" {
                    // Keep the placeholder text, which may nest braces.
                    var depth = 1
                    j += 1
                    while j < chars.count {
                        if chars[j] == "{" { depth += 1 }
                        if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                        out.append(chars[j])
                        j += 1
                    }
                    if first?.offset == start, first?.length == 0 { first?.length = (out as NSString).length - start }
                } else {
                    while j < chars.count, chars[j] != "}" { j += 1 }
                }
                i = j + 1
            } else {
                out.append(c)
                i += 1
            }
        }
        chars = []
        let end = (out as NSString).length
        return (out, first.map { NSRange(location: $0.offset, length: $0.length) } ?? NSRange(location: end, length: 0))
    }

    private static func plain(_ item: CompletionItem) -> String {
        item.isSnippet ? expand(item.newText).0 : item.newText
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scroll.frame = background.bounds
        scroll.autoresizingMask = [.width, .height]
        background.addSubview(scroll)
        panel.contentView = background
        return panel
    }

    @objc private func doubleClicked() { accept() }

    private func show() {
        guard let tv = textView, let window = tv.window else { return }
        let height = CGFloat(min(shown.count, Self.maxRows)) * Self.rowHeight + 8
        let caret = tv.firstRect(forCharacterRange: NSRange(location: anchor, length: 0), actualRange: nil)
        let screen = window.screen?.visibleFrame ?? .infinite
        // Icons line up with the typed text; flips above the line when the screen ends.
        var origin = NSPoint(x: caret.minX - 30, y: caret.minY - height - 2)
        if origin.y < screen.minY { origin.y = caret.maxY + 2 }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - Self.width)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CompletionCell.identifier, owner: nil) as? CompletionCell ?? CompletionCell()
        cell.show(shown[row])
        return cell
    }
}

private final class CompletionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let stack = NSStackView(views: [icon, label, detail])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: CompletionItem) {
        label.stringValue = item.label
        detail.stringValue = item.detail ?? ""
        let (symbol, tint): (String, NSColor) = switch item.kind {
        case .function: ("f.cursive", .systemBlue)
        case .variable: ("x.squareroot", .systemTeal)
        case .constant: ("number", .systemOrange)
        case .keyword: ("textformat", .systemPink)
        case .snippet: ("curlybraces", .systemGray)
        case .file: ("doc", .systemGray)
        case .font: ("textformat.alt", .systemPurple)
        case .field: ("tag", .systemGreen)
        case .other: ("circle.fill", .systemGray)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
    }
}
