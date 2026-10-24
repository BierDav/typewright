import AppKit
import SwiftUI

/// Errors and docs for what's under the pointer, in a panel under the hovered text.
@MainActor
final class HoverController {
    private weak var textView: NSTextView?
    var provider: ((Int) async -> (markdown: String, range: NSRange?)?)?
    var fixesProvider: ((Diagnostic) -> [QuickFix])?
    /// Commands the docs link to, like tinymist replacing an outdated package's version; true when it ran.
    var command: ((URL) -> Bool)?
    /// Diagnostics with the text they cover.
    var diagnostics: [(range: NSRange, diagnostic: Diagnostic)] = [] {
        didSet { refreshDiagnostics() }
    }
    private var hoveredIndex: Int?
    private var documentationOnly = false

    private func refreshDiagnostics() {
        guard !documentationOnly, let index = hoveredIndex else { return }
        let errors = diagnostics.filter { NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index }.map(\.diagnostic)
        if let host = panel?.contentView as? PopupHostingView<HoverContent> {
            var content = host.rootView
            content.errors = errors
            if content.errors.isEmpty && content.markdown == nil { hide(); return }
            host.rootView = content
            if let tv = textView, let line = diagnostics.first(where: { NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index })
                .flatMap({ Self.rect(of: $0.range, in: tv) }) { anchor = anchor.union(line) }
        } else if !errors.isEmpty, let tv = textView,
                  let range = diagnostics.first(where: { NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index })?.range,
                  let rect = Self.rect(of: range, in: tv) {
            let pinned = isPinned
            present(errors: errors, markdown: nil, below: rect, at: index)
            isPinned = pinned && panel != nil
        }
    }

    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    /// The hovered text in view coordinates; the panel stays while the pointer is on it or the panel.
    private var anchor: NSRect = .null
    private var dismissal: (any NSObjectProtocol)?
    /// Links followed in the shown docs.
    private var trail: DocsTrail?

    init(textView: NSTextView) {
        self.textView = textView
        dismissal = Popups.observe(window: { [weak textView] in textView?.window }) { [weak self] in self?.hide() }
        Popups.onBack(self, window: { [weak textView] in textView?.window }) { [weak self] in self?.trail?.back() ?? false }
    }

    deinit { if let dismissal { NotificationCenter.default.removeObserver(dismissal) } }

    /// Called on every pointer move over the text.
    func pointerMoved(to point: NSPoint) {
        if isPinned { return }
        // Nothing pops up through the command palette, the search or anything else on top of the text.
        guard isTopmost(at: point) else {
            if panel != nil, !pointerInPanel { hide() }
            task?.cancel()
            return
        }
        if panel != nil {
            if isPinned { return }
            if keepsOpen(point) {
                hideTask?.cancel()
                hideTask = nil
            } else {
                scheduleHide()
            }
            return
        }
        task?.cancel()
        hoveredIndex = nil
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.show(at: point)
        }
    }

    /// The pointer left the text, possibly onto the panel, which is its own window.
    func pointerExited() {
        if isPinned { return }
        if panel != nil { scheduleHide() } else { task?.cancel(); hoveredIndex = nil }
    }

    private var hideTask: Task<Void, Never>?
    private var pointerInPanel = false

    /// A short grace period lets the pointer cross other text on its way to the panel.
    private func scheduleHide() {
        guard hideTask == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.pointerInPanel else { return }
            self.hide()
        }
    }

    private func isTopmost(at point: NSPoint) -> Bool {
        guard let tv = textView, let content = tv.window?.contentView else { return false }
        // hitTest takes the superview's coordinates; the flipped hosting view's own ones would mirror the point.
        let hit = content.hitTest(content.superview?.convert(point, from: tv) ?? tv.convert(point, to: nil))
        return hit.map { $0 === tv || $0.isDescendant(of: tv) } ?? false
    }

    /// On the hovered text, the panel, or the corridor between them.
    private func keepsOpen(_ point: NSPoint) -> Bool {
        if anchor.insetBy(dx: -3, dy: -3).contains(point) { return true }
        guard let tv = textView, let window = tv.window, let panel else { return false }
        let frame = tv.convert(window.convertFromScreen(panel.frame), from: nil)
        return anchor.union(frame).contains(point)
    }

    private var monitor: Any?

    /// While docs show, F1 closes them, Esc goes back from a followed link or closes them, and any other key
    /// or click outside them closes them. A click inside pins them. Watched app-wide, as shortcuts like ⌘K
    /// never reach the text view and the panel takes key once clicked.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel else { return event }
        let inPanel = event.window === panel
        if event.type == .keyDown {
            if KeyLayout.current.shortcuts.documentation.matches(event) {
                hide()
                return nil
            }
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                if trail?.back() != true { hide() }
                return nil
            }
            // Typing in the panel, like ⌘C, stays there.
            if inPanel { return event }
            hide()
            return event
        }
        if inPanel {
            isPinned = true
            hideTask?.cancel()
            hideTask = nil
            return event
        }
        // The mouse's back button steps back through followed links first, see `Popups.back`.
        if event.type == .otherMouseDown, event.buttonNumber == 3, trail?.canGoBack == true { return event }
        hide()
        return event
    }

    /// True when a panel was open.
    @discardableResult
    func hide() -> Bool {
        task?.cancel()
        task = nil
        hideTask?.cancel()
        hideTask = nil
        pointerInPanel = false
        isPinned = false
        anchor = .null
        hoveredIndex = nil
        documentationOnly = false
        trail = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let panel else { return false }
        self.panel = nil
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // A click made it key to select text; typing goes back to the editor.
        if panel.isKeyWindow { parent?.makeKey() }
        return true
    }

    private func show(at point: NSPoint) async {
        guard let tv = textView, isTopmost(at: point), let index = Self.character(at: point, in: tv, onGlyph: false) else { return }
        hoveredIndex = index
        documentationOnly = false
        let errors = diagnostics.filter { NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index }
        if let range = errors.first?.range, let rect = Self.rect(of: range, in: tv) {
            present(errors: errors.map(\.diagnostic), markdown: nil, below: rect, at: index)
        }
        let editor = tv as? TypstTextView
        let collapsed = editor?.collapsedSegment(at: point)
        let source = collapsed.flatMap { editor?.collapsedSourceTooltip(for: $0) }
        if let collapsed, let source, let rect = editor?.highlightBoxes(for: collapsed).first(where: { $0.contains(point) }) {
            present(errors: errors.map(\.diagnostic), markdown: source, below: rect, at: index)
        }
        guard let symbol = Self.character(at: point, in: tv) else { return }
        let docs = await provider?(symbol)
        // Something may have opened on top while the server answered.
        guard !Task.isCancelled, docs != nil, isTopmost(at: point) else { return }
        // Docs only for the glyph under the pointer, not a symbol its range stops short of.
        if let range = docs?.range, !NSLocationInRange(symbol, range) { return }

        let currentErrors = diagnostics.filter { NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index }
        let range = collapsed ?? docs?.range ?? currentErrors.first?.range ?? NSRange(location: index, length: 1)
        guard var rect = Self.rect(of: range, in: tv) else { return }
        // Long ranges wrap; only the hovered line matters for placement.
        if !rect.insetBy(dx: -3, dy: -3).contains(point) { rect = NSRect(x: point.x - 20, y: point.y - 9, width: 40, height: 18) }
        let pinned = isPinned
        let markdown = [source, docs?.markdown].compactMap { $0 }.joined(separator: "\n\n---\n\n")
        present(errors: currentErrors.map(\.diagnostic), markdown: markdown, below: rect, at: index)
        isPinned = pinned && panel != nil
        // The errors cover their line, so moving along it keeps them open.
        if panel != nil, let line = currentErrors.first.flatMap({ Self.rect(of: $0.range, in: tv) }) { anchor = anchor.union(line) }
    }

    /// F1: hides shown or loading docs, or shows and pins the docs at the caret.
    /// Pinned docs only ignore the pointer; keys, clicks and scrolling still close them.
    func toggleAtCaret() {
        let hasDocs = (panel?.contentView as? PopupHostingView<HoverContent>)?.rootView.markdown != nil
        if documentationOnly || hasDocs { hide(); return }
        if panel != nil { hide() }
        showAtCaret()
    }

    /// Documentation of the symbol at the caret.
    private func showAtCaret() {
        guard let tv = textView else { return }
        let index = tv.selectedRange().location
        task?.cancel()
        // Pinned already, so pointer moves while the server answers neither cancel it nor show their own.
        isPinned = true
        documentationOnly = true
        hoveredIndex = index
        task = Task { [weak self] in
            // The caret may sit just after the symbol.
            var docs = await self?.provider?(index)
            if docs == nil, index > 0 { docs = await self?.provider?(index - 1) }
            guard let self, !Task.isCancelled else { return }
            guard let tv = self.textView, tv.selectedRange().location == index else { return self.isPinned = false }
            // Docs only for the symbol the caret touches, not one across a space or an operator.
            if let range = docs?.range, !(range.location <= index && index <= NSMaxRange(range)) {
                docs = nil
            }
            guard let docs else {
                self.isPinned = false
                self.documentationOnly = false
                self.hoveredIndex = nil
                return NSSound.beep()
            }
            let range = docs.range ?? NSRange(location: index, length: 0)
            let caret = (tv as? TypstTextView)?.caretAnchor() ?? .zero
            var rect = Self.rect(of: range, in: tv) ?? caret
            if !rect.insetBy(dx: -3, dy: -3).intersects(caret) { rect = caret }
            self.present(errors: [], markdown: docs.markdown, below: rect, at: index)
            self.isPinned = self.panel != nil
        }
    }

    /// Shown from the keyboard, so pointer moves don't close it.
    private(set) var isPinned = false
    var isShown: Bool { panel != nil }

    private static func rect(of range: NSRange, in tv: NSTextView) -> NSRect? {
        guard let lm = tv.layoutManager, let container = tv.textContainer, NSMaxRange(range) <= (tv.string as NSString).length
        else { return nil }
        let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        return rect.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
    }

    private func present(errors: [Diagnostic], markdown: String?, below rect: NSRect, at index: Int) {
        guard let tv = textView, !Popups.isCovered(tv.window) else { hide(); return }
        anchor = rect

        let width = HoverContent.width(for: markdown, screen: tv.window?.screen)
        var placedAbove = false
        weak var placedPanel: NSPanel?
        let trail = DocsTrail()
        let content = HoverContent(errors: errors, markdown: markdown, width: width,
                                   fixes: fixesProvider ?? { _ in [] }, onClose: { [weak self] in self?.hide() },
                                   command: command.map { run in { [weak self] url in
                                       if run(url) { self?.hide() }
                                   } },
                                   onSize: { size in
            // Fixes can arrive later, e.g. once Google Fonts' list loaded; the panel grows away from the text.
            guard let panel = placedPanel, size.height > 0, abs(panel.frame.height - size.height) > 0.5 else { return }
            var frame = panel.frame
            if !placedAbove { frame.origin.y = frame.maxY - size.height }
            frame.size = size
            panel.setFrame(frame, display: true)
        }, trail: trail)
        let host = PopupHostingView(rootView: content)
        host.frame.size = host.fittingSize
        // Takes key on a click, so its text can be selected and copied.
        let panel = HoverPanel(contentRect: NSRect(origin: .zero, size: host.frame.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.becomesKey = true
        panel.onCancel = { [weak self] in self?.hide() }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = host
        panel.onEnter = { [weak self] in
            self?.pointerInPanel = true
            self?.hideTask?.cancel()
            self?.hideTask = nil
        }
        panel.onExit = { [weak self] in
            self?.pointerInPanel = false
            if self?.isPinned == true { return }
            // Moves back over the text decide from there.
            self?.scheduleHide()
        }

        guard let window = tv.window else { return }
        let screenRect = window.convertToScreen(tv.convert(rect, to: nil))
        let screen = window.screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: screenRect.minX, y: screenRect.minY - host.frame.height - 2)
        if origin.y < screen.minY {
            origin.y = screenRect.maxY + 2
            placedAbove = true
        }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - host.frame.width)
        panel.setFrameOrigin(origin)
        placedPanel = panel
        // Replacing the panel must keep its pending documentation request alive.
        let request = task
        let documentationOnly = self.documentationOnly
        task = nil
        hide()
        task = request
        self.documentationOnly = documentationOnly
        anchor = rect
        self.trail = trail
        self.panel = panel
        hoveredIndex = index
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // `self?.handle(event) ?? event` would turn a swallowed Esc (nil) back into the event.
            guard let self else { return event }
            return self.handle(event)
        }
    }

    /// Diagnostics cover their line; documentation requires a glyph under the pointer.
    private static func character(at point: NSPoint, in tv: NSTextView, onGlyph: Bool = true) -> Int? {
        guard let lm = tv.layoutManager, let container = tv.textContainer, lm.numberOfGlyphs > 0 else { return nil }
        let p = NSPoint(x: point.x - tv.textContainerOrigin.x, y: point.y - tv.textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: container)
        let rect = onGlyph ? lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            : lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard rect.insetBy(dx: -1, dy: 0).contains(p) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        let source = tv.string as NSString
        guard index < source.length else { return nil }
        if onGlyph, let scalar = UnicodeScalar(source.character(at: index)), CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
        return index
    }
}

/// Takes the click that makes its popup key, instead of only activating with it.
final class PopupHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reports when the pointer leaves the panel.
final class HoverPanel: NSPanel {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// Esc while it's key.
    var onCancel: (() -> Void)?
    /// Borderless panels can't take key by default, which selecting and copying text needs.
    var becomesKey = false
    private var tracking: NSTrackingArea?

    override var canBecomeKey: Bool { becomesKey }

    // Key before the click is handled, so the first click already selects text or presses a link.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, becomesKey, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }

    override var contentView: NSView? {
        didSet {
            guard let view = contentView else { return }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
            view.addTrackingArea(area)
            tracking = area
        }
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

struct HoverContent: View {
    var errors: [Diagnostic]
    let markdown: String?
    let width: CGFloat
    let fixes: (Diagnostic) -> [QuickFix]
    let onClose: () -> Void
    /// Runs a link that is a command, like tinymist replacing a package version.
    var command: ((URL) -> Void)?
    let onSize: (CGSize) -> Void
    /// The links followed in function docs, for popups that step back on Esc.
    var trail: DocsTrail?

    static let baseWidth: CGFloat = 480

    /// Docs that would wrap into a tall, narrow column: lots of text or long code lines.
    static func isLarge(_ markdown: String?) -> Bool {
        guard let markdown else { return false }
        let longestLine = markdown.split(separator: "\n").map(\.count).max() ?? 0
        return markdown.count > 700 || longestLine > 90
    }

    /// The same for hovers and a completion's docs, so F1 looks alike from both.
    static func width(for markdown: String?, screen: NSScreen?) -> CGFloat {
        // Function docs fold what's long, so they stay narrow and easy to read.
        guard isLarge(markdown), FunctionDocs(markdown: markdown!) == nil else { return baseWidth }
        return min(baseWidth * 1.4, (screen?.visibleFrame.width ?? 1600) - 40)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(errors.enumerated()), id: \.offset) { _, d in
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        // Read here, so they update when e.g. a download finishes.
                        let fixes = fixes(d)
                        if !fixes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(fixes) { fix in
                                    if let run = fix.run {
                                        Button {
                                            run()
                                            onClose()
                                        } label: {
                                            Label(fix.title, systemImage: fix.icon)
                                        }
                                        .buttonStyle(FixButtonStyle())
                                    } else {
                                        Label(fix.title, systemImage: fix.icon).foregroundStyle(.secondary)
                                    }
                                }
                                Text("\(KeyLayout.current.shortcuts.contextActions.display) shows these at the caret")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } icon: {
                    Image(systemName: d.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(d.severity == .error ? .red : .yellow)
                }
                .padding(10)
            }
            if !errors.isEmpty && markdown != nil { Divider() }
            if let markdown {
                // Function docs scroll under their own pinned header.
                if let docs = FunctionDocs(markdown: markdown) {
                    FunctionDocsView(docs: docs, trail: trail)
                } else {
                    ScrollView {
                        MarkdownView(blocks: MarkdownBlock.parse(markdown))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 640)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .environment(\.openURL, OpenURLAction { url in
            // The system has no app for tinymist's command links; they run here or do nothing.
            guard url.scheme == "command" else { return .systemAction }
            command?(url)
            return .handled
        })
        .frame(width: width, alignment: .leading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .onExitCommand(perform: onClose)
    }
}

/// The parts of tinymist's Markdown worth rendering: code blocks, headings, rules, lists and paragraphs.
enum MarkdownBlock: Equatable {
    /// Code with its fence's language, like `typc` for code mode or `typ` for markup.
    case code(String, language: String)
    case heading(String)
    case rule
    case paragraph(String)
    /// Items with their markers, `•` or `1.`.
    case list([String], markers: [String])
    /// A line that is only `![](url)`.
    case image(URL)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [String] = []
        var markers: [String] = []
        var code: [String]?
        var fence = 0
        var language = ""
        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items, markers: markers)) }
            items = []
            markers = []
        }
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ticks = trimmed.prefix { $0 == "`" }.count
            if let lines = code {
                // Only a fence at least as long closes, so ```` blocks can show ``` ones.
                if ticks >= fence, trimmed.allSatisfy({ $0 == "`" }) {
                    blocks.append(.code(lines.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    code?.append(line)
                }
            } else if ticks >= 3 {
                flush()
                flushList()
                code = []
                fence = ticks
                language = String(trimmed.dropFirst(ticks)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("![]("), trimmed.hasSuffix(")"),
                      let url = URL(string: String(trimmed.dropFirst(4).dropLast())) {
                flush()
                flushList()
                blocks.append(.image(url))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                flushList()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("#") {
                flush()
                flushList()
                blocks.append(.heading(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if let marker = listMarker(trimmed) {
                flush()
                let shown = marker == "-" || marker == "*" ? "•" : marker
                if let last = markers.last, (last == "•") != (shown == "•") { flushList() }
                items.append(String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
                markers.append(shown)
            } else if trimmed.isEmpty {
                flush()
            } else if !items.isEmpty, paragraph.isEmpty, line.first?.isWhitespace == true {
                items[items.count - 1] += " " + trimmed
            } else {
                flushList()
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"), language: language)) }
        flush()
        flushList()
        return blocks
    }

    /// `-`, `*` or `1.` followed by a space.
    private static func listMarker(_ line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return String(line.prefix(1)) }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return digits + "."
    }
}

/// An image with its pixel size, fitted into the popup.
private struct ImageThumbnail: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            let rep = image.representations.first
            let pixels = rep.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, .infinity), maxHeight: min(image.size.height, 280))
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                Text(pixels.width > 0 ? "\(url.lastPathComponent) · \(Int(pixels.width)) × \(Int(pixels.height))" : url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label(url.lastPathComponent, systemImage: "photo").foregroundStyle(.secondary)
        }
    }
}

struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// Names in inline code that link to their own docs.
    var links: (String) -> Bool = { _ in false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let text, let language):
                    Text(Self.code(text, language: language))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                case .heading(let text):
                    Text(text).font(.callout.weight(.semibold)).padding(.top, 4)
                case .rule:
                    Divider()
                case .list(let items, let markers):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(markers[i]).foregroundStyle(.secondary)
                                InlineText(text: Self.inline(item, links: links))
                            }
                        }
                    }
                case .paragraph(let text):
                    InlineText(text: Self.inline(text, links: links))
                case .image(let url):
                    ImageThumbnail(url: url)
                }
            }
        }
    }

    private static func code(_ text: String, language: String) -> AttributedString {
        if language.split(separator: " ").first.map(String.init) == SolvengSupport.tag {
            return solveng(text)
        }
        return switch language {
        case "typc": Highlighter.highlighted(text, code: true, size: 12)
        case "typ", "typst", "": Highlighter.highlighted(text, code: false, size: 12)
        default: AttributedString(text)
        }
    }

    private static func solveng(_ text: String) -> AttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let storage = NSTextStorage(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        InjectedLanguages.color(SolvengSupport.mathTokens(text), in: storage, at: 0, length: storage.length, font: font)
        return (try? AttributedString(storage, including: \.appKit)) ?? AttributedString(text)
    }

    /// The scheme of links to another function's docs, `typewright-docs:defined`.
    static let docsScheme = "typewright-docs"

    /// Inline Markdown with its code highlighted as typst, and names `links` accepts linked to their docs.
    static func inline(_ text: String, links: (String) -> Bool = { _ in false }) -> AttributedString {
        // Markdown hard breaks ("\" at a line end) and soft wraps both join into flowing text.
        // tinymist doubles bold that's already Markdown, `**x**` → `****x****`.
        let joined = text.replacingOccurrences(of: "\\\n", with: "\n").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "****", with: "**")
        guard let parsed = try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(joined) }
        var result = AttributedString()
        for run in parsed.runs {
            let part = AttributedString(parsed[run.range])
            guard run.inlinePresentationIntent?.contains(.code) == true else {
                result += part
                continue
            }
            let code = String(part.characters)
            // `#clear(all: true)` and `$t =$` are markup, `heading.where(level: 1)` is code.
            var shown = Highlighter.highlighted(code, code: !(code.hasPrefix("#") || code.hasPrefix("$")), size: 12)
            shown.inlinePresentationIntent = .code
            let hashes = code.prefix { $0 == "#" }
            let name = code.dropFirst(hashes.count).prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if !name.isEmpty, links(String(name)), let url = URL(string: "\(docsScheme):\(name)") {
                // Only the name is the link, so the rest keeps its colours.
                let start = shown.characters.index(shown.startIndex, offsetBy: hashes.count)
                let range = start..<shown.characters.index(start, offsetBy: name.count)
                shown[range].link = url
                // The link's colour, not the highlighter's, and underlined, as function names are blue too.
                shown[range].foregroundColor = nil
                shown[range].underlineStyle = .single
            }
            result += shown
        }
        return result
    }
}

/// The link look, with hover and the hand cursor working while the popup isn't key.
private struct FixButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: .linkColor))
            .opacity(configuration.isPressed ? 0.5 : hovered ? 0.75 : 1)
            .contentShape(Rectangle())
            .background(PointerTracker(hovered: $hovered))
    }
}

/// SwiftUI's hover and AppKit's cursor rects only apply in the key window; tracking areas always do.
private struct PointerTracker: NSViewRepresentable {
    @Binding var hovered: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = { hovered = $0 }
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = { hovered = $0 } }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        // Clicks go to the button above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) {
            onChange?(true)
            NSCursor.pointingHand.set()
        }

        override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }

        override func mouseExited(with event: NSEvent) {
            onChange?(false)
            NSCursor.arrow.set()
        }
    }
}
