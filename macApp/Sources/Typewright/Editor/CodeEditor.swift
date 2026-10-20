import AppKit
import SwiftUI

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
}

extension EditorLanguage {
    func quickFixes(for diagnostic: Diagnostic) -> [QuickFix] { [] }
    func links(at offset: Int) async -> [(title: String, url: URL)] { [] }
    func documentation(of item: CompletionItem) async -> String? { item.documentation }
}

final class TypstTextView: NSTextView {
    /// Color literals that get a clickable swatch in the gap kerned in before them.
    var swatches: [ColorLiteral] = [] {
        didSet { if swatches != oldValue { needsDisplay = true } }
    }
    var onSwatchClick: ((ColorLiteral) -> Void)?
    var onDefinition: ((Int) -> Void)?
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
    /// Typing and clicking close the docs popup.
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

    override var font: NSFont? {
        didSet { updateWrapWidth() }
    }

    private var columnWidth: CGFloat {
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
        guard let window, wrapColumn > 0 else { return }
        // Holding ⌘ over the guide shows it can be dragged.
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if isOnGuide(point, flags: event.modifierFlags) { NSCursor.resizeLeftRight.set() } else if visibleRect.contains(point) { NSCursor.iBeam.set() }
        needsDisplay = true
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
    /// Gliding and Vim's block caret are drawn by this view instead of AppKit.
    private var ownsCaret: Bool { glidingCaret || vim?.blockCaret == true }
    func refreshCaret() { updateCaret(animated: false) }

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
        // Newer AppKit draws the caret with an indicator subview rather than drawInsertionPoint.
        for case let indicator as NSTextInsertionIndicator in subviews {
            indicator.displayMode = ownsCaret ? .hidden : .automatic
        }
        let selection = selectedRange()
        guard ownsCaret, selection.length == 0, window?.firstResponder === self, window?.isKeyWindow == true,
              let rect = caretRect(at: selection.location) else {
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

    /// Solid while moving, then blinking like the system caret.
    private func restartBlink() {
        guard let layer = caretView.layer else { return }
        layer.removeAnimation(forKey: "blink")
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0, 1]
        blink.keyTimes = [0, 0.45, 0.55, 0.95, 1]
        blink.duration = 1.05
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + 0.5
        layer.add(blink, forKey: "blink")
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

    // NSTextView sets the I-beam on every move, even under floating controls.
    override func mouseMoved(with event: NSEvent) {
        if let cursor = cursor(for: event) { cursor.set() } else { super.mouseMoved(with: event) }
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let exitArea { removeTrackingArea(exitArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        exitArea = area
    }

    private var exitArea: NSTrackingArea?

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerExited?()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let x = guideX, x < bounds.maxX {
            let active = isDraggingGuide || NSEvent.modifierFlags.contains(.command)
            (active ? NSColor.controlAccentColor.withAlphaComponent(0.7) : NSColor.separatorColor).setFill()
            NSRect(x: x.rounded(), y: rect.minY, width: active ? 2 : 1, height: rect.height).fill()
        }
        func boxes(_ ranges: [NSRange]) -> [NSRect] {
            guard let lm = layoutManager, let container = textContainer else { return [] }
            let length = (string as NSString).length
            return ranges.filter { NSMaxRange($0) <= length }.map { range in
                lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            }
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
        for (range, box) in zip(renameRanges, boxes(renameRanges)) where box.intersects(rect) {
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
        if let cursor = cursor(for: event) { cursor.set() } else { super.cursorUpdate(with: event) }
    }

    private func cursor(for event: NSEvent) -> NSCursor? {
        if let cursor = CursorArea.cursor(for: event) { return cursor }
        if isOnGuide(convert(event.locationInWindow, from: nil), flags: event.modifierFlags) { return .resizeLeftRight }
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

    override func mouseDown(with event: NSEvent) {
        onDismissHover?()
        let point = convert(event.locationInWindow, from: nil)
        if let literal = swatch(at: point) {
            onSwatchClick?(literal)
            return
        }
        if isOnGuide(point, flags: event.modifierFlags) { return dragGuide(from: event) }
        if event.modifierFlags.contains(.command), event.clickCount == 1, let onDefinition {
            let index = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: index, length: 0))
            onDefinition(index)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
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
            let fix = NSMenuItem(title: "Show Fixes…", action: #selector(showFixes(_:)), keyEquivalent: "\r")
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
        if onUndo?() != true { undoManager?.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if onRedo?() != true { undoManager?.redo() }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) { return onUndo != nil && isRenaming || undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return onRedo != nil && isRenaming || undoManager?.canRedo == true }
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
        if event.keyCode == 6, flags == .command, onUndo?() == true { return true }
        if event.keyCode == 6, flags == [.command, .shift], onRedo?() == true { return true }
        // ⌘F finds, ⌥⌘F also replaces; ⇧⌘F is left to the space search.
        if event.keyCode == 3, let onFind, flags == .command || flags == [.command, .option] {
            onFind(flags.contains(.option))
            return true
        }
        if event.keyCode == 5, let onFindStep, flags == .command || flags == [.command, .shift] {
            onFindStep(flags.contains(.shift) ? -1 : 1)
            return true
        }
        if flags == .command, event.keyCode == 11, let onDefinition {
            onDefinition(selectedRange().location)
            return true
        }
        if flags == [.command, .option], event.keyCode == 37, let onFormat {
            onFormat()
            return true
        }
        if flags == .shift, event.keyCode == 97, let onRename {
            onRename()
            return true
        }
        // ⌥⌘V extracts a variable, ⌥⌘N inlines one.
        if flags == [.command, .option], event.keyCode == 9, let onExtractVariable {
            onExtractVariable()
            return true
        }
        if flags == [.command, .option], event.keyCode == 45, let onInlineVariable {
            onInlineVariable()
            return true
        }
        // ⌥⌘M extracts a function, ⌥⇧⌘M asks where it goes.
        if event.keyCode == 46, flags == [.command, .option] || flags == [.command, .option, .shift], let onExtractFunction {
            onExtractFunction(flags.contains(.shift))
            return true
        }
        // ⌘D duplicates, ⌘⌫ deletes the line, like IntelliJ.
        if flags == .command, event.keyCode == 2, isEditable {
            duplicateLine()
            return true
        }
        if flags == .command, event.keyCode == 51, isEditable {
            deleteLine()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Duplicates the selection, or the caret's line when nothing is selected.
    func duplicateLine() {
        let s = string as NSString
        let sel = selectedRange()
        if sel.length > 0 {
            let copy = s.substring(with: sel)
            replace(NSRange(location: NSMaxRange(sel), length: 0), with: copy,
                    select: NSRange(location: NSMaxRange(sel), length: sel.length), action: "Duplicate")
            return
        }
        var line = s.lineRange(for: sel)
        let hasBreak = line.length > 0 && s.character(at: NSMaxRange(line) - 1) == 10
        if hasBreak { line.length -= 1 }
        let text = s.substring(with: line)
        replace(NSRange(location: NSMaxRange(line), length: 0), with: "\n" + text,
                select: NSRange(location: sel.location + line.length + 1, length: 0), action: "Duplicate Line")
    }

    /// Swaps the lines the selection touches with the line above or below; the selection moves along.
    func moveLines(up: Bool) {
        let s = string as NSString
        let sel = selectedRange()
        let trimmed = sel.length > 0 && s.character(at: NSMaxRange(sel) - 1) == 10
        let block = s.lineRange(for: trimmed ? NSRange(location: sel.location, length: sel.length - 1) : sel)
        guard block.length > 0, up ? block.location > 0 : NSMaxRange(block) < s.length else { return NSSound.beep() }
        // The last line has no break of its own; borrow the one before it so both halves stay lines.
        func lines(_ r: NSRange) -> String {
            let text = s.substring(with: r)
            return text.hasSuffix("\n") ? String(text.dropLast()) : text
        }
        let neighbour = s.lineRange(for: NSRange(location: up ? block.location - 1 : NSMaxRange(block), length: 0))
        let union = NSUnionRange(block, neighbour)
        let endsWithBreak = s.substring(with: union).hasSuffix("\n")
        let moved = lines(block), other = lines(neighbour)
        let swapped = (up ? moved + "\n" + other : other + "\n" + moved) + (endsWithBreak ? "\n" : "")
        let shift = up ? -((other as NSString).length + 1) : (other as NSString).length + 1
        replace(union, with: swapped, select: NSRange(location: sel.location + shift, length: sel.length),
                action: up ? "Move Line Up" : "Move Line Down")
    }

    /// Deletes the lines the selection touches, keeping the caret's column on the next line.
    func deleteLine() {
        let s = string as NSString
        let sel = selectedRange()
        // A selection ending at a line start leaves that line alone.
        let trimmed = sel.length > 0 && s.character(at: NSMaxRange(sel) - 1) == 10
        var range = s.lineRange(for: trimmed ? NSRange(location: sel.location, length: sel.length - 1) : sel)
        guard range.length > 0 || range.location > 0 else { return }
        let column = sel.location - range.location
        // The last line takes the break before it, so no empty line is left behind.
        if NSMaxRange(range) == s.length, s.character(at: NSMaxRange(range) - 1) != 10 || range.length == 0, range.location > 0 {
            range.location -= 1
            range.length += 1
        }
        let rest = s.replacingCharacters(in: range, with: "") as NSString
        let start = NSMaxRange(range) == s.length && range.location > 0
            ? rest.lineRange(for: NSRange(location: min(range.location, rest.length), length: 0)).location
            : range.location
        var next = rest.lineRange(for: NSRange(location: min(start, rest.length), length: 0))
        if next.length > 0, rest.character(at: NSMaxRange(next) - 1) == 10 { next.length -= 1 }
        replace(range, with: "", select: NSRange(location: start + min(column, next.length), length: 0), action: "Delete Line")
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
        onDismissHover?()
        if event.keyCode == 122, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, let onShowDocs {
            return onShowDocs()
        }
        if let vim, vim.handle(event) { return }
        // ⌥↩ shows the fixes for the problem at the caret.
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.shift, .command, .option, .control]) == .option, let onQuickFix {
            return onQuickFix(selectedRange().location)
        }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .shift, event.keyCode == 97, let onRename {
            return onRename()
        }
        // ⌥⇧↑ and ⌥⇧↓ move the lines, like IntelliJ.
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.option, .shift],
           event.keyCode == 126 || event.keyCode == 125, isEditable {
            return moveLines(up: event.keyCode == 126)
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.charactersIgnoringModifiers == " ",
           let onComplete {
            return onComplete()
        }
        super.keyDown(with: event)
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

    /// Keeps the indentation of the current line.
    override func insertNewline(_ sender: Any?) {
        let s = string as NSString
        let line = s.substring(with: s.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }
}

struct CodeEditor: NSViewRepresentable {
    let documentID: Int
    let text: String
    let fontSize: CGFloat
    var glidingCursor = false
    /// Lines wrap at this column, drawn as a guide; 0 wraps at the view's edge.
    var wrapColumn = 0
    var vim = false
    var find: FindModel?
    let highlights: Bool
    /// Colours Markdown; `highlights` is for Typst.
    var markdown = false
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
    /// The Vim mode for the status bar, nil while Vim is off.
    var onVimModeChange: ((String?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
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
        tv.selectedTextAttributes = [.backgroundColor: NSColor.gray.withAlphaComponent(0.3)]
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

        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        context.coordinator.completion = CompletionController(textView: tv)
        let hover = HoverController(textView: tv)
        context.coordinator.hover = hover
        tv.onPointerMoved = { [weak hover] in hover?.pointerMoved(to: $0) }
        tv.onPointerExited = { [weak hover] in hover?.pointerExited() }
        tv.onDismissHover = { [weak hover] in hover?.hide() }
        tv.onSwatchClick = { [weak coordinator = context.coordinator] in coordinator?.editColor($0) }
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
        tv.glidingCaret = glidingCursor
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
        tv.onShowDocs = language == nil ? nil : { [weak c] in
            if c?.completion?.toggleDocs() != true { c?.hover?.showAtCaret() }
        }
        tv.onFormat = language == nil ? nil : { [weak c] in c?.format() }
        tv.onRename = language == nil ? nil : { [weak c] in c?.startRename() }
        tv.onExtractVariable = highlights ? { [weak c] in c?.extractVariable() } : nil
        tv.onInlineVariable = highlights ? { [weak c] in c?.inlineVariable() } : nil
        tv.onExtractFunction = highlights ? { [weak c] in c?.extractFunction(toScope: $0) } : nil
        // While other devices edit along, undo takes back only this device's edits.
        tv.onUndo = { [weak c] in c?.undoRename() == true || c?.live?.undo(redo: false) == true }
        tv.onQuickFix = { [weak c] in c?.showQuickFixes(at: $0) }
        tv.hasQuickFixes = { [weak c] in !(c?.quickFixes(at: $0).isEmpty ?? true) }
        c.hover?.fixesProvider = language.map { l in { l.quickFixes(for: $0) } }
        tv.onRedo = { [weak c] in c?.redoRename() == true || c?.live?.undo(redo: true) == true }
        if c.live !== live {
            c.live?.applyEdits = nil
            c.live?.showCursors = nil
            c.live = live
            live?.applyEdits = { [weak c] in c?.applyRemote($0) ?? false }
            live?.showCursors = { [weak tv] in tv?.remoteCursors = $0 }
        }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if c.documentID != documentID || c.font != font {
            let isNewDocument = c.documentID != documentID
            c.documentID = documentID
            c.font = font
            tv.font = font
            if isNewDocument {
                c.dropRename()
                c.completion?.hide()
                c.hover?.hide()
                (tv as TypstTextView).occurrences = []
                DispatchQueue.main.async { [weak find] in find?.textDidChange() }
                c.endColorEdit()
                c.isRestoring = true
                if tv.string != text {
                    tv.string = text
                    tv.undoManager?.removeAllActions()
                }
                let state = state ?? EditorState()
                // Wait for the view to get its real width so line positions are final.
                DispatchQueue.main.async {
                    Self.restore(state, in: tv)
                    c.isRestoring = false
                    c.report()
                }
            }
            if let storage = tv.textStorage { c.style(storage) }
        }

        if c.diagnostics != diagnostics {
            c.diagnostics = diagnostics
            c.hover?.diagnostics = markDiagnostics(in: tv)
        }

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

    /// Tints and underlines diagnostic lines; returns each diagnostic with its line for hovering.
    private func markDiagnostics(in tv: NSTextView) -> [(range: NSRange, diagnostic: Diagnostic)] {
        guard let lm = tv.layoutManager else { return [] }
        var marked: [(range: NSRange, diagnostic: Diagnostic)] = []
        let s = tv.string as NSString
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: s.length))
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: s.length))
        for d in diagnostics {
            guard let range = Self.lineRange(d.line, in: s) else { continue }
            let tint: NSColor = d.severity == .error ? .systemRed : .systemYellow
            lm.addTemporaryAttributes([.backgroundColor: tint.withAlphaComponent(0.12)], forCharacterRange: range)
            let start = min(range.location + max(d.column - 1, 0), NSMaxRange(range))
            let underline = NSRange(location: start, length: NSMaxRange(range) - start)
            lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                                       .underlineColor: tint], forCharacterRange: underline)
            marked.append((range, d))
        }
        return marked
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
        tv.showFindIndicator(for: selection.length > 0 ? selection : r)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        /// The color panel is shared; only the editor that last opened it drives it.
        private static weak var colorOwner: Coordinator?
        weak var textView: NSTextView?
        weak var ruler: NSRulerView?
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
        private var colorPopover: NSPopover?
        var documentID = -1
        var font: NSFont?
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
            guard !isRestoring, let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer,
                  let scroll = tv.enclosingScrollView else { return }
            let selection = tv.selectedRange()
            let y = scroll.contentView.bounds.minY + scroll.contentInsets.top - tv.textContainerOrigin.y
            let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: container)
            let top = (tv.string as NSString).length == 0 ? 0 : lm.characterIndexForGlyph(at: glyph)
            onStateChange(EditorState(selection: selection.location, length: selection.length, top: top))
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard allowsRenameEdit(range, text) else { return false }
            let event = NSApp.currentEvent
            let typing = event?.type == .keyDown && event?.modifierFlags.contains(.command) == false
            lastTyped = typing && !isApplyingColor && completion?.isEditing != true && (text?.utf16.count ?? 2) <= 1 ? text : nil
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

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if let storage = tv.textStorage { style(storage) }
            // A change of the user's own ends a color session; the wheel's edits continue it.
            if !isApplyingColor { endColorEdit() }
            (tv as? TypstTextView)?.occurrences = []
            onChange(tv.string, isApplyingColor)
            find?.textDidChange()
            if renameSession != nil {
                if !isMirroring { mirrorRename() }
                lastTyped = nil
                return
            }
            if completion?.isEditing != true, !isApplyingRemote { completion?.textDidChange(typed: lastTyped) }
            lastTyped = nil
        }

        func style(_ storage: NSTextStorage) {
            guard let font else { return }
            var swatches: [ColorLiteral] = []
            if highlights {
                Highlighter.apply(to: storage, font: font)
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
            updateHighlights()
            report()
        }

        /// Matches the bracket at the caret right away and asks the server for the symbol's uses after a pause.
        private func updateHighlights() {
            guard let tv = textView as? TypstTextView else { return }
            let selection = tv.selectedRange()
            let s = tv.string as NSString
            tv.brackets = highlights && selection.length == 0 ? Self.matchingBrackets(at: selection.location, in: s) : []
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

        private static let pairs: [unichar: (partner: unichar, forward: Bool)] = [
            40: (41, true), 41: (40, false), 91: (93, true), 93: (91, false), 123: (125, true), 125: (123, false),
        ]

        /// The bracket or quote before or after the caret and the one it pairs with.
        static func matchingBrackets(at caret: Int, in s: NSString) -> [NSRange] {
            for index in [caret - 1, caret] where index >= 0 && index < s.length {
                let c = s.character(at: index)
                if c == 34, let partner = matchingQuote(at: index, in: s) {
                    return [NSRange(location: index, length: 1), NSRange(location: partner, length: 1)]
                }
                guard let pair = pairs[c] else { continue }
                var depth = 0
                var i = index
                // Bounded so huge files stay responsive.
                for _ in 0..<50_000 {
                    i += pair.forward ? 1 : -1
                    guard i >= 0, i < s.length else { break }
                    let x = s.character(at: i)
                    if x == c { depth += 1 }
                    if x == pair.partner {
                        if depth == 0 { return [NSRange(location: index, length: 1), NSRange(location: i, length: 1)] }
                        depth -= 1
                    }
                }
            }
            return []
        }

        /// Quotes pair up in order along their line, skipping escaped ones.
        private static func matchingQuote(at index: Int, in s: NSString) -> Int? {
            let line = s.lineRange(for: NSRange(location: index, length: 0))
            var quotes: [Int] = []
            var i = line.location
            while i < NSMaxRange(line) {
                let c = s.character(at: i)
                if c == 92 { i += 2; continue }
                if c == 34 { quotes.append(i) }
                i += 1
            }
            guard let k = quotes.firstIndex(of: index) else { return nil }
            let partner = k % 2 == 0 ? k + 1 : k - 1
            return quotes.indices.contains(partner) ? quotes[partner] : nil
        }

        // MARK: - Quick fixes

        /// Fixes for every diagnostic on the character's line.
        func quickFixes(at index: Int) -> [QuickFix] {
            guard let language, let hover else { return [] }
            return hover.diagnostics
                .filter { NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index }
                .flatMap { language.quickFixes(for: $0.diagnostic) }
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
            menu.popUp(positioning: nil, at: point, in: tv)
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
                    menu.popUp(positioning: nil, at: point, in: tv)
                    return
                }
                let usages = await language.goToDefinition(at: offset)
                guard let tv = textView, !usages.isEmpty else { return }
                if usages.count == 1 { return language.open(usages[0].location) }
                let menu = NSMenu()
                for usage in usages {
                    let item = ClosureMenuItem(title: usage.preview) { [weak language] in language?.open(usage.location) }
                    item.subtitle = "\(usage.file):\(usage.location.line + 1)"
                    menu.addItem(item)
                }
                let caret = tv.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
                guard let window = tv.window else { return }
                let point = tv.convert(window.convertPoint(fromScreen: NSPoint(x: caret.minX, y: caret.minY)), from: nil)
                menu.popUp(positioning: nil, at: point, in: tv)
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

            init(original: String, origin: Int, text: String, ranges: [NSRange], primary: Int, local: Bool = false) {
                self.original = original
                self.origin = origin
                self.text = text
                self.ranges = ranges
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
                // Only spots that still spell the name are edited along.
                var ranges = (uses + [target.range]).filter { NSMaxRange($0) <= s.length && s.substring(with: $0) == target.name }
                ranges = Array(Set(ranges.map { [$0.location, $0.length] })).map { NSRange(location: $0[0], length: $0[1]) }
                    .sorted { $0.location < $1.location }
                guard let primary = ranges.firstIndex(of: target.range) else { return NSSound.beep() }
                tv.breakUndoCoalescing()
                // The session's keystrokes become one rename step, registered when it's committed.
                renameSession = RenameSession(original: target.name, origin: target.range.location, text: before,
                                              ranges: ranges, primary: primary)
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
            for i in session.ranges.indices.reversed() where i != session.primary {
                let old = session.ranges[i]
                replaceForRename(old, with: name)
                let d = (name as NSString).length - old.length
                session.ranges[i].length = (name as NSString).length
                for j in session.ranges.indices where j > i { session.ranges[j].location += d }
            }
            // Uses before the edited one moved it; the caret follows.
            let primary = session.ranges[session.primary]
            isMirroring = true
            tv.setSelectedRange(NSRange(location: primary.location + min(max(caret, 0), primary.length), length: 0))
            isMirroring = false
            showRenameRanges()
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
            for i in ranges.indices.reversed() where (tv.string as NSString).substring(with: ranges[i]) != session.original {
                replaceForRename(ranges[i], with: session.original)
                let d = (session.original as NSString).length - ranges[i].length
                for j in ranges.indices where j > i { ranges[j].location += d }
            }
            renameSession = nil
            if session.registrationOff { tv.undoManager?.enableUndoRegistration() }
            showRenameRanges()
            let p = ranges[session.primary]
            tv.setSelectedRange(NSRange(location: p.location + min(max(caret, 0), p.length), length: 0))
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
            guard let tv = textView, let session = renameSession else { return }
            for i in session.ranges.indices.reversed() {
                let old = session.ranges[i]
                replaceForRename(old, with: name)
                let d = (name as NSString).length - old.length
                session.ranges[i].length = (name as NSString).length
                for j in session.ranges.indices where j > i { session.ranges[j].location += d }
            }
            isMirroring = true
            tv.setSelectedRange(NSRange(location: NSMaxRange(session.ranges[session.primary]), length: 0))
            isMirroring = false
            showRenameRanges()
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
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: tv)
        }

        private func showRefactorMessage(_ message: String) {
            guard let tv = textView as? TypstTextView else { return }
            NSSound.beep()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: Text(message).padding(10))
            popover.show(relativeTo: tv.caretAnchor(), of: tv, preferredEdge: .maxY)
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
