import AppKit
import SwiftUI

/// A function's docs, split up so they can be shown at a glance: what it does, an example, and its parameters.
/// Read from tinymist's hover Markdown, which solveng's functions are written as too, so both look the same.
struct FunctionDocs: Equatable {
    struct Parameter: Equatable {
        /// `..body` for a rest parameter.
        let name: String
        let type: String
        let `default`: String
        /// The first paragraph of its docs.
        let summary: String
    }

    let name: String
    /// Nil when tinymist doesn't know, `any`.
    let returns: String?
    /// The first paragraph.
    let summary: String
    /// The first code block, shown under the summary.
    let example: (code: String, language: String)?
    /// Everything else of the description.
    let details: String
    let parameters: [Parameter]

    static func == (a: FunctionDocs, b: FunctionDocs) -> Bool {
        a.name == b.name && a.returns == b.returns && a.summary == b.summary && a.example?.code == b.example?.code
            && a.example?.language == b.example?.language && a.details == b.details && a.parameters == b.parameters
    }

    /// Nil unless the Markdown starts with a `let name(…)` signature, as tinymist shows functions.
    init?(markdown: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[open].hasPrefix("```"),
              let close = lines[(open + 1)...].firstIndex(where: { $0.hasPrefix("```") }) else { return nil }
        let signature = lines[(open + 1)..<close].joined(separator: "\n")
        guard signature.hasPrefix("let "), let paren = signature.firstIndex(of: "("),
              let end = Self.matching(signature, from: paren) else { return nil }
        name = String(signature[signature.index(signature.startIndex, offsetBy: 4)..<paren])
        guard !name.isEmpty, !name.contains(" ") else { return nil }
        let after = signature[signature.index(after: end)...].trimmingCharacters(in: CharacterSet(charactersIn: " ;\n"))
        let returned = after.hasPrefix("= ") || after.hasPrefix("->") ? String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces) : ""
        returns = returned.isEmpty || returned == "any" ? nil : returned

        var rest = Array(lines[(close + 1)...])
        let sectionStarts: Set<String> = ["# Positional Parameters", "# Rest Parameters", "# Named Parameters"]
        let split = Self.outsideCode(rest).first { sectionStarts.contains(rest[$0].trimmingCharacters(in: .whitespaces)) }
        let sections = split.map { Self.sections(Array(rest[$0...])) } ?? [:]
        if let split { rest = Array(rest[..<split]) }

        // The signature's parameters, completed by tinymist's sections and the docs' own `- name (types): …` list.
        let listed = Self.documentedList(rest)
        rest = rest.enumerated().filter { !listed.lines.contains($0.offset) }.map(\.element)
        let inner = String(signature[signature.index(after: paren)..<end])
        let parameters = Self.splitTop(inner).compactMap { part -> Parameter? in
            let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { return nil }
            let (head, value) = part.range(of: " = ").map { (String(part[..<$0.lowerBound]), String(part[$0.upperBound...])) } ?? (part, "")
            let (name, type) = head.range(of: ":").map {
                (String(head[..<$0.lowerBound]), String(head[$0.upperBound...]).trimmingCharacters(in: .whitespaces))
            } ?? (head, "")
            let bare = String(name.drop { $0 == "." })
            let section = sections[bare]
            let summary = section?.summary.isEmpty == false ? section!.summary : listed.docs[bare] ?? ""
            let shownType = section?.type.isEmpty == false ? section!.type : type
            return Parameter(name: name, type: shownType == "any" ? "" : shownType, default: value, summary: summary)
        }
        // Rest and documented parameters first, in the signature's order; undocumented ones last.
        self.parameters = parameters.filter { $0.name.hasPrefix("..") || !$0.summary.isEmpty }
            + parameters.filter { !$0.name.hasPrefix("..") && $0.summary.isEmpty }

        // The description: its first paragraph, its first example, and the rest.
        while let first = rest.first, ["", "---"].contains(first.trimmingCharacters(in: .whitespaces)) { rest.removeFirst() }
        var blocks = MarkdownBlock.parse(rest.joined(separator: "\n"))
        if case .paragraph(let text) = blocks.first {
            summary = text
            blocks.removeFirst()
        } else {
            summary = ""
        }
        if let i = blocks.firstIndex(where: { if case .code = $0 { true } else { false } }), case .code(let code, let language) = blocks[i] {
            example = (code, language)
            blocks.remove(at: i)
            // Its "Example" heading goes with it.
            if i > 0, case .heading(let h) = blocks[i - 1], h.lowercased().hasPrefix("example") { blocks.remove(at: i - 1) }
        } else {
            example = nil
        }
        details = blocks.map(\.markdown).joined(separator: "\n\n")
    }

    /// solveng's own docs of one of its functions, in the shape tinymist shows functions.
    static func markdown(for f: SolvengSupport.Function) -> String {
        let all = f.positional + f.named
        let type = { (p: SolvengSupport.Parameter) in p.types.replacingOccurrences(of: ", ", with: " | ") }
        let signature = all.map { p in
            let name = (p.variadic ? ".." : "") + p.name
            let typed = p.types.isEmpty ? name : "\(name): \(type(p))"
            return "  " + typed + (p.default.isEmpty ? "" : " = \(p.default)") + ","
        }
        var lines = ["```typc", "let \(f.name)("] + signature + [") = any;", "```", "", "---", "", f.doc, ""]
        for (title, group) in [("# Positional Parameters", f.positional), ("# Named Parameters", f.named)] where !group.isEmpty {
            lines += [title, ""]
            for p in group {
                lines += ["## \(p.name)", "", "```typc", "type: \(type(p))", "```", "", p.doc, ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// The index of the parenthesis closing the one at `open`.
    private static func matching(_ s: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var i = open
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" { inString.toggle() }
            if !inString, "([{".contains(c) { depth += 1 }
            if !inString, ")]}".contains(c) {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Splits `a, b: (1, 2), c` at the top level.
    static func splitTop(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        for c in s {
            if c == "\"" { inString.toggle() }
            if !inString, "([{".contains(c) { depth += 1 }
            if !inString, ")]}".contains(c) { depth -= 1 }
            if !inString, depth == 0, c == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    /// Indices of lines outside fenced code.
    private static func outsideCode(_ lines: [String]) -> [Int] {
        var fence = 0
        return lines.indices.filter { i in
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let ticks = trimmed.prefix { $0 == "`" }.count
            if fence > 0 {
                if ticks >= fence, trimmed.allSatisfy({ $0 == "`" }) { fence = 0 }
                return false
            }
            if ticks >= 3 { fence = ticks; return false }
            return true
        }
    }

    /// tinymist's `## name (named)` sections: a `type: …` block and docs, of which the first paragraph is kept.
    private static func sections(_ lines: [String]) -> [String: (type: String, summary: String)] {
        let outside = Set(outsideCode(lines))
        var result: [String: (type: String, summary: String)] = [:]
        var name: String?
        var type = ""
        var body: [String] = []
        func finish() {
            guard let name else { return }
            let paragraph = body.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            result[name] = (type, paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
        }
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if outside.contains(i), trimmed.hasPrefix("## ") {
                finish()
                var heading = String(trimmed.dropFirst(3))
                for suffix in [" (named)", " (positional)", " (rest)"] where heading.hasSuffix(suffix) { heading.removeLast(suffix.count) }
                name = heading
                type = ""
                body = []
                // The type block right under the heading.
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j + 2 < lines.count, lines[j].hasPrefix("```"), lines[j + 1].hasPrefix("type: "), lines[j + 2] == "```" {
                    type = String(lines[j + 1].dropFirst(6))
                    i = j + 3
                    continue
                }
            } else if outside.contains(i), trimmed.hasPrefix("# ") {
                finish()
                name = nil
            } else if name != nil {
                // Code ends a paragraph.
                body.append(outside.contains(i) ? lines[i] : "")
            }
            i += 1
        }
        finish()
        return result
    }

    /// The docs' own parameter list, like `- inherit (auto, bool): …` or `- digits, separator, … (auto): …`, and its lines.
    private static func documentedList(_ lines: [String]) -> (docs: [String: String], lines: Set<Int>) {
        var docs: [String: String] = [:]
        var taken: Set<Int> = []
        for i in outsideCode(lines) {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { continue }
            let item = trimmed.dropFirst(2)
            guard let open = item.range(of: " ("), let close = item.range(of: "): ", range: open.upperBound..<item.endIndex) else { continue }
            let names = item[..<open.lowerBound].split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".…`")))
            }.filter { !$0.isEmpty && !$0.contains(" ") }
            guard !names.isEmpty else { continue }
            for name in names { docs[name] = String(item[close.upperBound...]) }
            taken.insert(i)
        }
        return (docs, taken)
    }
}

extension MarkdownBlock {
    /// Back to Markdown, for what's parsed apart and shown again.
    var markdown: String {
        switch self {
        case .code(let code, let language): "````\(language)\n\(code)\n````"
        case .heading(let text): "## \(text)"
        case .rule: "---"
        case .paragraph(let text): text
        case .list(let items, let markers): zip(markers, items).map { ($0 == "•" ? "-" : $0) + " " + $1 }.joined(separator: "\n")
        case .image(let url): "![](\(url.absoluteString))"
        }
    }
}

/// The docs reached through links, so the popup's owner can step back on Esc and the mouse's back button.
@MainActor @Observable
final class DocsTrail {
    /// Followed links, the shown docs last.
    private(set) var pages: [FunctionDocs] = []
    /// Whether the last step followed a link, which slides pages in from the right.
    private(set) var forward = true

    var canGoBack: Bool { !pages.isEmpty }

    func follow(_ docs: FunctionDocs) {
        step(forward: true) { $0.pages.append(docs) }
    }

    /// False when there's nothing to go back to.
    @discardableResult
    func back() -> Bool {
        guard canGoBack else { return false }
        step(forward: false) { $0.pages.removeLast() }
        return true
    }

    /// A changed direction renders first, as the leaving page slides with the transition it was last drawn with.
    private func step(forward: Bool, _ change: @escaping @MainActor (DocsTrail) -> Void) {
        let animated: @MainActor () -> Void = { withAnimation(.smooth(duration: 0.25)) { change(self) } }
        guard forward != self.forward else { return animated() }
        self.forward = forward
        Task { @MainActor in animated() }
    }
}

/// A function's docs: name, what it does, an example, then its parameters as a table.
/// solveng's functions named in them link to their docs, shown in place with a way back.
struct FunctionDocsView: View {
    let docs: FunctionDocs
    /// Passed in by popups that step back themselves.
    var trail: DocsTrail?
    @State private var ownTrail = DocsTrail()

    private var pages: DocsTrail { trail ?? ownTrail }
    private var shown: FunctionDocs { pages.pages.last ?? docs }

    private var slide: AnyTransition {
        let forward = pages.forward
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                // Pinned, so the way back and the name stay while the docs scroll.
                VStack(alignment: .leading, spacing: 6) {
                    if pages.canGoBack {
                        Button {
                            pages.back()
                        } label: {
                            Label((pages.pages.dropLast().last ?? docs).name, systemImage: "chevron.backward")
                        }
                        .buttonStyle(.link)
                        .pointerStyle(.link)
                    }
                    header
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(pages.pages.count)
                .transition(slide)
                Divider()
                ScrollView {
                    Color.clear.frame(height: 0).id("top")
                    content
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(pages.pages.count)
                        .transition(slide)
                }
                .frame(maxHeight: 600)
                .fixedSize(horizontal: false, vertical: true)
            }
            .clipped()
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == MarkdownView.docsScheme, let target = Self.solveng(url.absoluteString
                    .dropFirst(MarkdownView.docsScheme.count + 1)) else { return .systemAction }
                pages.follow(target)
                proxy.scrollTo("top", anchor: .top)
                return .handled
            })
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !shown.summary.isEmpty {
                InlineText(text: MarkdownView.inline(shown.summary, links: links))
            }
            if let example = shown.example {
                MarkdownView(blocks: [.code(example.code, language: example.language)])
            }
            if !shown.details.isEmpty {
                MarkdownView(blocks: MarkdownBlock.parse(shown.details), links: links)
            }
            if !shown.parameters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Parameters").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    parameterGrid(shown.parameters)
                }
                .padding(.top, 2)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(shown.name).font(.system(size: 14, weight: .semibold, design: .monospaced))
            if let returns = shown.returns {
                Text("→ \(returns)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    /// Inside solveng's docs, its other functions; not names of this one's parameters, like `digits`.
    private var links: (String) -> Bool {
        let current = shown.name
        guard SolvengSupport.function(current) != nil else { return { _ in false } }
        let parameters = Set(shown.parameters.map { String($0.name.drop { $0 == "." }) })
        return { $0 != current && !parameters.contains($0) && SolvengSupport.function($0) != nil }
    }

    private static func solveng(_ name: Substring) -> FunctionDocs? {
        SolvengSupport.function(String(name)).flatMap { FunctionDocs(markdown: FunctionDocs.markdown(for: $0)) }
    }

    private func parameterGrid(_ parameters: [FunctionDocs.Parameter]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(parameters, id: \.name) { p in
                GridRow {
                    Text(p.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tint)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        if !p.type.isEmpty || !p.default.isEmpty {
                            Text(Self.typeLine(p))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !p.summary.isEmpty {
                            InlineText(text: MarkdownView.inline(p.summary, links: links))
                        }
                    }
                }
            }
        }
    }

    /// `auto | int = 4`; solveng's `auto (4)` defaults show what `auto` stands for.
    private static func typeLine(_ p: FunctionDocs.Parameter) -> String {
        var value = p.default
        if value.hasPrefix("auto ("), value.hasSuffix(")") { value = String(value.dropFirst(6).dropLast()) }
        if value.isEmpty { return p.type }
        return p.type.isEmpty ? "= \(value)" : "\(p.type) = \(value)"
    }
}

/// Selectable text; with links in an AppKit text view, as SwiftUI's selection takes their clicks.
struct InlineText: View {
    let text: AttributedString

    var body: some View {
        if text.runs.contains(where: { $0.link != nil }) {
            LinkText(text: text)
        } else {
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// Selectable text whose links open through the environment's `openURL`, with the hand cursor over them.
private struct LinkText: NSViewRepresentable {
    let text: AttributedString

    func makeNSView(context: Context) -> LinkTextView {
        let view = LinkTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: LinkTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        let string = Self.attributed(text)
        if view.textStorage?.isEqual(to: string) != true { view.textStorage?.setAttributedString(string) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: LinkTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        container.size = NSSize(width: width ?? 10_000, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width ?? ceil(used.width), height: ceil(used.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            openURL?(url)
            return true
        }
    }

    /// The SwiftUI attributes `MarkdownView.inline` sets, as AppKit ones in the popup's callout font.
    private static func attributed(_ text: AttributedString) -> NSAttributedString {
        let base = NSFont.preferredFont(forTextStyle: .callout)
        let result = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : base
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let color = run.swiftUI.foregroundColor { attributes[.foregroundColor] = NSColor(color) }
            if let link = run.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }
}

/// Shows the hand over links even while its panel isn't key, when AppKit's cursor rects don't apply.
private final class LinkTextView: NSTextView {
    // The click that makes the popup key also selects or follows a link.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["links"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["links": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        (isOverLink(event) ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
    }

    private func isOverLink(_ event: NSEvent) -> Bool {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return false }
        return storage.attribute(.link, at: layout.characterIndexForGlyph(at: glyph), effectiveRange: nil) != nil
    }

    // Esc closes the popup instead of asking for completions.
    override func cancelOperation(_ sender: Any?) { window?.cancelOperation(sender) }
}
