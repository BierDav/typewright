import AppKit
import SwiftUI
import TypewrightCore
import UniformTypeIdentifiers

/// A use of a symbol, listed when ⌘B is pressed on its definition.
struct SymbolUsage {
    let location: SourceLocation
    /// Path relative to the space.
    let file: String
    let preview: String
}

/// Language server features the editor offers for the shown file; offsets are UTF-16.
@MainActor protocol EditorLanguage: AnyObject {
    func completions(at offset: Int) async -> [CompletionItem]
    /// Markdown docs of a completion item, for F1 in the list.
    func documentation(of item: CompletionItem) async -> String?
    /// Navigates, or returns the usages to choose from when `offset` is on a definition.
    func goToDefinition(at offset: Int) async -> [SymbolUsage]
    /// Web pages for what's at `offset`, like a package's Universe page and repository; ⌘B offers them.
    func links(at offset: Int) async -> [(title: String, url: URL)]
    func open(_ location: SourceLocation)
    func hover(at offset: Int) async -> (markdown: String, range: NSRange?)?
    func occurrences(at offset: Int) async -> [NSRange]
    func formattingEdits() async -> [TextEdit]
    func renameTarget(at offset: Int) async -> (range: NSRange, name: String)?
    /// Edits for the shown file; other files are updated by the language itself.
    func rename(at offset: Int, to name: String) async -> [TextEdit]
    func quickFixes(for diagnostic: Diagnostic) -> [QuickFix]
    /// Text of the files around the shown one that solveng settings and definitions come from.
    func solvengContext() -> String
}

extension EditorLanguage {
    func quickFixes(for diagnostic: Diagnostic) -> [QuickFix] { [] }
    func solvengContext() -> String { "" }
    func links(at offset: Int) async -> [(title: String, url: URL)] { [] }
    func documentation(of item: CompletionItem) async -> String? { item.documentation }
}

/// How the editor's comment shortcuts comment the shown file.
struct CommentSyntax: Equatable {
    /// What a commented line starts with, like `// `.
    var linePrefix = "// "
    /// What it ends with, for Markdown's HTML comments instead of line comments.
    var lineSuffix = ""
    var blockPrefix = "/*"
    var blockSuffix = "*/"

    /// The markers alone, for taking comments away again.
    var lineMarker: String { linePrefix.trimmingCharacters(in: .whitespaces) }
    var lineSuffixMarker: String { lineSuffix.trimmingCharacters(in: .whitespaces) }

    static let typst = CommentSyntax()
    static let markdown = CommentSyntax(linePrefix: "<!-- ", lineSuffix: " -->", blockPrefix: "<!--", blockSuffix: "-->")
}

final class TypstTextView: NSTextView, NSLayoutManagerDelegate {
    /// Color literals that get a clickable swatch in the gap kerned in before them.
    var swatches: [ColorLiteral] = [] {
        didSet { if swatches != oldValue { needsDisplay = true } }
    }
    var onSwatchClick: ((ColorLiteral) -> Void)?
    var onDefinition: ((Int) -> Void)?
    /// A click moved the caret far from this location, which the navigation history keeps.
    var onJump: ((Int) -> Void)?
    var onComplete: (() -> Void)?
    /// F1: docs of the selected completion, or of the symbol at the caret.
    var onShowDocs: (() -> Void)?
    var onFormat: (() -> Void)?
    /// Shows the fixes for the diagnostics at a character, e.g. on ⌥↩.
    var onQuickFix: ((Int) -> Void)?
    /// Whether there are fixes at a character, for the context menu.
    var hasQuickFixes: ((Int) -> Bool)?
    /// Undo and redo while something keeps its own history, like an inline rename; false lets the normal undo run.
    var onUndo: (() -> Bool)?
    var onRedo: (() -> Bool)?
    /// Opens find, with the replace field when true.
    var onFind: ((Bool) -> Void)?
    var onFindStep: ((Int) -> Void)?
    /// How the shown file is commented; nil leaves ⌘7 and ⇧⌘7 unused.
    var comments: CommentSyntax?
    /// The scroll bar's diagnostic ticks, which want the arrow over the text's edge.
    weak var markers: DiagnosticMarkers?

    // MARK: Column selection

    /// The fill of rounded selections.
    var selectionColor = NSColor.gray.withAlphaComponent(0.3) {
        didSet { updateSelectionBackground() }
    }
    /// Carets edited together (see ColumnSelection.swift); empty while there's one selection.
    var columnCarets: [ColumnCaret] = [] {
        didSet {
            guard columnCarets != oldValue else { return }
            needsDisplay = true
            updateSelectionBackground()
        }
    }
    /// The caret the text view selects itself, which scrolling and the caret drawing follow.
    var primaryColumn = 0
    /// Set while the carets change the text view's selection, which otherwise ends them.
    var isUpdatingColumns = false
    /// ⇧⌘8: a plain drag selects a column and ⇧↑ and ⇧↓ add lines to it.
    var columnSelectionMode = false {
        didSet { if columnSelectionMode != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    private func updateSelectionBackground() {
        // AppKit's rectangular fill would cover the rounded corners.
        if (selectedTextAttributes[.backgroundColor] as? NSColor) != .clear {
            var attributes = selectedTextAttributes
            attributes[.backgroundColor] = NSColor.clear
            selectedTextAttributes = attributes
        }
        needsDisplay = true
    }

    private var isSelectingWithMouse = false

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isUpdatingColumns { endColumns() }
        if !isMovingVertically { verticalGoal = nil }
        // AppKit's mouse tracker bypasses public hit-testing for hidden glyphs.
        let ranges = !isUpdatingColumns && (isSelectingWithMouse || stillSelecting) && selectionGranularity == .selectByCharacter
            ? ranges.map { value in
                let range = value.rangeValue
                let start = insertionIndexForConceals(range.location)
                let end = insertionIndexForConceals(NSMaxRange(range))
                return NSValue(range: NSRange(location: start, length: max(0, end - start)))
            } : ranges
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateSelectionBackground()
        if !isUpdatingColumns { updateRevealedEquation() }
    }

    override func doCommand(by selector: Selector) {
        if isColumnMode {
            if performInColumns(selector) { return }
            endColumns()
        } else if columnSelectionMode, selector == #selector(moveUpAndModifySelection(_:)) || selector == #selector(moveDownAndModifySelection(_:)) {
            return extendColumn(up: selector == #selector(moveUpAndModifySelection(_:)))
        }
        super.doCommand(by: selector)
    }

    override func copy(_ sender: Any?) {
        if hasOnlyInsertionPoints { return copyCurrentRows() }
        if isColumnMode { copyColumns() } else { super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        guard isEditable else { return }
        if hasOnlyInsertionPoints { return cutCurrentRows() }
        guard isColumnMode else { return super.cut(sender) }
        copyColumns()
        replaceInColumns(columnCarets.map { ($0.range, "") }, action: "Cut")
    }

    /// Saves pasted images next to the shown file and returns the text that shows them; nil pastes as usual.
    var onPasteImage: ((NSPasteboard) -> String?)?
    /// After an undo (false) or redo (true) with the resulting text, so pasted images can go and come back with it.
    var onDidUndo: ((Bool, String) -> Void)?

    /// Image files dropped from Finder are saved like pasted ones and referenced at the drop point.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let images = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        guard isEditable, !images.isEmpty, let onPasteImage else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        guard let reference = onPasteImage(pasteboard) else { return false }
        window?.makeFirstResponder(self)
        replace(NSRange(location: index, length: 0), with: reference,
                select: NSRange(location: index + (reference as NSString).length, length: 0), action: "Drop Image")
        return true
    }

    override func paste(_ sender: Any?) {
        if isColumnMode { return pasteInColumns() }
        if let onPasteImage, let reference = onPasteImage(.general) {
            let range = selectedRange()
            // A `#` typed just before keeps the call from getting two.
            let text = range.location > 0 && (string as NSString).character(at: range.location - 1) == 35 && reference.hasPrefix("#")
                ? String(reference.dropFirst()) : reference
            let end = NSRange(location: range.location + (text as NSString).length, length: 0)
            return replace(range, with: text, select: end, action: "Paste")
        }
        super.paste(sender)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Composed input goes to the primary caret only.
        endColumns()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    // MARK: Auto-closing

    /// Openers and the closers typed along with them; empty turns it off.
    var autoPairs: [Character: Character] = [:]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if isColumnMode, replacementRange.location == NSNotFound || replacementRange == selectedRange(),
           let typed = (string as? String) ?? (string as? NSAttributedString)?.string {
            return insertInColumns(typed)
        }
        guard !autoPairs.isEmpty, !hasMarkedText(), replacementRange.location == NSNotFound || replacementRange == selectedRange(),
              let typed = (string as? String) ?? (string as? NSAttributedString)?.string, typed.count == 1,
              let c = typed.first, isEditable else { return super.insertText(string, replacementRange: replacementRange) }
        let s = self.string as NSString
        let selection = selectedRange()
        let next = NSMaxRange(selection) < s.length ? Character(UnicodeScalar(s.character(at: NSMaxRange(selection))) ?? " ") : nil
        let previous = selection.location > 0 ? Character(UnicodeScalar(s.character(at: selection.location - 1)) ?? " ") : nil
        let closers = Set(autoPairs.values)
        // The third backtick of a fence closes it with a fence of its own and offers the language tags.
        if c == "`", autoPairs[c] != nil, selection.length == 0, selection.location >= 2, next != "`",
           s.substring(with: NSRange(location: selection.location - 2, length: 2)) == "``",
           selection.location == 2 || s.character(at: selection.location - 3) != 96 {
            super.insertText("````", replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            onComplete?()
            return
        }
        // Typing the closer that's already there steps over it.
        if selection.length == 0, closers.contains(c), next == c, previous != "\\" {
            return setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        }
        guard let closer = autoPairs[c], previous != "\\" else { return super.insertText(string, replacementRange: replacementRange) }
        // A selection gets wrapped and stays selected.
        if selection.length > 0 {
            let inner = s.substring(with: selection)
            super.insertText(String(c) + inner + String(closer), replacementRange: selection)
            return setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
        }
        if c == "$", Highlighter.closesMath(in: self.string, at: selection.location) {
            return super.insertText(string, replacementRange: replacementRange)
        }
        // Only before whitespace, a closer or punctuation, so typing in front of a word doesn't add a stray closer.
        let symmetric = c == closer
        let freeAfter = next.map { $0.isWhitespace || closers.contains($0) || ",;:.".contains($0) } ?? true
        let freeBefore = !symmetric || !(previous.map { $0.isLetter || $0.isNumber } ?? false)
            || c == "\"" && gluesNames(at: selection.location)
        guard freeAfter, freeBefore else { return super.insertText(string, replacementRange: replacementRange) }
        super.insertText(String(c) + String(closer), replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + 1, length: 0))
    }

    /// Whether a `"` typed at `location` glues names, in math and solveng code (`Delta""tau`), so it pairs after letters too.
    private func gluesNames(at location: Int) -> Bool {
        // Only Typst pairs `$`.
        autoPairs["$"] != nil && Highlighter.gluesNames(in: string, at: location)
    }

    /// Backspace in an empty pair takes the closer along; in the indentation it goes back to where the line belongs,
    /// then onto the line above, like IntelliJ.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, !isColumnMode, isEditable,
              let change = TypewrightCore.backspace(text: string, caret: Int32(selection.location),
                                                    pairs: autoPairs.map { String($0.key) + String($0.value) }.joined())
        else { return super.deleteBackward(sender) }
        apply(change, action: "Typing")
    }

    /// Replaces as the core's `Typing` says and puts the caret where it says.
    private func apply(_ change: Typing, action: String) {
        let range = NSRange(location: Int(change.from), length: Int(change.to - change.from))
        guard shouldChangeText(in: range, replacementString: change.insert) else { return }
        replaceCharacters(in: range, with: change.insert)
        didChangeText()
        setSelectedRange(NSRange(location: Int(change.caret), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// `"typst"`, `"markdown"` or plain text, for what Enter continues.
    var syntax = ""

    // MARK: Hidden syntax

    /// The files around the shown one, for solveng code in them.
    var solvengContext: (() -> String)?

    /// Math shows as it renders, like `$12"k"Omega$` as `$12kΩ$`, except the piece the caret touches.
    var concealsMath = false {
        didSet {
            guard concealsMath != oldValue else { return }
            layoutManager?.delegate = self
            observeStorage()
            refreshConceals()
        }
    }

    /// Recomputes what's concealed, e.g. once a compile tells whether solveng reads math.
    func refreshConceals() {
        conceals = concealsMath ? Highlighter.conceals(in: string, context: solvengContext?() ?? "") : []
        invalidateGlyphs(in: NSRange(location: 0, length: (string as NSString).length))
        updateRevealedEquation()
    }

    /// Sorted by location; found again while each edit is processed, before anything is laid out with stale positions.
    private(set) var conceals: [Highlighter.Conceal] = [] {
        didSet {
            let (kept, pieces) = Self.pieces(of: conceals, text: string as NSString)
            // Setting it here doesn't run didSet again.
            if kept.count != conceals.count { conceals = kept }
            self.pieces = pieces
        }
    }

    /// What reveals as one: a symbol, a string with both its quotes, or such pieces glued by empty strings
    /// (`Delta""Gamma`).
    private struct Piece {
        let range: NSRange
    }
    private var pieces: [Piece] = []

    /// The pieces of `conceals`, and the conceals without empty strings that glue nothing, which show as typed.
    private static func pieces(of conceals: [Highlighter.Conceal], text: NSString) -> ([Highlighter.Conceal], [Piece]) {
        // Single pieces first, each with its conceals.
        var singles: [(range: NSRange, box: NSRange?, conceals: ArraySlice<Highlighter.Conceal>)] = []
        var i = 0
        while i < conceals.count {
            let c = conceals[i]
            // Constructor wrappers and their contents reveal together.
            if c.replacement == 0, c.range.location == c.equation.location, c.range.length > 1,
               let end = conceals[i...].firstIndex(where: {
                   $0.replacement == 0 && $0.equation == c.equation && NSMaxRange($0.range) == NSMaxRange(c.equation)
               }), end > i {
                let box = NSRange(location: NSMaxRange(c.range), length: conceals[end].range.location - NSMaxRange(c.range))
                singles.append((c.equation, box.length > 0 ? box : nil, conceals[i...end]))
                i = end + 1
                continue
            }
            // A hidden prefix like the `#` of `#inch` collapses into the name it introduces, so that name is marked.
            if c.replacement == 0, c.range.location == c.equation.location, NSMaxRange(c.equation) > NSMaxRange(c.range) {
                var end = i
                while end + 1 < conceals.count, conceals[end + 1].equation == c.equation,
                      NSMaxRange(conceals[end + 1].range) <= NSMaxRange(c.equation) { end += 1 }
                let box = NSRange(location: NSMaxRange(c.range), length: NSMaxRange(c.equation) - NSMaxRange(c.range))
                singles.append((c.equation, box, conceals[i...end]))
                i = end + 1
                continue
            }
            // Hidden quotes come in pairs.
            if c.replacement == 0, i + 1 < conceals.count, conceals[i + 1].replacement == 0, conceals[i + 1].equation == c.equation {
                let close = conceals[i + 1].range
                let box = NSRange(location: NSMaxRange(c.range), length: close.location - NSMaxRange(c.range))
                singles.append((NSRange(location: c.range.location, length: NSMaxRange(close) - c.range.location),
                                box.length > 0 ? box : nil, conceals[i...(i + 1)]))
                i += 2
            } else {
                singles.append((c.range, c.replacement == 0 ? nil : NSRange(location: c.range.location, length: 1), conceals[i...i]))
                i += 1
            }
        }
        // Runs of pieces that touch through an empty string; one with nothing else in it isn't concealed.
        let empty = { (k: Int) in singles[k].box == nil && singles[k].conceals.count == 2 }
        var kept: [Highlighter.Conceal] = []
        var pieces: [Piece] = []
        var j = 0
        while j < singles.count {
            var end = j
            while end + 1 < singles.count, NSMaxRange(singles[end].range) == singles[end + 1].range.location,
                  empty(end) || empty(end + 1) { end += 1 }
            let run = singles[j...end]
            var boxes = run.compactMap(\.box)
            var start = run.first!.range.location
            var finish = NSMaxRange(run.last!.range)
            if empty(j), start > 0 {
                let left = text.rangeOfComposedCharacterSequence(at: start - 1)
                if text.substring(with: left).unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                    start = left.location
                    boxes.insert(left, at: 0)
                }
            }
            if empty(end), finish < text.length {
                let right = text.rangeOfComposedCharacterSequence(at: finish)
                if text.substring(with: right).unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                    finish = NSMaxRange(right)
                    boxes.append(right)
                }
            }
            if !boxes.isEmpty || (j...end).contains(where: { !empty($0) }) {
                kept += run.flatMap(\.conceals)
                pieces.append(Piece(range: NSRange(location: start, length: finish - start)))
            }
            j = end + 1
        }
        return (kept, pieces)
    }

    private var storageObserver: (any NSObjectProtocol)?
    /// The conceals before the edits not yet compared, and how much those edits changed the length.
    private var pendingConceals: (old: [Highlighter.Conceal], delta: Int)?

    private func observeStorage() {
        guard storageObserver == nil, let storage = textStorage else { return }
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.storageDidProcessEditing() } }
    }

    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
    }

    /// Runs before the layout manager hears of the edit, so its new glyphs see the new conceals.
    private func storageDidProcessEditing() {
        guard concealsMath, let storage = textStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let first = pendingConceals == nil
        pendingConceals = (pendingConceals?.old ?? conceals, (pendingConceals?.delta ?? 0) + storage.changeInLength)
        conceals = Highlighter.conceals(in: storage.string, context: solvengContext?() ?? "")
        // Other changed equations, like everything after a new `$`, once the layout manager caught up with the edit.
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let pending = self.pendingConceals else { return }
            self.pendingConceals = nil
            self.invalidateChangedConceals(from: pending.old, delta: pending.delta)
            self.updateRevealedEquation()
        }
    }

    /// The pieces shown as typed: the one the caret is in or next to, or all a selection or column touches.
    private var revealedPieces: [NSRange] = []

    var collapsedSegments: [NSRange] {
        let revealed = Set(revealedPieces)
        return pieces.map(\.range).filter { !revealed.contains($0) }
    }

    func updateRevealedEquation() {
        updateOperatorLigatures()
        reveal(piecesShown())
    }

    /// The piece at the caret, or every piece a selection or column touches.
    private func piecesShown() -> [NSRange] {
        let selections = isColumnMode ? columnCarets.map(\.range) : [selectedRange()]
        return pieces.map(\.range).filter { piece in
            selections.contains { selection in
                selection.length == 0
                    ? piece.location <= selection.location && selection.location <= NSMaxRange(piece)
                    : NSIntersectionRange(piece, selection).length > 0
            }
        }
    }

    /// The piece a caret is in or right next to.
    private func piece(revealedBy selection: NSRange) -> NSRange? {
        pieces.first { $0.range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.range) }?.range
    }

    // A hidden opening quote shares its insertion point with the first visible character.
    func insertionIndexForConceals(_ index: Int) -> Int {
        guard let piece = piece(revealedBy: NSRange(location: index, length: 0)),
              (piece.location..<index).allSatisfy({ conceal(at: $0)?.replacement == 0 }) else { return index }
        return piece.location
    }

    private func reveal(_ pieces: [NSRange]) {
        let shown = Set(pieces)
        let changed = Set(revealedPieces).symmetricDifference(shown)
        guard !changed.isEmpty else { return }
        revealedPieces = shown.sorted { $0.location < $1.location }
        for piece in changed { invalidateGlyphs(in: piece) }
    }

    /// The x the caret keeps while going up and down, and whether it's going so.
    private var verticalGoal: CGFloat?
    private var isMovingVertically = false

    override func moveUp(_ sender: Any?) {
        if !moveVertically(up: true) { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if !moveVertically(up: false) { super.moveDown(sender) }
    }

    /// Up and down past concealed pieces: the caret lands right above or below where it was, as the line looks once
    /// the piece it lands in shows as typed. False leaves it to the text view, e.g. on the first and last line.
    private func moveVertically(up: Bool) -> Bool {
        let selection = selectedRange()
        guard concealsMath, !pieces.isEmpty, !isColumnMode, selection.length == 0, let lm = layoutManager,
              let container = textContainer, let caret = caretRect(at: selection.location) else { return false }
        let x = verticalGoal ?? caret.midX
        let y = up ? caret.minY - 1 : caret.maxY + 1
        let origin = textContainerOrigin
        guard y > origin.y, y < origin.y + lm.usedRect(for: container).maxY else { return false }
        let point = NSPoint(x: x, y: y)
        var index = characterIndexForInsertion(at: point)
        // The piece it lands in shows as typed, which moves what's after it; land where that line has the caret's x.
        if let piece = piece(revealedBy: NSRange(location: index, length: 0)), !revealedPieces.contains(piece) {
            reveal([piece])
            index = characterIndexForInsertion(at: point)
        }
        isMovingVertically = true
        setSelectedRange(NSRange(location: index, length: 0))
        isMovingVertically = false
        verticalGoal = x
        scrollRangeToVisible(NSRange(location: index, length: 0))
        return true
    }

    private func updateOperatorLigatures() {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        let selections = isColumnMode ? columnCarets.map(\.range) : [selectedRange()]
        var changes: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let font = value as? NSFont, font.fontName == "JetBrainsMono-Bold" else { return }
            let original = text.substring(with: range)
            guard original == ":=" || original == "->" else { return }
            let touching = selections.contains { selection in
                [selection.location, NSMaxRange(selection)].contains { range.location < $0 && $0 < NSMaxRange(range) }
            }
            let desired = Highlighter.operatorFont(size: font.pointSize, ligatures: !touching)
            if !font.isEqual(desired) { changes.append((range, desired)) }
        }
        for (range, font) in changes { storage.addAttribute(.font, value: font, range: range) }
    }

    /// Only what differs is laid out again: the lists match at the start, and at the end once shifted by the edit.
    private func invalidateChangedConceals(from old: [Highlighter.Conceal], delta: Int) {
        guard concealsMath else { return }
        let new = conceals
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        func shifted(_ c: Highlighter.Conceal) -> Highlighter.Conceal {
            Highlighter.Conceal(range: NSRange(location: c.range.location + delta, length: c.range.length),
                                replacement: c.replacement,
                                equation: NSRange(location: c.equation.location + delta, length: c.equation.length))
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              shifted(old[old.count - 1 - suffix]) == new[new.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix < max(old.count, new.count) else { return }
        let changed = (new[prefix..<(new.count - suffix)].map(\.equation)
            + old[prefix..<(old.count - suffix)].map { shifted($0).equation })
        guard let start = changed.map(\.location).min(), let end = changed.map(NSMaxRange).max() else { return }
        invalidateGlyphs(in: NSRange(location: start, length: end - start))
    }

    private func invalidateGlyphs(in range: NSRange) {
        guard let lm = layoutManager else { return }
        let length = (string as NSString).length
        let start = min(max(range.location, 0), length)
        let clamped = NSRange(location: start, length: min(max(NSMaxRange(range), start), length) - start)
        lm.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
        needsDisplay = true
    }

    /// The conceal around a character, unless its equation is shown as typed.
    func conceal(at index: Int) -> Highlighter.Conceal? {
        var low = 0, high = conceals.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let c = conceals[mid]
            if index < c.range.location { high = mid - 1 } else if index >= NSMaxRange(c.range) { low = mid + 1 } else {
                return revealedPieces.contains { NSLocationInRange(index, $0) } ? nil : c
            }
        }
        return nil
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard concealsMath, !conceals.isEmpty, glyphRange.length > 0 else { return 0 }
        var newGlyphs: [CGGlyph]?
        var newProperties: [NSLayoutManager.GlyphProperty] = []
        // A symbol the font can't draw keeps its name.
        var symbolGlyphs: [Int: CGGlyph] = [:]
        for i in 0..<glyphRange.length {
            let index = characterIndexes[i]
            guard let c = conceal(at: index) else { continue }
            var glyph: CGGlyph = 0
            if c.replacement != 0 {
                if let known = symbolGlyphs[c.range.location] { glyph = known } else {
                    var character = c.replacement
                    if !CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) { glyph = 0 }
                    symbolGlyphs[c.range.location] = glyph
                }
                if glyph == 0 { continue }
            }
            if newGlyphs == nil {
                newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
                newProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            }
            if c.replacement != 0, index == c.range.location {
                newGlyphs?[i] = glyph
                newProperties[i] = []
            } else {
                newProperties[i] = .null
            }
        }
        guard let newGlyphs else { return 0 }
        layoutManager.setGlyphs(newGlyphs, properties: newProperties, characterIndexes: characterIndexes, font: font,
                                forGlyphRange: glyphRange)
        return glyphRange.length
    }

    var findMatches: [NSRange] = [] {
        didSet { if findMatches != oldValue { needsDisplay = true } }
    }
    var currentFindMatch: NSRange? {
        didSet { if currentFindMatch != oldValue { needsDisplay = true } }
    }
    /// The symbol being renamed inline and its other uses.
    var renameRanges: [NSRange] = [] {
        didSet { if renameRanges != oldValue { needsDisplay = true } }
    }
    var renamePrimary: NSRange? {
        didSet { if renamePrimary != oldValue { needsDisplay = true } }
    }
    var onRename: (() -> Void)?
    var onExtractVariable: (() -> Void)?
    /// True picks the scope the function goes into.
    var onExtractFunction: ((Bool) -> Void)?
    var onInlineVariable: (() -> Void)?
    var onResign: (() -> Void)?
    var onPointerMoved: ((NSPoint) -> Void)?
    var onPointerExited: (() -> Void)?
    /// Clicks close the docs popup.
    var onDismissHover: (() -> Void)?
    /// Uses of the symbol under the caret.
    var occurrences: [NSRange] = [] {
        didSet { if occurrences != oldValue { needsDisplay = true } }
    }
    /// The bracket or quote next to the caret and its partner.
    var brackets: [NSRange] = [] {
        didSet { if brackets != oldValue { needsDisplay = true } }
    }
    /// Carets and selections of other devices editing the same file.
    var remoteCursors: [RemoteCursor] = [] {
        didSet { if remoteCursors != oldValue { needsDisplay = true } }
    }

    // MARK: Wrap guide

    static let wrapColumns = 20...400

    var wrapColumn = 0 {
        didSet { if wrapColumn != oldValue { updateWrapWidth() } }
    }
    /// Reports a column picked by ⌘-dragging the guide.
    var onWrapColumnChange: ((Int) -> Void)?
    private var isDraggingGuide = false
    /// ⌘ is down with the pointer on the guide, so it shows it can be dragged.
    private var guideHovered = false {
        didSet { if guideHovered != oldValue { needsDisplay = true } }
    }

    override var font: NSFont? {
        didSet { updateWrapWidth() }
    }

    var columnWidth: CGFloat {
        let font = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }

    private var guideX: CGFloat? {
        guard wrapColumn > 0, let container = textContainer else { return nil }
        return textContainerOrigin.x + container.lineFragmentPadding + CGFloat(wrapColumn) * columnWidth
    }

    /// Wraps at the guide, or at the edge when the view is narrower.
    private func updateWrapWidth() {
        guard let container = textContainer else { return }
        let available = max(bounds.width - textContainerInset.width * 2, 50)
        if wrapColumn > 0 {
            container.widthTracksTextView = false
            let width = min(container.lineFragmentPadding * 2 + CGFloat(wrapColumn) * columnWidth, available)
            if container.size.width != width { container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
        } else if !container.widthTracksTextView {
            container.widthTracksTextView = true
            container.size = NSSize(width: available, height: CGFloat.greatestFiniteMagnitude)
        }
        needsDisplay = true
    }

    private func isOnGuide(_ point: NSPoint, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command), let x = guideX else { return false }
        return abs(point.x - x) <= 5
    }

    /// ⌘-drag moves the guide a column at a time.
    private func dragGuide(from event: NSEvent) {
        guard let window, let container = textContainer else { return }
        isDraggingGuide = true
        defer {
            isDraggingGuide = false
            needsDisplay = true
        }
        NSCursor.resizeLeftRight.set()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let x = convert(next.locationInWindow, from: nil).x - textContainerOrigin.x - container.lineFragmentPadding
            let column = min(max(Int((x / columnWidth).rounded()), Self.wrapColumns.lowerBound), Self.wrapColumns.upperBound)
            if column != wrapColumn {
                wrapColumn = column
                onWrapColumnChange?(column)
            }
            if next.type == .leftMouseUp { break }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        // Holding ⌘ over the guide shows it can be dragged; other modifiers leave the pointer alone.
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let point = convert(windowPoint, from: nil)
        let inside = visibleRect.contains(point)
        guideHovered = inside && isOnGuide(point, flags: event.modifierFlags)
        guard inside, markers?.isOnScroller(atWindowPoint: windowPoint) != true else { return }
        if let overlay = CursorArea.cursor(in: window, at: windowPoint) {
            overlay.set()
        } else if guideHovered {
            NSCursor.resizeLeftRight.set()
        } else if swatch(at: point) != nil {
            NSCursor.pointingHand.set()
        } else if columnSelectionMode {
            NSCursor.crosshair.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    // MARK: Gliding caret

    /// Draws its own caret that slides to each new position instead of jumping.
    var glidingCaret = false {
        didSet { if glidingCaret != oldValue { updateCaret(animated: false) } }
    }
    private let caretView = CaretView()
    var vim: VimEngine? {
        didSet { updateCaret(animated: false) }
    }
    /// Gliding, Vim's block caret and every caret of a column selection are drawn by this view instead of AppKit.
    private var ownsCaret: Bool { isColumnMode || glidingCaret || vim?.blockCaret == true }
    func refreshCaret(animated: Bool = false) { updateCaret(animated: animated) }

    private final class CaretView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if !ownsCaret { super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        updateCaret(animated: true)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        updateCaret(animated: false)
        return became
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if wrapColumn > 0 { updateWrapWidth() }
        updateCaret(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCaret(animated: false)
    }

    private func updateCaret(animated: Bool) {
        guard !isUpdatingColumns else { return }
        // Newer AppKit draws the caret with an indicator subview rather than drawInsertionPoint.
        for case let indicator as NSTextInsertionIndicator in subviews {
            indicator.displayMode = ownsCaret ? .hidden : .automatic
        }
        if !isColumnMode, !columnCaretViews.isEmpty {
            for view in columnCaretViews { view.removeFromSuperview() }
            columnCaretViews = []
            columnCaretHeads = []
        }
        guard ownsCaret, window?.firstResponder === self, window?.isKeyWindow == true else {
            caretView.isHidden = true
            for view in columnCaretViews { view.isHidden = true }
            return
        }
        if isColumnMode {
            caretView.isHidden = true
            return updateColumnCarets(animated: animated)
        }
        let selection = selectedRange()
        guard selection.length == 0, let rect = caretRect(at: selection.location) else {
            caretView.isHidden = true
            return
        }
        if caretView.superview !== self {
            caretView.wantsLayer = true
            caretView.layer?.cornerRadius = 1
            addSubview(caretView)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            caretView.layer?.backgroundColor = insertionPointColor.withAlphaComponent(vim?.blockCaret == true ? 0.4 : 1).cgColor
        }
        let wasHidden = caretView.isHidden
        caretView.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !wasHidden && glidingCaret ? 0.09 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            caretView.animator().frame = vim?.blockCaret == true ? vimBlockRect(rect, at: selection.location) : rect
        }
        restartBlink()
    }

    /// A view per caret, at the end of its selection; reused so they glide instead of jumping.
    private var columnCaretViews: [CaretView] = []
    /// The head each view last showed, to match views to carets when lines are added above.
    private var columnCaretHeads: [Int] = []

    private func updateColumnCarets(animated: Bool) {
        var unusedViews = columnCaretViews
        var unusedHeads = columnCaretHeads
        var views: [CaretView] = []
        var isNew: [Bool] = []
        for caret in columnCarets {
            let match: Int?
            if let exact = unusedHeads.firstIndex(of: caret.head) {
                match = exact
            } else {
                match = unusedHeads.indices.min { abs(unusedHeads[$0] - caret.head) < abs(unusedHeads[$1] - caret.head) }
            }
            if let match {
                views.append(unusedViews.remove(at: match))
                unusedHeads.remove(at: match)
                isNew.append(false)
            } else {
                let view = CaretView()
                view.wantsLayer = true
                view.layer?.cornerRadius = 1
                view.isHidden = true
                addSubview(view)
                views.append(view)
                isNew.append(true)
            }
        }
        for view in unusedViews { view.removeFromSuperview() }
        columnCaretViews = views
        columnCaretHeads = columnCarets.map(\.head)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for view in columnCaretViews { view.layer?.backgroundColor = insertionPointColor.cgColor }
        }
        for (i, caret) in columnCarets.enumerated() {
            let view = columnCaretViews[i]
            guard let rect = caretRect(at: caret.head) else {
                view.isHidden = true
                continue
            }
            if isNew[i] {
                // A caret that wasn't there yet appears where it is instead of flying in from the corner.
                view.frame = rect
                view.isHidden = false
                continue
            }
            let wasHidden = view.isHidden
            view.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated && !wasHidden && glidingCaret ? 0.09 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                view.animator().frame = rect
            }
        }
        restartBlink()
    }

    /// Solid while moving, then blinking like the system caret.
    private func restartBlink() {
        for view in [caretView] + columnCaretViews {
            guard let layer = view.layer else { continue }
            layer.removeAnimation(forKey: "blink")
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 1, 0, 0, 1]
            blink.keyTimes = [0, 0.45, 0.55, 0.95, 1]
            blink.duration = 1.05
            blink.repeatCount = .infinity
            blink.beginTime = CACurrentMediaTime() + 0.5
            layer.add(blink, forKey: "blink")
        }
    }

    private func caretRect(at caret: Int) -> NSRect? {
        guard let lm = layoutManager, let container = textContainer else { return nil }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        var line: NSRect
        var x: CGFloat
        lm.ensureLayout(for: container)
        if caret >= length, length == 0 || lm.extraLineFragmentTextContainer != nil {
            line = lm.extraLineFragmentRect
            if line.isEmpty { line = NSRect(x: 0, y: 0, width: 0, height: font.map { lm.defaultLineHeight(for: $0) } ?? 16) }
            x = line.minX + container.lineFragmentPadding
        } else if caret >= length {
            let glyph = lm.glyphIndexForCharacter(at: length - 1)
            line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
        } else {
            let glyph = lm.glyphIndexForCharacter(at: caret)
            line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = line.minX + lm.location(forGlyphAt: glyph).x
        }
        return NSRect(x: origin.x + x - 1, y: origin.y + line.minY, width: 2, height: line.height).integral
    }

    static func swatchSize(for font: NSFont?) -> CGFloat { ((font?.pointSize ?? 13) * 0.8).rounded() }
    /// Space kerned in before a color literal for its swatch.
    static func swatchGap(for font: NSFont?) -> CGFloat { swatchSize(for: font) + 5 }

    // MARK: Zooming

    static let fontSizes = 9.0...32.0
    private var zoomDelta: CGFloat = 0

    /// ⌘-scroll changes the editor font size, like ⌘+ and ⌘- in browsers.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else {
            return super.scrollWheel(with: event)
        }
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .began { zoomDelta = 0 }
        // Trackpads report points, wheels report lines.
        zoomDelta += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        let steps = zoomDelta.rounded(.towardZero)
        guard steps != 0 else { return }
        zoomDelta -= steps
        let defaults = UserDefaults.standard
        let size = defaults.object(forKey: "editorFontSize") as? Double ?? 14
        let next = min(max(size + Double(steps), Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        if next != size { defaults.set(next, forKey: "editorFontSize") }
    }

    // NSTextView sets the I-beam on every move, even under floating controls.
    override func mouseMoved(with event: NSEvent) {
        guideHovered = isOnGuide(convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
        if let cursor = cursor(for: event) {
            cursor.set()
        } else {
            super.mouseMoved(with: event)
            // ⌥ must not let AppKit swap in its column-selection pointer.
            NSCursor.iBeam.set()
        }
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    private var pointerArea: NSTrackingArea?

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guideHovered = false
        onPointerExited?()
    }

    func highlightBoxes(for range: NSRange) -> [NSRect] {
        guard let lm = layoutManager, let container = textContainer,
              range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else { return [] }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var boxes: [NSRect] = []
        for glyph in glyphs.location..<NSMaxRange(glyphs) {
            let index = lm.characterIndexForGlyph(at: glyph)
            guard index < NSMaxRange(range),
                  index >= range.location || conceal(at: range.location)?.range.location == index else { continue }
            // Null glyphs retain source bounds even though their quotes or spelling are hidden.
            guard !lm.propertyForGlyph(at: glyph).contains(.null) else { continue }
            let box = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard box.width > 0 else { continue }
            if let last = boxes.last, last.minY == box.minY, last.height == box.height {
                boxes[boxes.count - 1] = last.union(box)
            } else {
                boxes.append(box)
            }
        }
        return boxes.map { $0.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y) }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawSelections(in: rect)
        if let x = guideX, x < bounds.maxX {
            let active = isDraggingGuide || guideHovered
            (active ? NSColor.controlAccentColor.withAlphaComponent(0.7) : NSColor.separatorColor).setFill()
            NSRect(x: x.rounded(), y: rect.minY, width: active ? 2 : 1, height: rect.height).fill()
        }
        func boxes(_ ranges: [NSRange]) -> [NSRect] {
            ranges.flatMap { highlightBoxes(for: $0) }
        }
        let length = (string as NSString).length
        // Only the visible part of a long match list is measured.
        let visible = layoutManager.flatMap { lm in textContainer.map { lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: $0),
            actualGlyphRange: nil) } } ?? NSRange(location: 0, length: length)
        let shown = findMatches.filter { NSIntersectionRange($0, visible).length > 0 || NSLocationInRange($0.location, visible) }
        for box in boxes(shown) where box.intersects(rect) {
            NSColor.systemYellow.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
        if let current = currentFindMatch, let box = boxes([current]).first, box.intersects(rect) {
            NSColor.systemYellow.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
        for (range, box) in renameRanges.flatMap({ range in highlightBoxes(for: range).map { (range, $0) } }) where box.intersects(rect) {
            let primary = range == renamePrimary
            let path = NSBezierPath(roundedRect: box.insetBy(dx: -1.5, dy: 0.5), xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.withAlphaComponent(primary ? 0.18 : 0.1).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(primary ? 0.9 : 0.5).setStroke()
            path.lineWidth = primary ? 1.5 : 1
            path.stroke()
        }
        for box in boxes(occurrences) where box.intersects(rect) {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
        for box in boxes(brackets) where box.intersects(rect) {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: -0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        (cursor(for: event) ?? .iBeam).set()
    }

    private func cursor(for event: NSEvent) -> NSCursor? {
        if let cursor = CursorArea.cursor(for: event) { return cursor }
        if markers?.isOnScroller(atWindowPoint: event.locationInWindow) == true { return .arrow }
        if isOnGuide(convert(event.locationInWindow, from: nil), flags: event.modifierFlags) { return .resizeLeftRight }
        if columnSelectionMode {
            return bounds.contains(convert(event.locationInWindow, from: nil)) ? .crosshair : nil
        }
        return swatch(at: convert(event.locationInWindow, from: nil)) != nil ? .pointingHand : nil
    }

    private func swatch(at point: NSPoint) -> ColorLiteral? {
        swatches.first { swatchRect(for: $0)?.insetBy(dx: -2, dy: -2).contains(point) == true }
    }

    func swatchRect(for literal: ColorLiteral) -> NSRect? {
        guard let lm = layoutManager, literal.range.location > 0, NSMaxRange(literal.range) <= (string as NSString).length else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: literal.range.location)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = lm.location(forGlyphAt: glyph).x
        let size = Self.swatchSize(for: font)
        let origin = textContainerOrigin
        return NSRect(x: origin.x + line.minX + x - size - 2.5, y: origin.y + line.midY - size / 2, width: size, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCollapsedSegmentUnderlines(in: dirtyRect)
        drawRemoteCursors(in: dirtyRect)
        for literal in swatches {
            guard let rect = swatchRect(for: literal), rect.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            // Translucent colors show over white, like a color well.
            NSColor.white.setFill()
            path.fill()
            literal.color.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Each device's selection tinted in its color, a caret and its name above it.
    private func drawRemoteCursors(in dirtyRect: NSRect) {
        guard let lm = layoutManager, let container = textContainer else { return }
        let length = (string as NSString).length
        let label = NSFont.systemFont(ofSize: 9, weight: .semibold)
        for cursor in remoteCursors where NSMaxRange(cursor.range) <= length {
            let color = cursor.color
            if cursor.range.length > 0 {
                color.withAlphaComponent(0.2).setFill()
                let glyphs = lm.glyphRange(forCharacterRange: cursor.range, actualCharacterRange: nil)
                lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                    rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).fill()
                }
            }
            guard let caret = caretRect(at: NSMaxRange(cursor.range)) else { continue }
            let bar = NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height)
            guard bar.insetBy(dx: -150, dy: -20).intersects(dirtyRect) else { continue }
            color.setFill()
            bar.fill()
            let name = NSAttributedString(string: cursor.name, attributes: [.font: label, .foregroundColor: NSColor.white])
            let size = name.size()
            let tag = NSRect(x: caret.minX, y: caret.minY - size.height - 1, width: size.width + 8, height: size.height + 1)
            NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
            name.draw(at: NSPoint(x: tag.minX + 4, y: tag.minY + 0.5))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) { return hit }
        // AppKit excludes the area beyond a fixed-width text container.
        guard wrapColumn > 0, !isHiddenOrHasHiddenAncestor, let superview,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onDismissHover?()
        let point = convert(event.locationInWindow, from: nil)
        if let literal = swatch(at: point) {
            onSwatchClick?(literal)
            return
        }
        if isOnGuide(point, flags: event.modifierFlags) { return dragGuide(from: event) }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.clickCount == 1, modifiers == .option || columnSelectionMode && modifiers.isEmpty {
            return dragColumns(from: event)
        }
        if event.clickCount == 1, modifiers == [.option, .shift] || modifiers == [.control, .shift] {
            window?.makeFirstResponder(self)
            return toggleCaret(at: characterIndexForInsertion(at: point))
        }
        if event.modifierFlags.contains(.command), event.clickCount == 1, let onDefinition {
            let index = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: index, length: 0))
            onDefinition(index)
            return
        }
        let before = selectedRange().location
        isSelectingWithMouse = true
        defer {
            isSelectingWithMouse = false
            updateRevealedEquation()
            refreshCaret()
        }
        super.mouseDown(with: event)
        if let onJump, Self.isFar(before, selectedRange().location, in: string as NSString) { onJump(before) }
    }

    /// More than a screenful apart, roughly; nearer moves aren't worth going back to.
    private static func isFar(_ a: Int, _ b: Int, in s: NSString) -> Bool {
        let range = NSRange(location: min(a, b, s.length), length: min(abs(a - b), max(s.length - min(a, b), 0)))
        var lines = 0
        s.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, _, _, stop in
            lines += 1
            if lines > 20 { stop.pointee = true }
        }
        return lines > 20
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        Popups.onDismiss(menu, in: window) { $0.cancelTrackingWithoutAnimation() }
        if let workspace = (window?.windowController as? MainWindowController)?.state.workspace,
           let file = workspace.selectedFile, FileHistory.isAvailable(for: file), selectedRange().length > 0 {
            let history = NSMenuItem(title: "Show History for Selection…", action: #selector(showSelectionHistory(_:)), keyEquivalent: "")
            history.target = self
            menu.addItem(.separator())
            menu.addItem(history)
        }
        guard onDefinition != nil else { return menu }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let item = NSMenuItem(title: "Go to Definition", action: #selector(goToDefinition(_:)), keyEquivalent: "b")
        item.target = self
        item.representedObject = index
        let rename = NSMenuItem(title: "Rename Symbol…", action: #selector(renameSymbol(_:)), keyEquivalent: String(UnicodeScalar(NSF6FunctionKey)!))
        rename.keyEquivalentModifierMask = .shift
        rename.target = self
        let format = NSMenuItem(title: "Format Document", action: #selector(formatDocument(_:)), keyEquivalent: "l")
        format.keyEquivalentModifierMask = [.command, .option]
        format.target = self
        var entries = [item, rename, format]
        if onExtractVariable != nil {
            let extract = NSMenuItem(title: "Extract Variable…", action: #selector(extractVariable(_:)), keyEquivalent: "v")
            extract.keyEquivalentModifierMask = [.command, .option]
            extract.target = self
            let inline = NSMenuItem(title: "Inline Variable", action: #selector(inlineVariable(_:)), keyEquivalent: "n")
            inline.keyEquivalentModifierMask = [.command, .option]
            inline.target = self
            let function = NSMenuItem(title: "Extract Function…", action: #selector(extractFunction(_:)), keyEquivalent: "m")
            function.keyEquivalentModifierMask = [.command, .option]
            function.target = self
            let scoped = NSMenuItem(title: "Extract Function to Scope…", action: #selector(extractFunctionToScope(_:)),
                                    keyEquivalent: "m")
            scoped.keyEquivalentModifierMask = [.command, .option, .shift]
            scoped.target = self
            entries += [extract, function, scoped, inline]
        }
        entries.append(.separator())
        if hasQuickFixes?(index) == true {
            let fix = NSMenuItem(title: "Show Context Actions…", action: #selector(showFixes(_:)), keyEquivalent: "\r")
            fix.keyEquivalentModifierMask = .option
            fix.target = self
            fix.representedObject = index
            entries.insert(fix, at: 0)
        }
        for (i, entry) in entries.enumerated() { menu.insertItem(entry, at: i) }
        return menu
    }

    @objc private func renameSymbol(_ sender: Any?) { onRename?() }
    @objc private func extractVariable(_ sender: Any?) { onExtractVariable?() }
    @objc private func inlineVariable(_ sender: Any?) { onInlineVariable?() }
    @objc private func extractFunction(_ sender: Any?) { onExtractFunction?(false) }
    @objc private func extractFunctionToScope(_ sender: Any?) { onExtractFunction?(true) }

    /// Where menus and messages about the caret appear, below it.
    func caretAnchor() -> NSRect {
        caretRect(at: selectedRange().location) ?? NSRect(x: 0, y: 0, width: 2, height: 16)
    }

    @objc private func showFixes(_ sender: NSMenuItem) {
        if let index = sender.representedObject as? Int { onQuickFix?(index) }
    }

    // The Edit menu's Undo and Redo reach the text view first, so a rename's own history wins there too.
    @objc func undo(_ sender: Any?) {
        if (window?.windowController as? MainWindowController)?.state.undoDeletion() == true { return }
        if onUndo?() != true {
            (undoManager as? ActionUndoManager)?.checkpoint()
            let files = (window?.windowController as? MainWindowController)?.state.undoManager
            files?.checkpoint()
            ActionUndoManager.preferred([undoManager, files], redo: false)?.undo()
        }
        onDidUndo?(false, string)
    }

    @objc func redo(_ sender: Any?) {
        if onRedo?() != true {
            let files = (window?.windowController as? MainWindowController)?.state.undoManager
            ActionUndoManager.preferred([undoManager, files], redo: true)?.redo()
        }
        onDidUndo?(true, string)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            return (window?.windowController as? MainWindowController)?.state.deletionNotice != nil
                || onUndo != nil && isRenaming || undoManager?.canUndo == true
                || (window?.windowController as? MainWindowController)?.state.undoManager.canUndo == true
        }
        if item.action == #selector(redo(_:)) {
            return onRedo != nil && isRenaming || undoManager?.canRedo == true
                || (window?.windowController as? MainWindowController)?.state.undoManager.canRedo == true
        }
        if item.action == #selector(copy(_:)) { return isSelectable }
        if item.action == #selector(cut(_:)) { return isEditable && !string.isEmpty }
        // A plain text view doesn't read images, so Paste would stay disabled for them.
        if item.action == #selector(paste(_:)), isEditable, onPasteImage != nil,
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        return super.validateMenuItem(item)
    }

    /// Set while an inline rename runs.
    var isRenaming: Bool { renamePrimary != nil }

    /// The Edit menu's Find items land here too.
    override func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let onFind, let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag) else { return super.performTextFinderAction(sender) }
        switch action {
        case .showFindInterface, .setSearchString: onFind(false)
        case .showReplaceInterface, .replace, .replaceAll, .replaceAndFind: onFind(true)
        case .nextMatch: onFindStep?(1)
        case .previousMatch: onFindStep?(-1)
        default: super.performTextFinderAction(sender)
        }
    }
    @objc private func showSelectionHistory(_ sender: Any?) {
        guard let workspace = (window?.windowController as? MainWindowController)?.state.workspace,
              let file = workspace.selectedFile, let lines = FileHistory.selectedLines(in: workspace) else { return }
        FileHistory.show(file, in: workspace, selectedLines: lines)
    }

    @objc private func formatDocument(_ sender: Any?) { onFormat?() }

    @objc private func goToDefinition(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onDefinition?(index)
    }

    /// Option-Escape (and Control-Space below) ask the language server instead of the spell checker.
    override func complete(_ sender: Any?) {
        if let onComplete { onComplete() } else { super.complete(sender) }
    }

    /// ⌘B jumps to the definition at the caret, ⌥⌘L formats, ⇧F6 renames.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Z
        if event.keyCode == 6, flags == .command, onUndo?() == true {
            onDidUndo?(false, string)
            return true
        }
        if event.keyCode == 6, flags == [.command, .shift], onRedo?() == true {
            onDidUndo?(true, string)
            return true
        }
        let keys = KeyLayout.current.shortcuts
        if keys.find.matches(event), let onFind {
            onFind(false)
            return true
        }
        if keys.replace.matches(event), let onFind {
            onFind(true)
            return true
        }
        if keys.findNext.matches(event), let onFindStep {
            onFindStep(1)
            return true
        }
        if keys.findPrevious.matches(event), let onFindStep {
            onFindStep(-1)
            return true
        }
        if keys.definition.matches(event), let onDefinition {
            onDefinition(selectedRange().location)
            return true
        }
        if keys.format.matches(event), let onFormat {
            onFormat()
            return true
        }
        if keys.rename.matches(event), let onRename {
            onRename()
            return true
        }
        if keys.extractVariable.matches(event), let onExtractVariable {
            onExtractVariable()
            return true
        }
        if keys.inlineVariable.matches(event), let onInlineVariable {
            onInlineVariable()
            return true
        }
        if keys.extractFunction.matches(event), let onExtractFunction {
            onExtractFunction(false)
            return true
        }
        if keys.extractFunctionToScope.matches(event), let onExtractFunction {
            onExtractFunction(true)
            return true
        }
        // ⌘D duplicates, ⌘⌫ deletes the line, like IntelliJ.
        if keys.duplicateLine.matches(event), isEditable {
            duplicateLine()
            return true
        }
        if keys.deleteLine.matches(event), isEditable {
            deleteLine()
            return true
        }
        if keys.commentLine.matches(event), comments != nil, isEditable {
            toggleLineComment()
            return true
        }
        if keys.commentBlock.matches(event), comments != nil, isEditable {
            toggleBlockComment()
            return true
        }
        if keys.columnSelection.matches(event) {
            columnSelectionMode.toggle()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Duplicates the selection, or the caret's line when nothing is selected.
    func duplicateLine() {
        let selections = currentCarets.map { LineSelection(anchor: Int32($0.anchor), head: Int32($0.head)) }
        applyLineChange(duplicateSelectedLines(selections: selections, text: string), action: "Duplicate Line")
    }

    /// Swaps the lines the selection touches with the line above or below; the selection moves along.
    func moveLines(up: Bool) {
        let selections = currentCarets.map { LineSelection(anchor: Int32($0.anchor), head: Int32($0.head)) }
        applyLineChange(moveSelectedLines(selections: selections, up: up, text: string),
                        action: up ? "Move Line Up" : "Move Line Down")
    }

    /// Deletes the lines the selection touches, keeping the caret's column on the next line.
    func deleteLine() {
        let selections = currentCarets.map { LineSelection(anchor: Int32($0.anchor), head: Int32($0.head)) }
        applyLineChange(deleteSelectedLines(selections: selections, text: string), action: "Delete Line")
    }

    // MARK: Comments

    /// Comments the lines the selection touches, or takes the markers away again; ⌘7 in the IntelliJ layout.
    func toggleLineComment() {
        guard let comments, isEditable else { return NSSound.beep() }
        let s = string as NSString
        let selection = selectedRange()
        let block = s.lineRange(for: Self.touched(selection, in: s))
        let marker = comments.lineMarker
        let suffix = comments.lineSuffixMarker

        struct Line {
            let start: Int
            let end: Int
            let blank: Bool
            let commented: Bool
        }
        let lines: [Line] = Self.lineRanges(in: block, of: s).map { line in
            let end = Self.bodyEnd(of: line, in: s)
            var start = line.location
            while start < end, s.character(at: start) == 32 || s.character(at: start) == 9 { start += 1 }
            let text = s.substring(with: NSRange(location: start, length: end - start))
            let blank = text.trimmingCharacters(in: .whitespaces).isEmpty
            let commented = !blank && text.hasPrefix(marker)
                && (suffix.isEmpty || text.trimmingCharacters(in: .whitespaces).hasSuffix(suffix))
            return Line(start: start, end: end, blank: blank, commented: commented)
        }
        let uncomment = lines.contains { !$0.blank } && lines.allSatisfy { $0.blank || $0.commented }

        var edits: [CommentEdit] = []
        for line in lines where !line.blank {
            if uncomment {
                let markerLength = (marker as NSString).length
                let space = line.start + markerLength < s.length && s.character(at: line.start + markerLength) == 32 ? 1 : 0
                edits.append(CommentEdit(at: line.start, remove: markerLength + space, insert: ""))
                if !suffix.isEmpty {
                    let length = (suffix as NSString).length
                    let space = line.end - length > line.start && s.character(at: line.end - length - 1) == 32 ? 1 : 0
                    edits.append(CommentEdit(at: line.end - length - space, remove: length + space, insert: ""))
                }
            } else {
                edits.append(CommentEdit(at: line.start, remove: 0, insert: comments.linePrefix))
                if !suffix.isEmpty {
                    edits.append(CommentEdit(at: line.end, remove: 0, insert: comments.lineSuffix))
                }
            }
        }
        // An empty file or a line of only spaces gets an empty comment at the caret.
        guard !edits.isEmpty else {
            let at = selection.location
            return replace(NSRange(location: at, length: 0), with: comments.linePrefix + comments.lineSuffix,
                           select: NSRange(location: at + (comments.linePrefix as NSString).length, length: 0),
                           action: "Comment Lines")
        }
        applyCommentEdits(edits, in: block, action: uncomment ? "Uncomment Lines" : "Comment Lines")
    }

    /// Wraps the selection, or the caret's line, in block markers; ⇧⌘7 in the IntelliJ layout.
    func toggleBlockComment() {
        guard let comments, isEditable else { return NSSound.beep() }
        let s = string as NSString
        let selection = selectedRange()
        let prefix = comments.blockPrefix
        let suffix = comments.blockSuffix
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        let regions = prefix == "/*" ? Highlighter.runs(in: string).filter { $0.tag == .comment }.map(\.range)
            : [NSRange(location: 0, length: s.length)]
        if let enclosing = enclosingBlockComment(
            selection: TypewrightCore.TextRange(location: Int32(selection.location), length: Int32(selection.length)),
            text: string, prefix: prefix, suffix: suffix,
            regions: regions.map { TypewrightCore.TextRange(location: Int32($0.location), length: Int32($0.length)) }
        ) {
            let block = NSRange(location: Int(enclosing.location), length: Int(enclosing.length))
            return applyCommentEdits([CommentEdit(at: block.location, remove: prefixLength, insert: ""),
                                      CommentEdit(at: NSMaxRange(block) - suffixLength, remove: suffixLength, insert: "")],
                                     in: block, action: "Uncomment Block")
        }

        if selection.length > 0 {
            let text = s.substring(with: selection) as NSString
            var start = 0, end = text.length
            while start < end, Self.isSpace(text.character(at: start)) { start += 1 }
            while end > start, Self.isSpace(text.character(at: end - 1)) { end -= 1 }
            let core = text.substring(with: NSRange(location: start, length: end - start)) as NSString
            if core.length >= prefixLength + suffixLength, core.hasPrefix(prefix), core.hasSuffix(suffix) {
                let inner = core.substring(with: NSRange(location: prefixLength, length: core.length - prefixLength - suffixLength))
                let replacement = text.substring(to: start) + inner + text.substring(from: end)
                replace(selection, with: replacement, select: NSRange(location: selection.location + start, length: (inner as NSString).length),
                        action: "Uncomment Block")
            } else if selection.location >= prefixLength, NSMaxRange(selection) + suffixLength <= s.length,
                      s.substring(with: NSRange(location: selection.location - prefixLength, length: prefixLength)) == prefix,
                      s.substring(with: NSRange(location: NSMaxRange(selection), length: suffixLength)) == suffix {
                // The markers around the selection are the ones commenting it.
                let block = NSRange(location: selection.location - prefixLength,
                                    length: prefixLength + selection.length + suffixLength)
                replace(block, with: text as String,
                        select: NSRange(location: block.location, length: selection.length), action: "Uncomment Block")
            } else {
                replace(selection, with: prefix + (text as String) + suffix,
                        select: NSRange(location: selection.location + prefixLength, length: selection.length), action: "Comment Block")
            }
            return
        }

        // The caret's line, between its indentation and its line break.
        let line = s.lineRange(for: NSRange(location: min(selection.location, s.length), length: 0))
        let end = Self.bodyEnd(of: line, in: s)
        var start = line.location
        while start < end, s.character(at: start) == 32 || s.character(at: start) == 9 { start += 1 }
        guard start < end else {
            return replace(NSRange(location: start, length: 0), with: prefix + suffix,
                           select: NSRange(location: start + prefixLength, length: 0), action: "Comment Block")
        }
        let body = s.substring(with: NSRange(location: start, length: end - start)) as NSString
        let block = NSRange(location: start, length: end - start)
        if body.length >= prefixLength + suffixLength, body.hasPrefix(prefix), body.hasSuffix(suffix) {
            applyCommentEdits([CommentEdit(at: start, remove: prefixLength, insert: ""),
                               CommentEdit(at: end - suffixLength, remove: suffixLength, insert: "")],
                              in: block, action: "Uncomment Block")
        } else {
            applyCommentEdits([CommentEdit(at: start, remove: 0, insert: prefix),
                               CommentEdit(at: end, remove: 0, insert: suffix)],
                              in: block, action: "Comment Block")
        }
    }

    private struct CommentEdit {
        let at: Int
        let remove: Int
        let insert: String
    }

    /// Applies the edits of a commented block and keeps the selection on the same text.
    private func applyCommentEdits(_ edits: [CommentEdit], in block: NSRange, action: String) {
        let s = string as NSString
        var text = s.substring(with: block) as NSString
        for edit in edits.sorted(by: { $0.at > $1.at }) {
            let range = NSRange(location: edit.at - block.location, length: edit.remove)
            text = text.replacingCharacters(in: range, with: edit.insert) as NSString
        }
        guard text as String != s.substring(with: block) else { return }
        let selection = selectedRange()
        func moved(_ offset: Int) -> Int {
            // Edits are at absolute offsets of the old text, so the shift adds up separately.
            var delta = 0
            for edit in edits.sorted(by: { $0.at < $1.at }) {
                let end = edit.at + edit.remove
                let inserted = (edit.insert as NSString).length
                if edit.remove == 0 {
                    if offset >= edit.at { delta += inserted }
                } else if offset >= end {
                    delta += inserted - edit.remove
                } else if offset > edit.at {
                    return edit.at + inserted + delta
                }
            }
            return offset + delta
        }
        let start = moved(selection.location)
        let end = moved(NSMaxRange(selection))
        replace(block, with: text as String, select: NSRange(location: start, length: max(0, end - start)), action: action)
    }

    /// A selection ending at a line start leaves that line alone.
    private static func touched(_ selection: NSRange, in s: NSString) -> NSRange {
        guard selection.length > 0, NSMaxRange(selection) <= s.length else { return selection }
        let last = s.character(at: NSMaxRange(selection) - 1)
        return last == 10 || last == 13 ? NSRange(location: selection.location, length: selection.length - 1) : selection
    }

    /// The full lines of a block, including their breaks; one empty line when the block is empty.
    private static func lineRanges(in block: NSRange, of s: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        var at = block.location
        while at < NSMaxRange(block) {
            let line = s.lineRange(for: NSRange(location: at, length: 0))
            guard line.length > 0 else { break }
            lines.append(line)
            at = NSMaxRange(line)
        }
        return lines.isEmpty ? [NSRange(location: min(block.location, s.length), length: 0)] : lines
    }

    /// Where a line's text ends, without its line break.
    private static func bodyEnd(of line: NSRange, in s: NSString) -> Int {
        var end = NSMaxRange(line)
        if end > line.location, s.character(at: end - 1) == 10 { end -= 1 }
        if end > line.location, s.character(at: end - 1) == 13 { end -= 1 }
        return end
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 32 || c == 9 || c == 10 || c == 13
    }

    private func replace(_ range: NSRange, with text: String, select: NSRange, action: String) {
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: text) else { return }
        replaceCharacters(in: range, with: text)
        didChangeText()
        undoManager?.setActionName(action)
        setSelectedRange(select)
        scrollRangeToVisible(select)
    }

    override func keyDown(with event: NSEvent) {
        let keys = KeyLayout.current.shortcuts
        // F1 shows, pins or hides the docs, of the selected completion when the list is open.
        if keys.documentation.matches(event), let onShowDocs { return onShowDocs() }
        if let vim, vim.handle(event) { return }
        // ⌥↩ shows the fixes for the problem at the caret.
        if keys.contextActions.matches(event), let onQuickFix {
            return onQuickFix(selectedRange().location)
        }
        if keys.rename.matches(event), let onRename { return onRename() }
        // ⌥⇧↑ and ⌥⇧↓ move the lines, like IntelliJ.
        if keys.moveLineUp.matches(event), isEditable { return moveLines(up: true) }
        if keys.moveLineDown.matches(event), isEditable { return moveLines(up: false) }
        if let command = Self.lineKeyCommand(for: event) { return doCommand(by: command) }
        if keys.addCaretAbove.matches(event) { return addCaret(up: true) }
        if keys.addCaretBelow.matches(event) { return addCaret(up: false) }
        if keys.completions.matches(event), let onComplete {
            return onComplete()
        }
        super.keyDown(with: event)
    }

    /// Home (Pos1) and End go to the line's edges and Page Up and Down move the caret, like other editors; ⌘ or ⌃ for the document's.
    static func lineKeyCommand(for event: NSEvent) -> Selector? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let extend = modifiers.contains(.shift)
        let document = modifiers.contains(.command) || modifiers.contains(.control)
        guard !modifiers.contains(.option) else { return nil }
        switch event.specialKey {
        case .home?:
            return document ? (extend ? #selector(moveToBeginningOfDocumentAndModifySelection(_:)) : #selector(moveToBeginningOfDocument(_:)))
                : (extend ? #selector(moveToLeftEndOfLineAndModifySelection(_:)) : #selector(moveToLeftEndOfLine(_:)))
        case .end?:
            return document ? (extend ? #selector(moveToEndOfDocumentAndModifySelection(_:)) : #selector(moveToEndOfDocument(_:)))
                : (extend ? #selector(moveToRightEndOfLineAndModifySelection(_:)) : #selector(moveToRightEndOfLine(_:)))
        case .pageUp? where !document:
            return extend ? #selector(pageUpAndModifySelection(_:)) : #selector(pageUp(_:))
        case .pageDown? where !document:
            return extend ? #selector(pageDownAndModifySelection(_:)) : #selector(pageDown(_:))
        default:
            return nil
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onResign?()
            caretView.isHidden = true
        }
        return resigned
    }

    override func insertTab(_ sender: Any?) {
        insertText("  ", replacementRange: selectedRange())
    }

    /// Keeps the indentation, indents after an opener and continues list items.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard !isColumnMode, isEditable else { return super.insertNewline(sender) }
        apply(TypewrightCore.newline(text: string, from: Int32(selection.location), to: Int32(NSMaxRange(selection)), syntax: syntax),
              action: "Typing")
    }
}

struct CodeEditor: NSViewRepresentable {
    @AppStorage("editorFontName") private var fontName = ""
    let documentID: Int
    let text: String
    let fontSize: CGFloat
    var glidingCursor = false
    /// Lines wrap at this column, drawn as a guide; 0 wraps at the view's edge.
    var wrapColumn = 0
    var vim = false
    /// Shows math as it renders while the caret is elsewhere.
    var concealsMath = false
    /// Types the closing bracket or quote along with the opening one.
    var autoClose = false
    var find: FindModel?
    let highlights: Bool
    /// Colours Markdown; `highlights` is for Typst.
    var markdown = false
    /// How ⌘7 and ⇧⌘7 comment the shown file; nil leaves them unused.
    var comments: CommentSyntax?
    let diagnostics: [Diagnostic]
    let reveal: RevealRequest?
    /// Restored when a new document is shown.
    let state: EditorState?
    let topInset: CGFloat
    /// The flag marks live edits like color wheel drags, which should compile right away.
    let onChange: (String, Bool) -> Void
    let onStateChange: (EditorState) -> Void
    /// Completions, docs, navigation, formatting and renaming; nil turns them off.
    var language: (any EditorLanguage)?
    /// Edits and cursors of other devices with the same file open.
    var live: LiveEditing?
    /// Changes with each new solveng report from the compiler, which restyles the text.
    var solvengRevision = 0
    /// The Vim mode for the status bar, nil while Vim is off.
    var onVimModeChange: ((String?) -> Void)?
    /// Called with where the caret was when a click moves it far, for the navigation history.
    var onJump: ((Int) -> Void)?
    /// Saves pasted images and returns the text that shows them; nil pastes them as usual.
    var onPasteImage: ((NSPasteboard) -> String?)?
    /// After undo or redo in the text, with the resulting text.
    var onDidUndo: ((Bool, String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = EditorLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = TypstTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 6, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .labelColor
        // Neutral selection instead of the system accent.
        tv.selectedTextAttributes = [.backgroundColor: NSColor.clear]
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        // Text starts below the hidden title bar strip but scrolls under it.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        let ruler = LineNumberRuler(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let markers = DiagnosticMarkers(textView: tv)
        markers.isHidden = true
        scroll.addSubview(markers)
        tv.markers = markers
        context.coordinator.markers = markers

        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        context.coordinator.completion = CompletionController(textView: tv)
        let hover = HoverController(textView: tv)
        context.coordinator.hover = hover
        tv.onPointerMoved = { [weak hover] in hover?.pointerMoved(to: $0) }
        tv.onPointerExited = { [weak hover] in hover?.pointerExited() }
        tv.onDismissHover = { [weak hover] in hover?.hide() }
        tv.onSwatchClick = { [weak coordinator = context.coordinator] in coordinator?.editColor($0) }
        context.coordinator.popupDismissal = Popups.observe(window: { [weak tv] in tv?.window }) {
            [weak coordinator = context.coordinator] in coordinator?.colorPopover?.close()
        }
        tv.onResign = { [weak coordinator = context.coordinator] in
            coordinator?.completion?.hide()
            coordinator?.commitRename()
        }
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.didScroll),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onChange = onChange
        c.highlights = highlights
        c.markdown = markdown
        c.onStateChange = onStateChange
        c.language = language
        c.completion?.provider = language.map { l in { await l.completions(at: $0) } }
        c.completion?.docsProvider = language.map { l in { await l.documentation(of: $0) } }
        c.hover?.provider = language.map { l in { await l.hover(at: $0) } }
        c.occurrenceProvider = language.map { l in { await l.occurrences(at: $0) } }
        guard let tv = c.textView as? TypstTextView else { return }
        tv.onJump = onJump
        tv.onPasteImage = onPasteImage
        tv.onDidUndo = onDidUndo
        tv.comments = comments
        tv.glidingCaret = glidingCursor
        tv.concealsMath = concealsMath && highlights
        tv.syntax = highlights ? "typst" : markdown ? "markdown" : ""
        tv.autoPairs = !autoClose ? [:] : highlights ? ["(": ")", "[": "]", "{": "}", "\"": "\"", "$": "$", "`": "`"]
            : markdown ? ["(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`"] : [:]
        tv.wrapColumn = wrapColumn
        tv.onWrapColumnChange = { UserDefaults.standard.set($0, forKey: "wrapColumn") }
        tv.configureVim(vim, completion: c.completion, onModeChange: onVimModeChange)
        if let find {
            find.textView = tv
            find.applyEdits = { [weak c] edits, name in c?.apply(edits, actionName: name) }
            tv.onFind = { [weak find] replace in find?.show(replace: replace) }
            tv.onFindStep = { [weak find] delta in
                guard let find else { return }
                if !find.isVisible { find.show(replace: false) } else if delta > 0 { find.next() } else { find.previous() }
            }
        }
        c.find = find
        tv.onDefinition = language == nil ? nil : { [weak c] offset in c?.goToDefinition(at: offset) }
        tv.onComplete = language == nil ? nil : { [weak c] in c?.completion?.request(force: true) }
        tv.solvengContext = language.map { l in { l.solvengContext() } }
        tv.onShowDocs = language == nil ? nil : { [weak c] in
            if c?.completion?.toggleDocs() != true { c?.hover?.toggleAtCaret() }
        }
        tv.onFormat = language == nil ? nil : { [weak c] in c?.format() }
        tv.onRename = language == nil ? nil : { [weak c] in c?.startRename() }
        tv.onExtractVariable = highlights ? { [weak c] in c?.extractVariable() } : nil
        tv.onInlineVariable = highlights ? { [weak c] in c?.inlineVariable() } : nil
        tv.onExtractFunction = highlights ? { [weak c] in c?.extractFunction(toScope: $0) } : nil
        // While other devices edit along, undo takes back only this device's edits.
        tv.onUndo = { [weak c, weak tv] in
            if c?.undoRename() == true { return true }
            guard let live = c?.live, live.isActive else { return false }
            let files = (tv?.window?.windowController as? MainWindowController)?.state.undoManager
            if let files, files.canUndo,
               (files.journal.undo.last?.order ?? 0) > (live.journal.undo.last?.order ?? 0) {
                files.undo()
            } else if !live.undo(redo: false) { files?.undo() }
            return true
        }
        tv.onQuickFix = { [weak c] in c?.showQuickFixes(at: $0) }
        tv.hasQuickFixes = { [weak c] in !(c?.quickFixes(at: $0).isEmpty ?? true) }
        c.hover?.fixesProvider = language.map { l in { l.quickFixes(for: $0) } }
        c.hover?.command = { [weak c] url in c?.runCommand(url) ?? false }
        tv.onRedo = { [weak c, weak tv] in
            if c?.redoRename() == true { return true }
            guard let live = c?.live, live.isActive else { return false }
            let files = (tv?.window?.windowController as? MainWindowController)?.state.undoManager
            if let files, files.canRedo,
               (files.journal.redo.last?.order ?? 0) > (live.journal.redo.last?.order ?? 0) {
                files.redo()
            } else if !live.undo(redo: true) { files?.redo() }
            return true
        }
        if c.live !== live {
            c.live?.applyEdits = nil
            c.live?.showCursors = nil
            c.live = live
            live?.applyEdits = { [weak c] in c?.applyRemote($0) ?? false }
            live?.showCursors = { [weak tv] in tv?.remoteCursors = $0 }
        }

        let font = EditorFont.font(name: fontName, size: fontSize)
        if c.documentID != documentID || c.font != font {
            let isNewDocument = c.documentID != documentID
            // Zooming keeps the line at the top in place.
            let anchor = isNewDocument || c.font == nil ? nil : c.topCharacter()
            c.documentID = documentID
            c.font = font
            tv.font = font
            if let anchor { DispatchQueue.main.async { c.scroll(toCharacter: anchor) } }
            if isNewDocument {
                c.dropRename()
                c.completion?.hide()
                c.hover?.hide()
                (tv as TypstTextView).occurrences = []
                DispatchQueue.main.async { [weak find] in find?.textDidChange() }
                c.endColorEdit()
                c.isRestoring = true
                tv.undoManager?.removeAllActions()
                if tv.string != text { tv.string = text }
                let state = state ?? EditorState()
                // Wait for the view to get its real width so line positions are final.
                DispatchQueue.main.async {
                    Self.restore(state, in: tv)
                    c.isRestoring = false
                    c.report()
                }
            }
            if let storage = tv.textStorage { c.style(storage) }
            c.solvengRevision = solvengRevision
        }
        if c.solvengRevision != solvengRevision {
            c.solvengRevision = solvengRevision
            if let storage = tv.textStorage { c.style(storage) }
            if tv.concealsMath { tv.refreshConceals() }
        }

        if c.diagnostics != diagnostics {
            c.diagnostics = diagnostics
            c.updateDiagnostics()
        }
        c.markers?.topInset = topInset

        if let reveal, c.reveal != reveal {
            c.reveal = reveal
            DispatchQueue.main.async { Self.select(reveal, in: tv) }
        }
        c.ruler?.needsDisplay = true
    }

    // Fitting size follows the text; never let it set the column's min size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }

    static func lineRange(_ line: Int, in s: NSString) -> NSRange? {
        var current = 1
        var index = 0
        while current < line {
            let r = s.lineRange(for: NSRange(location: index, length: 0))
            guard NSMaxRange(r) < s.length else { return nil }
            index = NSMaxRange(r)
            current += 1
        }
        var r = s.lineRange(for: NSRange(location: index, length: 0))
        if r.length > 0, s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        return r
    }

    private static func restore(_ state: EditorState, in tv: NSTextView) {
        let length = (tv.string as NSString).length
        let location = min(state.selection, length)
        tv.setSelectedRange(NSRange(location: location, length: min(state.length, length - location)))
        guard let lm = tv.layoutManager, let scroll = tv.enclosingScrollView else { return }
        var y = -scroll.contentInsets.top
        if length > 0, state.top > 0 {
            let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(state.top, length - 1)), effectiveRange: nil)
            y += rect.minY + tv.textContainerOrigin.y
        }
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private static func select(_ reveal: RevealRequest, in tv: NSTextView) {
        let s = tv.string as NSString
        guard let r = lineRange(reveal.line, in: s) else { return }
        let loc = min(r.location + max(reveal.column - 1, 0), NSMaxRange(r))
        let selection = NSRange(location: loc, length: min(reveal.length, NSMaxRange(r) - loc))
        if reveal.focus { tv.window?.makeFirstResponder(tv) }
        tv.setSelectedRange(selection)
        tv.scrollRangeToVisible(r)
        let marked = NSRange(location: loc, length: min(reveal.marked, NSMaxRange(r) - loc))
        tv.showFindIndicator(for: selection.length > 0 ? selection : marked.length > 0 ? marked : r)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        /// The color panel is shared; only the editor that last opened it drives it.
        private static weak var colorOwner: Coordinator?
        /// The text's own undo, apart from the window's, which holds file tree changes.
        let textUndo = ActionUndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { textUndo }
        weak var textView: NSTextView? {
            didSet {
                textUndo.text = { [weak self] in self?.textView?.string }
                textUndo.finishEditing = { [weak self] in self?.textView?.breakUndoCoalescing() }
            }
        }
        weak var ruler: NSRulerView?
        weak var markers: DiagnosticMarkers?
        var completion: CompletionController?
        var hover: HoverController?
        weak var language: (any EditorLanguage)?
        weak var find: FindModel?
        var occurrenceProvider: ((Int) async -> [NSRange])?
        private var occurrenceTask: Task<Void, Never>?
        /// What the last keystroke inserted: "" for a deletion, nil for pastes and programmatic edits.
        private var lastTyped: String?
        private var colorEdit: ColorEdit?
        private var isApplyingColor = false
        private var colorPanelObserver: (any NSObjectProtocol)?
        private(set) var colorPopover: NSPopover?
        var popupDismissal: (any NSObjectProtocol)? {
            didSet { if let oldValue { NotificationCenter.default.removeObserver(oldValue) } }
        }

        deinit { if let popupDismissal { NotificationCenter.default.removeObserver(popupDismissal) } }

        var documentID = -1
        var font: NSFont?
        var solvengRevision = 0
        var highlights = true
        var markdown = false
        var diagnostics: [Diagnostic] = []
        var reveal: RevealRequest?
        var onChange: (String, Bool) -> Void = { _, _ in }
        var onStateChange: (EditorState) -> Void = { _ in }
        var isRestoring = false
        weak var live: LiveEditing?
        private var isApplyingRemote = false

        /// Edits from other devices: not undoable here, and the caret keeps its place in the text around them.
        func applyRemote(_ edits: [LiveResult.Edit]) -> Bool {
            guard let tv = textView, let storage = tv.textStorage else { return false }
            // A rename would mirror the remote text into its other ranges.
            commitRename()
            var selection = tv.selectedRange()
            func shift(_ position: Int, _ edit: LiveResult.Edit) -> Int {
                if position <= edit.location { return position }
                if position >= edit.location + edit.length { return position + (edit.text as NSString).length - edit.length }
                return edit.location
            }
            tv.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            for edit in edits where edit.location + edit.length <= storage.length {
                storage.replaceCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.text)
                let start = shift(selection.location, edit), end = shift(NSMaxRange(selection), edit)
                selection = NSRange(location: start, length: max(end - start, 0))
            }
            storage.endEditing()
            tv.undoManager?.enableUndoRegistration()
            isApplyingRemote = true
            tv.setSelectedRange(selection)
            textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
            isApplyingRemote = false
            return true
        }

        @objc func didScroll() {
            completion?.hide()
            hover?.hide()
            report()
        }

        func report() {
            guard !isRestoring, let tv = textView, let top = topCharacter() else { return }
            let selection = tv.selectedRange()
            onStateChange(EditorState(selection: selection.location, length: selection.length, top: top))
        }

        /// The first character visible below the top inset.
        func topCharacter() -> Int? {
            guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer,
                  let scroll = tv.enclosingScrollView else { return nil }
            let y = scroll.contentView.bounds.minY + scroll.contentInsets.top - tv.textContainerOrigin.y
            let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: container)
            return (tv.string as NSString).length == 0 ? 0 : lm.characterIndexForGlyph(at: glyph)
        }

        func scroll(toCharacter index: Int) {
            guard let tv = textView, let lm = tv.layoutManager, let scroll = tv.enclosingScrollView else { return }
            let length = (tv.string as NSString).length
            guard length > 0, index > 0 else { return }
            let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(index, length - 1)), effectiveRange: nil)
            let clip = scroll.contentView
            let y = rect.minY + tv.textContainerOrigin.y - scroll.contentInsets.top
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard allowsRenameEdit(range, text) else { return false }
            textUndo.prepare(text: textView.string)
            let event = NSApp.currentEvent
            let typing = event?.type == .keyDown && event?.modifierFlags.contains(.command) == false
                && (textView as? TypstTextView)?.isColumnMode != true
            // A typed opener comes with its closer; the opener counts, so `(` still asks for the parameters.
            let typed = text.map { $0.utf16.count == 2 && "([{\"".contains($0.prefix(1)) ? String($0.prefix(1)) : $0 }
            lastTyped = typing && !isApplyingColor && completion?.isEditing != true && (typed?.utf16.count ?? 2) <= 1 ? typed : nil
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if renameSession != nil {
                switch selector {
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    commitRename()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    cancelRename()
                    return true
                default:
                    break
                }
            }
            if completion?.handle(selector) == true { return true }
            // ⇧↩ starts a new line below without splitting the current one.
            if selector == #selector(NSResponder.insertNewline(_:)),
               NSApp.currentEvent?.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift {
                let s = textView.string as NSString
                var line = s.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
                if line.length > 0, s.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
                textView.setSelectedRange(NSRange(location: NSMaxRange(line), length: 0))
                textView.insertNewline(nil)
                return true
            }
            return false
        }

        /// Keeps underlines, hover ranges and markers on the same diagnostic lines.
        func updateDiagnostics() {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            var marked: [(range: NSRange, diagnostic: Diagnostic)] = []
            let s = tv.string as NSString
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: s.length))
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: s.length))
            for d in diagnostics {
                guard let range = CodeEditor.lineRange(d.line, in: s) else { continue }
                let tint: NSColor = d.severity == .error ? .systemRed : .systemYellow
                // Warnings only get their underline; errors tint the whole line.
                if d.severity == .error {
                    lm.addTemporaryAttributes([.backgroundColor: tint.withAlphaComponent(0.12)], forCharacterRange: range)
                }
                let start = min(range.location + max(d.column - 1, 0), NSMaxRange(range))
                let underline = NSRange(location: start, length: min(d.length ?? .max, NSMaxRange(range) - start))
                lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                                           .underlineColor: tint], forCharacterRange: underline)
                marked.append((range, d))
            }
            hover?.diagnostics = marked
            markers?.diagnostics = marked
            markers?.isHidden = marked.isEmpty
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if let storage = tv.textStorage { style(storage) }
            // Edits shift character offsets before the compiler supplies new diagnostics.
            updateDiagnostics()
            // A change of the user's own ends a color session; the wheel's edits continue it.
            if !isApplyingColor { endColorEdit() }
            (tv as? TypstTextView)?.occurrences = []
            if renameSession != nil {
                if !isMirroring {
                    mirrorRename()
                    onChange(tv.string, isApplyingColor)
                    find?.textDidChange()
                }
                lastTyped = nil
                return
            }
            onChange(tv.string, isApplyingColor)
            find?.textDidChange()
            if completion?.isEditing != true, !isApplyingRemote { completion?.textDidChange(typed: lastTyped) }
            lastTyped = nil
        }

        func style(_ storage: NSTextStorage) {
            guard let font else { return }
            var swatches: [ColorLiteral] = []
            if highlights {
                Highlighter.apply(to: storage, font: font, solvengContext: language?.solvengContext() ?? "")
                let s = storage.string as NSString
                // Literals at a line start have no character to kern, so they go without a swatch.
                swatches = ColorLiteral.find(in: storage.string).filter {
                    $0.range.location > 0 && s.character(at: $0.range.location - 1) != 10
                }
                let gap = TypstTextView.swatchGap(for: font)
                for literal in swatches {
                    storage.addAttribute(.kern, value: gap, range: NSRange(location: literal.range.location - 1, length: 1))
                }
            } else if markdown {
                MarkdownHighlighter.apply(to: storage, font: font)
            } else {
                storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor],
                                      range: NSRange(location: 0, length: storage.length))
            }
            (textView as? TypstTextView)?.swatches = swatches
            (textView as? TypstTextView)?.updateRevealedEquation()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
            // Leaving the symbol accepts the new name, like IntelliJ.
            // While a keystroke is applied the caret moves before the ranges do.
            if let session = renameSession, !isMirroring, session.pending == nil, let tv = textView {
                let p = session.ranges[session.primary], sel = tv.selectedRange()
                if sel.location < p.location || NSMaxRange(sel) > NSMaxRange(p) { commitRename() }
            }
            completion?.selectionDidChange()
            (textView as? TypstTextView)?.updateRevealedEquation()
            updateHighlights()
            report()
        }

        private var bracketSource: NSString?
        private var bracketComments: [NSRange] = []

        /// Matches the bracket at the caret right away and asks the server for the symbol's uses after a pause.
        private func updateHighlights() {
            guard let tv = textView as? TypstTextView else { return }
            let selection = tv.selectedRange()
            let s = tv.string as NSString
            let nextToBracket = [selection.location - 1, selection.location].contains { index in
                index >= 0 && index < s.length && [34, 40, 41, 91, 93, 123, 125].contains(Int(s.character(at: index)))
            }
            if highlights && selection.length == 0 && nextToBracket {
                if bracketSource != s {
                    bracketSource = s
                    bracketComments = Highlighter.runs(in: tv.string).filter { $0.tag == .comment }.map(\.range)
                }
                tv.brackets = Self.matchingBrackets(at: selection.location, in: s, comments: bracketComments)
            } else {
                tv.brackets = []
            }
            occurrenceTask?.cancel()
            if !tv.occurrences.contains(where: { NSLocationInRange(selection.location, $0) || NSMaxRange($0) == selection.location }) {
                tv.occurrences = []
            }
            guard let provider = occurrenceProvider, selection.length == 0 else { return }
            let caret = selection.location
            occurrenceTask = Task { [weak tv] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                let ranges = await provider(caret)
                guard !Task.isCancelled, let tv, tv.selectedRange().location == caret else { return }
                // A lone use is just the word under the caret.
                tv.occurrences = ranges.count > 1 ? ranges : []
            }
        }

        /// The bracket or quote next to the caret, excluding comments from Typst's parser.
        static func matchingBrackets(at caret: Int, in s: NSString, comments: [NSRange]? = nil) -> [NSRange] {
            let comments = comments ?? Highlighter.runs(in: s as String).filter { $0.tag == .comment }.map(\.range)
            return TypewrightCore.matchingBrackets(caret: Int32(caret), text: s as String, comments: comments.map {
                TypewrightCore.TextRange(location: Int32($0.location), length: Int32($0.length))
            }).map { NSRange(location: Int($0.location), length: Int($0.length)) }
        }

        // MARK: - Quick fixes

        /// Fixes for every diagnostic on the character's line, then rewrites of the solveng calculation there.
        func quickFixes(at index: Int) -> [QuickFix] {
            guard let language, let hover else { return [] }
            let fixes = hover.diagnostics
                .filter { NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index }
                .flatMap { language.quickFixes(for: $0.diagnostic) }
            return fixes + solvengConversions(at: index).filter { conversion in !fixes.contains { $0.title == conversion.title } }
        }

        /// Fixes for explicit calculation bindings.
        private func solvengConversions(at index: Int) -> [QuickFix] {
            guard let tv = textView else { return [] }
            let text = tv.string
            let context = language?.solvengContext() ?? ""
            let found = SolvengSupport.unitFixes(text, context: context, offset: index)
            return found.map { conversion in
                QuickFix(id: "solveng.\(conversion.title)", title: conversion.title, icon: "arrow.left.arrow.right") { [weak self] in
                    guard let self, self.textView?.string == text else { return }
                    self.apply(conversion.textEdits, actionName: conversion.title)
                }
            }
        }

        func showQuickFixes(at index: Int) {
            guard let tv = textView, let window = tv.window else { return }
            let fixes = quickFixes(at: index)
            guard !fixes.isEmpty else { return NSSound.beep() }
            hover?.hide()
            let menu = NSMenu()
            menu.autoenablesItems = false
            for fix in fixes {
                let item = ClosureMenuItem(title: fix.title) { fix.run?() }
                item.image = NSImage(systemSymbolName: fix.icon, accessibilityDescription: nil)
                item.isEnabled = fix.run != nil
                menu.addItem(item)
            }
            let caret = tv.firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
            let point = tv.convert(window.convertPoint(fromScreen: NSPoint(x: caret.minX, y: caret.minY)), from: nil)
            Popups.show(menu, at: point, in: tv)
        }

        // MARK: - Navigation

        /// Follows the symbol; on a definition, one usage is jumped to and several are offered in a menu at the caret.
        func goToDefinition(at offset: Int) {
            guard let language else { return }
            Task {
                let links = await language.links(at: offset)
                if !links.isEmpty, let tv = textView, let window = tv.window {
                    let menu = NSMenu()
                    for link in links {
                        let item = ClosureMenuItem(title: link.title) { NSWorkspace.shared.open(link.url) }
                        item.subtitle = link.url.isFileURL ? link.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                            : link.url.host() ?? link.url.absoluteString
                        menu.addItem(item)
                    }
                    let caret = tv.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
                    let point = tv.convert(window.convertPoint(fromScreen: NSPoint(x: caret.minX, y: caret.minY)), from: nil)
                    Popups.show(menu, at: point, in: tv)
                    return
                }
                let usages = await language.goToDefinition(at: offset)
                guard let tv = textView, !usages.isEmpty else { return }
                if usages.count == 1 { return language.open(usages[0].location) }
                let menu = NSMenu()
                for usage in usages {
                    let item = ClosureMenuItem(title: usage.preview) { [language] in language.open(usage.location) }
                    item.subtitle = "\(usage.file):\(usage.location.line + 1)"
                    menu.addItem(item)
                }
                let caret = tv.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
                guard let window = tv.window else { return }
                let point = tv.convert(window.convertPoint(fromScreen: NSPoint(x: caret.minX, y: caret.minY)), from: nil)
                Popups.show(menu, at: point, in: tv)
            }
        }

        // MARK: - Formatting and renaming

        func format() {
            guard let tv = textView, let language else { return }
            let before = tv.string
            Task {
                let edits = await language.formattingEdits()
                // Edits made while the server worked would be clobbered.
                guard tv.string == before, !edits.isEmpty else { return }
                apply(edits, actionName: "Format Document")
            }
        }

        // MARK: Inline rename

        /// In-place rename: the symbol and its uses in this file change together as you type.
        final class RenameSession {
            let original: String
            /// Where the symbol was, for asking the server once the name is final.
            let origin: Int
            let text: String
            /// What each range covered before the session; the server's edits can widen them or add new ones.
            var originalRanges: [NSRange]
            var originalNames: [String]
            /// Ranges the server's edits added (a new import line) or widened (`pi as tau`).
            var managed: [Bool]
            let solvengContext: String?
            /// The name is renamed in its import: it shows as typed until the rename is done, then gets its alias.
            let inImport: Bool
            var ranges: [NSRange]
            var primary: Int
            var pending: (range: NSRange, length: Int)?
            /// Names before each keystroke, for ⌘Z inside the session, and the ones undone, for ⇧⌘Z.
            var undoNames: [String] = []
            var redoNames: [String] = []
            /// A new variable's spots, renamed right here instead of by the server.
            let local: [NSRange]?
            /// Keystrokes stay out of the undo history; registration goes off at the first one, since a group
            /// still open when it goes off (like the extract's) never closes and swallows the rename.
            var registrationOff = false

            init(original: String, origin: Int, text: String, ranges: [NSRange], primary: Int, local: Bool = false,
                 solvengContext: String? = nil, inImport: Bool = false) {
                self.original = original
                self.origin = origin
                self.text = text
                self.ranges = ranges
                self.originalRanges = ranges
                self.originalNames = ranges.map { (text as NSString).substring(with: $0) }
                self.managed = ranges.map { _ in false }
                self.solvengContext = solvengContext
                self.inImport = inImport
                self.primary = primary
                self.local = local ? ranges : nil
            }
        }

        private var renameSession: RenameSession?
        private var isMirroring = false

        func startRename() {
            guard renameSession == nil, let tv = textView, let language else { return }
            completion?.hide()
            hover?.hide()
            let caret = tv.selectedRange().location
            let before = tv.string
            Task {
                // Right after a name, like `greet|`, the server finds nothing at the caret; the name ends there.
                var found = await language.renameTarget(at: caret)
                if found == nil, caret > 0, let c = UnicodeScalar((before as NSString).character(at: caret - 1)),
                   CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains(c) {
                    found = await language.renameTarget(at: caret - 1)
                }
                guard let target = found, tv.string == before else { return NSSound.beep() }
                let uses = await language.occurrences(at: target.range.location)
                guard tv.string == before, renameSession == nil else { return }
                let s = before as NSString
                let context = language.solvengContext()
                let solvengTarget = SolvengSupport.renameTarget(before, context: context, offset: target.range.location)
                let solveng = solvengTarget != nil
                var ranges = (uses + [target.range]).filter {
                    NSMaxRange($0) <= s.length && (solveng || s.substring(with: $0) == target.name)
                }
                ranges = Array(Set(ranges.map { [$0.location, $0.length] })).map { NSRange(location: $0[0], length: $0[1]) }
                    .sorted { $0.location < $1.location }
                guard let primary = ranges.firstIndex(of: target.range) else { return NSSound.beep() }
                tv.breakUndoCoalescing()
                // The session's keystrokes become one rename step, registered when it's committed.
                renameSession = RenameSession(original: target.name, origin: target.range.location, text: before,
                                              ranges: ranges, primary: primary, solvengContext: solveng ? context : nil,
                                              inImport: solvengTarget?.inImport ?? false)
                tv.setSelectedRange(target.range)
                showRenameRanges()
            }
        }

        private func showRenameRanges() {
            guard let tv = textView as? TypstTextView else { return }
            tv.renameRanges = renameSession?.ranges ?? []
            tv.renamePrimary = renameSession.map { $0.ranges[$0.primary] }
        }

        /// Edits must stay inside the symbol being renamed.
        private func allowsRenameEdit(_ range: NSRange, _ text: String?) -> Bool {
            guard let session = renameSession, !isMirroring else { return true }
            let p = session.ranges[session.primary]
            guard range.location >= p.location, NSMaxRange(range) <= NSMaxRange(p), text?.contains("\n") != true else {
                NSSound.beep()
                return false
            }
            if !session.registrationOff {
                session.registrationOff = true
                textView?.undoManager?.disableUndoRegistration()
            }
            session.pending = (range, (text as NSString?)?.length ?? 0)
            if let tv = textView { session.undoNames.append((tv.string as NSString).substring(with: p)) }
            session.redoNames.removeAll()
            return true
        }

        /// Copies the edited name to every other use.
        private func mirrorRename() {
            guard let tv = textView, let session = renameSession, let pending = session.pending else { return }
            session.pending = nil
            let delta = pending.length - pending.range.length
            session.ranges[session.primary].length += delta
            for j in session.ranges.indices where j > session.primary { session.ranges[j].location += delta }
            let name = (tv.string as NSString).substring(with: session.ranges[session.primary])
            let caret = tv.selectedRange().location - session.ranges[session.primary].location
            renderRename(name, caret: caret)
        }

        private func renderRename(_ name: String, caret: Int) {
            guard let tv = textView, let session = renameSession else { return }
            var names = Array(repeating: name, count: session.ranges.count)
            if name == session.originalNames[session.primary] {
                names = session.originalNames
            } else if let context = session.solvengContext {
                let edits = SolvengSupport.rename(session.text, context: context, offset: session.origin, to: name)
                    .filter { $0.path == nil }
                let current = tv.string as NSString
                var written = Array(repeating: false, count: names.count)
                for edit in edits {
                    let range = NSRange(location: edit.start, length: edit.end - edit.start)
                    if let i = session.originalRanges.firstIndex(of: range) {
                        // The edited name keeps the typed spelling where its import gets an alias only at the end.
                        if !(i == session.primary && session.inImport) { names[i] = edit.text }
                        written[i] = true
                    } else if let i = session.originalRanges.indices.first(where: { overlaps(session.originalRanges[$0], range) }) {
                        if i == session.primary { written[i] = true; continue }
                        // An edit reaching past a use, like `pi as tau` back to `pi`: the range grows to cover it.
                        widenRename(session, i, to: NSUnionRange(session.originalRanges[i], range))
                        let base = session.originalRanges[i]
                        names[i] = (session.originalNames[i] as NSString)
                            .replacingCharacters(in: NSRange(location: range.location - base.location, length: range.length), with: edit.text)
                        written[i] = true
                    } else {
                        // An edit elsewhere, like a new import line, shows right away too.
                        let i = addRename(session, range)
                        names.insert(edit.text, at: i)
                        written.insert(true, at: i)
                    }
                }
                // Ranges the edits added or widened go back once no edit needs them; other uses stay as they are.
                for i in names.indices where !written[i] && i != session.primary {
                    names[i] = session.managed[i] ? session.originalNames[i] : current.substring(with: session.ranges[i])
                }
            }
            for i in session.ranges.indices.reversed() {
                let old = session.ranges[i], replacement = names[i]
                if (tv.string as NSString).substring(with: old) != replacement { replaceForRename(old, with: replacement) }
                let d = (replacement as NSString).length - old.length
                session.ranges[i].length = (replacement as NSString).length
                for j in session.ranges.indices where j > i { session.ranges[j].location += d }
            }
            let primary = session.ranges[session.primary]
            let formatted = names[session.primary]
            let closingQuote = formatted.hasSuffix("\"") && !name.hasSuffix("\"") ? 1 : 0
            let position = primary.length - ((name as NSString).length - caret) - closingQuote
            isMirroring = true
            tv.setSelectedRange(NSRange(location: primary.location + min(max(position, 0), primary.length), length: 0))
            isMirroring = false
            showRenameRanges()
        }

        /// Whether two ranges share text, or an insertion falls inside the other.
        private func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
            NSIntersectionRange(a, b).length > 0 || (b.length == 0 && b.location > a.location && b.location < NSMaxRange(a))
                || (a.length == 0 && a.location > b.location && a.location < NSMaxRange(b))
        }

        /// Where `original`, a range of the session's text, is now: shifted by the ranges before it.
        private func currentLocation(_ session: RenameSession, of original: Int) -> Int {
            var location = original
            for j in session.ranges.indices where NSMaxRange(session.originalRanges[j]) <= original {
                location += session.ranges[j].length - session.originalRanges[j].length
            }
            return location
        }

        /// Grows range `i` to `span` of the session's text; what it gains around it is still as it was.
        private func widenRename(_ session: RenameSession, _ i: Int, to span: NSRange) {
            let old = session.originalRanges[i]
            let before = old.location - span.location, after = NSMaxRange(span) - NSMaxRange(old)
            session.ranges[i] = NSRange(location: session.ranges[i].location - before, length: session.ranges[i].length + before + after)
            session.originalRanges[i] = span
            session.originalNames[i] = (session.text as NSString).substring(with: span)
            session.managed[i] = true
        }

        /// Adds a range of the session's text to the session, in order; returns its index.
        private func addRename(_ session: RenameSession, _ range: NSRange) -> Int {
            let i = session.originalRanges.firstIndex { $0.location >= NSMaxRange(range) } ?? session.ranges.count
            let current = NSRange(location: currentLocation(session, of: range.location), length: range.length)
            session.ranges.insert(current, at: i)
            session.originalRanges.insert(range, at: i)
            session.originalNames.insert((session.text as NSString).substring(with: range), at: i)
            session.managed.insert(true, at: i)
            if i <= session.primary { session.primary += 1 }
            return i
        }

        private func replaceForRename(_ range: NSRange, with text: String) {
            guard let tv = textView else { return }
            isMirroring = true
            if tv.shouldChangeText(in: range, replacementString: text) {
                tv.replaceCharacters(in: range, with: text)
                tv.didChangeText()
            }
            isMirroring = false
        }

        /// Puts the original name back everywhere and returns the typed one.
        @discardableResult
        private func endRename() -> String? {
            guard let tv = textView, let session = renameSession else { return nil }
            let name = (tv.string as NSString).substring(with: session.ranges[session.primary])
            let caret = tv.selectedRange().location - session.ranges[session.primary].location
            var ranges = session.ranges
            // Untouched names need no edit, which would otherwise leave an empty undo step.
            for i in ranges.indices.reversed() where (tv.string as NSString).substring(with: ranges[i]) != session.originalNames[i] {
                replaceForRename(ranges[i], with: session.originalNames[i])
                let d = (session.originalNames[i] as NSString).length - ranges[i].length
                for j in ranges.indices where j > i { ranges[j].location += d }
            }
            renameSession = nil
            if session.registrationOff { tv.undoManager?.enableUndoRegistration() }
            showRenameRanges()
            let p = ranges[session.primary]
            tv.setSelectedRange(NSRange(location: p.location + min(max(caret, 0), p.length), length: 0))
            onChange(tv.string, false)
            return name
        }

        func cancelRename() { endRename() }

        /// Steps back through the typed names; undoing past the first keystroke cancels the rename.
        func undoRename() -> Bool {
            guard let session = renameSession, let tv = textView else { return false }
            guard let previous = session.undoNames.popLast() else {
                cancelRename()
                return true
            }
            session.redoNames.append((tv.string as NSString).substring(with: session.ranges[session.primary]))
            setRenameName(previous)
            return true
        }

        func redoRename() -> Bool {
            guard let session = renameSession, let tv = textView else { return false }
            guard let next = session.redoNames.popLast() else {
                NSSound.beep()
                return true
            }
            session.undoNames.append((tv.string as NSString).substring(with: session.ranges[session.primary]))
            setRenameName(next)
            return true
        }

        /// Writes `name` into every use and puts the caret at the end of the edited one.
        private func setRenameName(_ name: String) {
            renderRename(name, caret: (name as NSString).length)
            if let tv = textView { onChange(tv.string, false) }
        }

        /// A new document replaced the text; there's nothing to restore.
        func dropRename() {
            guard let session = renameSession else { return }
            renameSession = nil
            if session.registrationOff { textView?.undoManager?.enableUndoRegistration() }
            showRenameRanges()
        }

        /// Renames for real through the server, which also updates other files, as one undo step.
        func commitRename() {
            guard let tv = textView, let session = renameSession, let name = endRename() else { return }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != session.original else { return }
            if let local = session.local {
                return apply(local.map { TextEdit(range: $0, newText: trimmed) }, actionName: "Rename Variable")
            }
            guard let language else { return }
            Task {
                let edits = await language.rename(at: session.origin, to: trimmed)
                guard tv.string == session.text else { return }
                if edits.isEmpty { NSSound.beep() }
                apply(edits, actionName: "Rename Symbol")
            }
        }

        // MARK: - Extract and inline variable

        /// Asks which expression and how many occurrences, like IntelliJ, then lets the new name be typed.
        func extractVariable() {
            guard let tv = textView as? TypstTextView, renameSession == nil else { return }
            completion?.hide()
            hover?.hide()
            let found = Refactor.candidates(in: tv.string, selection: tv.selectedRange())
            if let error = found.error { return showRefactorMessage(error) }
            choose(found.candidates.map { (Self.menuTitle($0.text), $0) }, title: "Expressions") { [weak self] in
                self?.extract($0)
            }
        }

        private func extract(_ candidate: Refactor.Candidate) {
            guard let tv = textView else { return }
            let text = tv.string
            let one = Refactor.extract(in: text, range: candidate.range, all: false)
            if let error = one.error { return showRefactorMessage(error) }
            guard one.count > 1 else { return finishExtract(one, text: text) }
            choose([("Replace This Occurrence Only", false), ("Replace All \(one.count) Occurrences", true)],
                   title: "Occurrences", highlight: true) { [weak self] all in
                guard let self, tv.string == text else { return }
                finishExtract(all ? Refactor.extract(in: text, range: candidate.range, all: true) : one, text: text)
            }
        }

        /// Moves the selection, or an expression picked at the caret, into a new function; its locals become parameters.
        func extractFunction(toScope: Bool) {
            guard let tv = textView as? TypstTextView, renameSession == nil else { return }
            completion?.hide()
            hover?.hide()
            let text = tv.string
            let selection = tv.selectedRange()
            let proceed: (NSRange) -> Void = { [weak self] range in
                guard let self, tv.string == text else { return }
                guard toScope else {
                    return finishExtract(Refactor.function(in: text, range: range), text: text, action: "Extract Function")
                }
                let scopes = Refactor.scopes(in: text, range: range)
                if let error = scopes.error { return showRefactorMessage(error) }
                choose(scopes.candidates.map { ($0.text, $0.start) }, title: "Extract Function To", highlight: true) {
                    [weak self] scope in
                    guard let self, tv.string == text else { return }
                    finishExtract(Refactor.function(in: text, range: range, scope: scope), text: text, action: "Extract Function")
                }
            }
            guard selection.length == 0 else { return proceed(selection) }
            let found = Refactor.candidates(in: text, selection: selection)
            if let error = found.error { return showRefactorMessage(error) }
            choose(found.candidates.map { (Self.menuTitle($0.text), $0.range) }, title: "Expressions", then: proceed)
        }

        private func finishExtract(_ result: Refactor.Response, text: String, action: String = "Extract Variable") {
            if let error = result.error { return showRefactorMessage(error) }
            guard let tv = textView, tv.string == text, !result.edits.isEmpty else { return NSSound.beep() }
            apply(result.textEdits, actionName: action)
            let s = tv.string as NSString
            let ranges = result.nameRanges.filter { NSMaxRange($0) <= s.length }
            guard let first = ranges.first else { return }
            let name = s.substring(with: first)
            guard ranges.allSatisfy({ s.substring(with: $0) == name }) else { return }
            tv.breakUndoCoalescing()
            renameSession = RenameSession(original: name, origin: first.location, text: tv.string, ranges: ranges,
                                          primary: 0, local: true)
            tv.setSelectedRange(first)
            tv.scrollRangeToVisible(first)
            showRenameRanges()
        }

        /// Replaces every use of the variable at the caret with its value and drops the declaration.
        func inlineVariable() {
            guard let tv = textView, renameSession == nil else { return }
            completion?.hide()
            hover?.hide()
            let result = Refactor.inline(in: tv.string, at: tv.selectedRange().location)
            if let error = result.error { return showRefactorMessage(error) }
            apply(result.textEdits, actionName: "Inline Variable")
        }

        private static func menuTitle(_ text: String) -> String {
            let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return line.count > 60 ? String(line.prefix(59)) + "…" : line
        }

        /// A menu below the caret; a single choice runs right away.
        private func choose<T>(_ options: [(String, T)], title: String, highlight: Bool = false,
                               then run: @escaping (T) -> Void) {
            guard let tv = textView as? TypstTextView, !options.isEmpty else { return }
            if options.count == 1, !highlight { return run(options[0].1) }
            let menu = NSMenu(title: title)
            menu.addItem(NSMenuItem.sectionHeader(title: title))
            for (label, value) in options {
                menu.addItem(ClosureMenuItem(title: label) { run(value) })
            }
            let rect = tv.caretAnchor()
            Popups.show(menu, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: tv)
        }

        private func showRefactorMessage(_ message: String) {
            guard let tv = textView as? TypstTextView, !Popups.isCovered(tv.window) else { return }
            NSSound.beep()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: Text(message).padding(10))
            Popups.track(popover, in: tv.window)
            popover.show(relativeTo: tv.caretAnchor(), of: tv, preferredEdge: .maxY)
        }

        /// Runs a command the docs link to, like tinymist replacing an outdated package's version.
        @discardableResult
        func runCommand(_ url: URL) -> Bool {
            guard let tv = textView,
                  let edit = LanguageCommand.replaceText(in: url, text: tv.string) else { return false }
            apply([TextEdit(range: edit.range, newText: edit.text)], actionName: "Replace Text")
            return true
        }

        /// Applies edits as one undoable change, keeping the caret and scroll position in place.
        func apply(_ edits: [TextEdit], actionName: String) {
            guard let tv = textView, !edits.isEmpty else { return }
            let s = tv.string as NSString
            let sorted = edits.filter { NSMaxRange($0.range) <= s.length }.sorted { $0.range.location < $1.range.location }
            guard let first = sorted.first else { return }
            let end = sorted.map { NSMaxRange($0.range) }.max() ?? NSMaxRange(first.range)
            let union = NSRange(location: first.range.location, length: end - first.range.location)
            let shifted = sorted.map { TextEdit(range: NSRange(location: $0.range.location - union.location, length: $0.range.length),
                                                newText: $0.newText) }
            let replacement = TextEdit.apply(shifted, to: s.substring(with: union))
            func map(_ i: Int) -> Int {
                var delta = 0
                for e in sorted {
                    if NSMaxRange(e.range) <= i {
                        delta += (e.newText as NSString).length - e.range.length
                    } else if e.range.location < i {
                        return e.range.location + delta + min(i - e.range.location, (e.newText as NSString).length)
                    }
                }
                return i + delta
            }
            let selection = tv.selectedRange()
            let clip = tv.enclosingScrollView?.contentView
            let origin = clip?.bounds.origin
            // Its own undo step, never merged into the typing before it.
            tv.breakUndoCoalescing()
            guard tv.shouldChangeText(in: union, replacementString: replacement) else { return }
            tv.replaceCharacters(in: union, with: replacement)
            tv.didChangeText()
            tv.undoManager?.setActionName(actionName)
            let start = map(selection.location)
            tv.setSelectedRange(NSRange(location: start, length: max(map(NSMaxRange(selection)) - start, 0)))
            if let clip, let origin {
                clip.scroll(to: origin)
                tv.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }

        // MARK: - Color wheel

        /// One color wheel session on one literal; the whole session undoes as a single step.
        final class ColorEdit {
            var range: NSRange
            var format: ColorLiteral.Format
            let original: String
            var current: String
            var undoRegistered = false

            init(_ literal: ColorLiteral, text: String) {
                range = literal.range
                format = literal.format
                original = text
                current = text
            }
        }

        /// Opens the wheel in a popover pointing at the literal's swatch.
        func editColor(_ literal: ColorLiteral) {
            guard let tv = textView as? TypstTextView, let rect = tv.swatchRect(for: literal) else { return }
            endColorEdit()
            completion?.hide()
            colorEdit = ColorEdit(literal, text: (tv.string as NSString).substring(with: literal.range))
            let wheel = ColorWheel(color: literal.color) { [weak self] color in
                self?.apply(color)
            } onShowPanel: { [weak self] in
                self?.showColorPanel(literal.color)
            }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: wheel)
            popover.delegate = self
            colorPopover = popover
            Popups.track(popover, in: tv.window)
            popover.show(relativeTo: rect, of: tv, preferredEdge: .maxY)
        }

        func popoverDidClose(_ notification: Notification) {
            // The system panel opened from the popover keeps the session going.
            guard (notification.object as? NSPopover) === colorPopover else { return }
            colorPopover = nil
            if !(Self.colorOwner === self && NSColorPanel.shared.isVisible) { endColorEdit() }
        }

        /// The system color panel, for its eyedropper and palettes; it drives the same session.
        private func showColorPanel(_ color: NSColor) {
            let panel = NSColorPanel.shared
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.showsAlpha = true
            panel.isContinuous = true
            panel.color = colorEdit.flatMap { ColorLiteral.find(in: $0.current).first?.color } ?? color
            panel.setTarget(self)
            panel.setAction(#selector(colorChanged(_:)))
            Self.colorOwner = self
            colorPopover?.close()
            Popups.track(panel, in: textView?.window)
            panel.orderFront(nil)
            if colorPanelObserver == nil {
                colorPanelObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: panel, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.endColorEdit() } }
            }
        }

        func endColorEdit() {
            guard colorEdit != nil else { return }
            colorEdit = nil
            let popover = colorPopover
            colorPopover = nil
            popover?.close()
            if let colorPanelObserver { NotificationCenter.default.removeObserver(colorPanelObserver) }
            colorPanelObserver = nil
            let panel = NSColorPanel.shared
            if Self.colorOwner === self {
                Popups.remove(panel)
                Self.colorOwner = nil
                panel.setTarget(nil)
                panel.setAction(nil)
            }
        }

        @objc func colorChanged(_ sender: NSColorPanel) { apply(sender.color) }

        /// Rewrites the literal on every wheel move, so the preview follows live.
        private func apply(_ color: NSColor) {
            guard let tv = textView, let edit = colorEdit else { return }
            let s = tv.string as NSString
            guard NSMaxRange(edit.range) <= s.length, s.substring(with: edit.range) == edit.current else { return endColorEdit() }
            let new = ColorLiteral.source(for: color, format: edit.format)
            guard new != edit.current else { return }
            if !edit.undoRegistered {
                edit.undoRegistered = true
                tv.breakUndoCoalescing()
                textUndo.prepare(text: tv.string)
                // Reads the session's final text when it runs.
                tv.undoManager?.registerUndo(withTarget: self) { coordinator in
                    coordinator.swapColor(at: edit.range.location, length: (edit.current as NSString).length,
                                          to: edit.original, back: edit.current)
                }
                tv.undoManager?.setActionName("Change Color")
            }
            replaceSilently(edit.range, with: new)
            edit.range.length = (new as NSString).length
            edit.current = new
            edit.format = ColorLiteral.format(of: new, previous: edit.format)
            textUndo.refreshPreview()
        }

        private func swapColor(at location: Int, length: Int, to text: String, back: String) {
            endColorEdit()
            guard let tv = textView, location + length <= (tv.string as NSString).length else { return }
            replaceSilently(NSRange(location: location, length: length), with: text)
            tv.undoManager?.registerUndo(withTarget: self) { coordinator in
                coordinator.swapColor(at: location, length: (text as NSString).length, to: back, back: text)
            }
            tv.undoManager?.setActionName("Change Color")
        }

        private func replaceSilently(_ range: NSRange, with text: String) {
            guard let tv = textView else { return }
            isApplyingColor = true
            tv.undoManager?.disableUndoRegistration()
            if tv.shouldChangeText(in: range, replacementString: text) {
                tv.replaceCharacters(in: range, with: text)
                tv.didChangeText()
            }
            tv.undoManager?.enableUndoRegistration()
            isApplyingColor = false
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
