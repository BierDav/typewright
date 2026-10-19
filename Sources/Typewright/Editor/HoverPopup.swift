import AppKit
import SwiftUI

/// Errors and docs for what's under the pointer, in a panel under the hovered text.
@MainActor
final class HoverController {
    private weak var textView: NSTextView?
    var provider: ((Int) async -> (markdown: String, range: NSRange?)?)?
    var fixesProvider: ((Diagnostic) -> [QuickFix])?
    /// Diagnostics with the text they cover.
    var diagnostics: [(range: NSRange, diagnostic: Diagnostic)] = []

    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    /// The hovered text in view coordinates; the panel stays while the pointer is on it or the panel.
    private var anchor: NSRect = .null

    init(textView: NSTextView) {
        self.textView = textView
    }

    /// Called on every pointer move over the text.
    func pointerMoved(to point: NSPoint) {
        // Nothing pops up through the command palette, the search or anything else on top of the text.
        guard isTopmost(at: point) else {
            if panel != nil, !pointerInPanel { hide() }
            task?.cancel()
            return
        }
        if panel != nil {
            if keepsOpen(point) {
                hideTask?.cancel()
                hideTask = nil
            } else {
                scheduleHide()
            }
            return
        }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.show(at: point)
        }
    }

    /// The pointer left the text, possibly onto the panel, which is its own window.
    func pointerExited() {
        if panel != nil { scheduleHide() } else { task?.cancel() }
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
        let hit = content.hitTest(content.convert(point, from: tv))
        return hit.map { $0 === tv || $0.isDescendant(of: tv) } ?? false
    }

    /// On the hovered text, the panel, or the corridor between them.
    private func keepsOpen(_ point: NSPoint) -> Bool {
        if anchor.insetBy(dx: -3, dy: -3).contains(point) { return true }
        guard let tv = textView, let window = tv.window, let panel else { return false }
        let frame = tv.convert(window.convertFromScreen(panel.frame), from: nil)
        return anchor.union(frame).contains(point)
    }

    func hide() {
        task?.cancel()
        task = nil
        hideTask?.cancel()
        hideTask = nil
        pointerInPanel = false
        anchor = .null
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func show(at point: NSPoint) async {
        guard let tv = textView, isTopmost(at: point), let index = Self.character(at: point, in: tv) else { return }
        let errors = diagnostics.filter { NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index }
        let docs = await provider?(index)
        // Something may have opened on top while the server answered.
        guard !Task.isCancelled, errors.count + (docs == nil ? 0 : 1) > 0, isTopmost(at: point) else { return }

        let range = docs?.range ?? errors.first?.range ?? NSRange(location: index, length: 1)
        guard let lm = tv.layoutManager, let container = tv.textContainer else { return }
        var rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        // Long ranges wrap; only the hovered line matters for placement.
        if !rect.insetBy(dx: -3, dy: -3).contains(point) { rect = NSRect(x: point.x - 20, y: point.y - 9, width: 40, height: 18) }
        anchor = rect

        // Long docs get three times the room, as far as the screen allows.
        let screenWidth = tv.window?.screen?.visibleFrame.width ?? 1600
        let width = HoverContent.isLarge(docs?.markdown) ? min(HoverContent.baseWidth * 2.4, screenWidth - 40) : HoverContent.baseWidth
        var placedAbove = false
        weak var placedPanel: NSPanel?
        let content = HoverContent(errors: errors.map(\.diagnostic), markdown: docs?.markdown, width: width,
                                   fixes: fixesProvider ?? { _ in [] }, onClose: { [weak self] in self?.hide() },
                                   onSize: { size in
            // Fixes can arrive later, e.g. once Google Fonts' list loaded; the panel grows away from the text.
            guard let panel = placedPanel, size.height > 0, abs(panel.frame.height - size.height) > 0.5 else { return }
            var frame = panel.frame
            if !placedAbove { frame.origin.y = frame.maxY - size.height }
            frame.size = size
            panel.setFrame(frame, display: true)
        })
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        let panel = HoverPanel(contentRect: NSRect(origin: .zero, size: host.frame.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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
        hide()
        anchor = rect
        self.panel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    /// The character under the pointer, or nil past a line's end.
    private static func character(at point: NSPoint, in tv: NSTextView) -> Int? {
        guard let lm = tv.layoutManager, let container = tv.textContainer, lm.numberOfGlyphs > 0 else { return nil }
        let p = NSPoint(x: point.x - tv.textContainerOrigin.x, y: point.y - tv.textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: container)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -1, dy: 0).contains(p) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        return index < (tv.string as NSString).length ? index : nil
    }
}

/// Reports when the pointer leaves the panel.
private final class HoverPanel: NSPanel {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?

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
}

private struct HoverContent: View {
    let errors: [Diagnostic]
    let markdown: String?
    let width: CGFloat
    let fixes: (Diagnostic) -> [QuickFix]
    let onClose: () -> Void
    let onSize: (CGSize) -> Void

    static let baseWidth: CGFloat = 480

    /// Docs that would wrap into a tall, narrow column: lots of text or long code lines.
    static func isLarge(_ markdown: String?) -> Bool {
        guard let markdown else { return false }
        let longestLine = markdown.split(separator: "\n").map(\.count).max() ?? 0
        return markdown.count > 700 || longestLine > 90
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
                                        .buttonStyle(.link)
                                    } else {
                                        Label(fix.title, systemImage: fix.icon).foregroundStyle(.secondary)
                                    }
                                }
                                Text("⌥↩ shows these at the caret").font(.caption).foregroundStyle(.tertiary)
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
                ScrollView {
                    MarkdownView(blocks: MarkdownBlock.parse(markdown))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 640)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .frame(width: width, alignment: .leading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .onExitCommand(perform: onClose)
    }
}

/// The parts of tinymist's Markdown worth rendering: code blocks, headings, rules and paragraphs.
enum MarkdownBlock: Equatable {
    /// Code with its fence's language, like `typc` for code mode or `typ` for markup.
    case code(String, language: String)
    case heading(String)
    case rule
    case paragraph(String)
    /// A line that is only `![](url)`.
    case image(URL)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var language = ""
        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    flush()
                    code = []
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.hasPrefix("![]("), trimmed.hasSuffix(")"),
                      let url = URL(string: String(trimmed.dropFirst(4).dropLast())) {
                flush()
                blocks.append(.image(url))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"), language: language)) }
        flush()
        return blocks
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

private struct MarkdownView: View {
    let blocks: [MarkdownBlock]

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
                case .paragraph(let text):
                    Text(Self.inline(text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .image(let url):
                    ImageThumbnail(url: url)
                }
            }
        }
    }

    private static func code(_ text: String, language: String) -> AttributedString {
        switch language {
        case "typc": Highlighter.highlighted(text, code: true, size: 12)
        case "typ", "typst", "": Highlighter.highlighted(text, code: false, size: 12)
        default: AttributedString(text)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        // Markdown hard breaks ("\" at a line end) and soft wraps both join into flowing text.
        let joined = text.replacingOccurrences(of: "\\\n", with: "\n").replacingOccurrences(of: "\n", with: " ")
        return (try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(joined)
    }
}
