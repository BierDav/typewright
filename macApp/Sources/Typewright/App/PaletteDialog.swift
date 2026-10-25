import AppKit
import Observation
import SwiftUI

/// A question in the command palette's look, over the key window. Unlike the window's palette overlay, it
/// also works in any window and where the answer decides what happens next: it runs until it's answered.
@MainActor
enum PaletteDialog {
    struct Choice: Identifiable {
        let id: String
        var title: String
        var subtitle: String?
        var icon = "chevron.right"
        /// Set for a checklist; tapping the row flips it.
        var checked: Bool?
        var destructive = false

        init(id: String, title: String, subtitle: String? = nil, icon: String = "chevron.right",
             checked: Bool? = nil, destructive: Bool = false) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.checked = checked
            self.destructive = destructive
        }
    }

    enum Result {
        case choice(String)
        case text(String)
        case checked(Set<Int>)
    }

    /// Tells the user something; the only way out is OK or Esc.
    static func message(_ title: String, detail: String? = nil, button: String = "OK", over window: NSWindow? = nil) {
        let model = Model(kind: .message, title: title, detail: detail, placeholder: title, button: button,
                          choices: [Choice(id: "ok", title: button, icon: "checkmark")])
        _ = run(model, over: window)
    }

    /// Shows the same message for an error, as alerts did.
    static func error(_ error: Error, title: String? = nil) {
        let error = error as NSError
        message(title ?? error.localizedDescription, detail: error.localizedRecoverySuggestion ?? error.localizedFailureReason)
    }

    /// Returns the chosen item's id, or nil when the dialog is cancelled.
    static func choose(_ title: String, detail: String? = nil, choices: [Choice], over window: NSWindow? = nil) -> String? {
        guard case .choice(let id) = run(Model(kind: .choice, title: title, detail: detail, placeholder: title,
                                              button: primary(choices), choices: choices), over: window) else { return nil }
        return id
    }

    /// Returns the typed text, or nil when the dialog is cancelled.
    static func input(_ title: String, detail: String? = nil, initial: String = "", placeholder: String? = nil,
                      button: String = "OK", over window: NSWindow? = nil) -> String? {
        let model = Model(kind: .input, title: title, detail: detail, placeholder: placeholder ?? title,
                          button: button, choices: [])
        model.text = initial
        guard case .text(let text) = run(model, over: window) else { return nil }
        return text
    }

    /// Returns the checked items' indices, or nil when the dialog is cancelled.
    static func checklist(_ title: String, detail: String? = nil, items: [Choice], button: String = "Continue",
                          over window: NSWindow? = nil) -> Set<Int>? {
        guard case .checked(let checked) = run(Model(kind: .checklist, title: title, detail: detail, placeholder: title,
                                                    button: button, choices: items), over: window) else { return nil }
        return checked
    }

    private static func primary(_ choices: [Choice]) -> String {
        choices.first { $0.id != "cancel" }?.title ?? "Select"
    }

    // MARK: - Presentation

    private static func run(_ model: Model, over window: NSWindow?) -> Result? {
        // Tests run without anyone to click; like alerts, the dialog counts as cancelled.
        guard !SpaceRepository.isTestHost else {
            NSLog("PaletteDialog: %@", model.title)
            return nil
        }
        let parent = window.flatMap { $0.isVisible ? $0 : nil }
            ?? NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is PaletteDialogWindow) }
        model.dimming = parent != nil
        let frame = parent?.frame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        // The palette's width, unless the window is narrower; a short window gets a shorter list.
        model.width = max(360, min(640, frame.width - 48))
        model.listHeight = max(120, min(360, frame.height - 260))
        let dialog = PaletteDialogWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        dialog.isOpaque = false
        dialog.backgroundColor = .clear
        dialog.hasShadow = false
        dialog.level = .modalPanel
        dialog.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        dialog.isReleasedWhenClosed = false
        // A plain content view keeps the hosting view from sizing the window down to the card.
        let host = NSHostingView(rootView: PaletteDialogView(model: model))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        dialog.contentView = container
        dialog.setContentSize(frame.size)

        var result: Result?
        model.finish = { answer in
            result = answer
            NSApp.stopModal(withCode: .OK)
        }
        // Esc also reaches the dialog after a row click took the field's focus.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === dialog else { return event }
            if event.keyCode == 53 {
                model.cancel()
                return nil
            }
            // Return works after a row click took the field's focus too.
            if event.keyCode == 36 || event.keyCode == 76, !(dialog.firstResponder is NSText) {
                model.accept()
                return nil
            }
            return event
        }
        dialog.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSApp.runModal(for: dialog)
        if let monitor { NSEvent.removeMonitor(monitor) }
        dialog.orderOut(nil)
        dialog.close()
        parent?.makeKey()
        return result
    }
}

/// A borderless window that can take key, unlike AppKit's default.
private final class PaletteDialogWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
private final class Model {
    enum Kind: Equatable {
        case message, choice, input, checklist
    }

    let kind: Kind
    let title: String
    let detail: String?
    let placeholder: String
    let button: String
    var choices: [PaletteDialog.Choice]
    var query = ""
    var text = ""
    var selection = 0
    var dimming = true
    var width: CGFloat = 640
    var listHeight: CGFloat = 360
    var finish: ((PaletteDialog.Result?) -> Void)?

    init(kind: Kind, title: String, detail: String?, placeholder: String, button: String,
         choices: [PaletteDialog.Choice]) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.placeholder = placeholder
        self.button = button
        self.choices = choices
    }

    var visible: [PaletteDialog.Choice] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard kind != .input, !q.isEmpty else { return choices }
        // The order stays put; a dialog's few rows are not worth reordering.
        return choices.filter {
            CommandPalette.score(q, $0.title.lowercased()) != nil
                || ($0.subtitle.map { CommandPalette.score(q, $0.lowercased()) != nil } ?? false)
        }
    }

    func toggle(_ id: String) {
        guard let index = choices.firstIndex(where: { $0.id == id }), let checked = choices[index].checked else { return }
        choices[index].checked = !checked
    }

    func accept() {
        switch kind {
        case .message:
            finish?(.choice(choices.first?.id ?? "ok"))
        case .choice:
            guard visible.indices.contains(selection) else { return NSSound.beep() }
            finish?(.choice(visible[selection].id))
        case .input:
            finish?(.text(text))
        case .checklist:
            finish?(.checked(Set(choices.indices.filter { choices[$0].checked == true })))
        }
    }

    func cancel() {
        finish?(nil)
    }
}

private struct PaletteDialogView: View {
    @Bindable var model: Model
    @FocusState private var focused: Bool
    /// Where the pointer last moved over the list.
    @State private var pointer = NSEvent.mouseLocation

    var body: some View {
        ZStack(alignment: .top) {
            if model.dimming {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancel() }
                    .overlay { CursorArea(isModal: true).ignoresSafeArea() }
            }
            card
                .padding(.top, model.dimming ? 72 : 24)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // The field can only take focus once the window is key; it is by the time this runs.
            NSApp.keyWindow?.makeFirstResponder(nil)
            try? await Task.sleep(for: .milliseconds(30))
            focused = true
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            if let detail = model.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            if model.kind != .input {
                Divider()
                list
            }
            Divider()
            footer
        }
        .frame(width: model.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            if model.kind == .input {
                TextField(model.placeholder, text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(model.accept)
                    .onKeyPress(.escape) { model.cancel(); return .handled }
            } else {
                TextField(model.placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(model.accept)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { model.cancel(); return .handled }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .onChange(of: model.query) { model.selection = 0 }
    }

    private var list: some View {
        let items = model.visible
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, choice in
                        DialogRow(choice: choice, isSelected: index == model.selection)
                            .id(choice.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = index
                                if model.kind == .checklist {
                                    model.toggle(choice.id)
                                } else {
                                    model.accept()
                                }
                            }
                            .onContinuousHover { phase in
                                guard case .active = phase, NSEvent.mouseLocation != pointer else { return }
                                pointer = NSEvent.mouseLocation
                                model.selection = index
                            }
                    }
                    if items.isEmpty {
                        Text("No results")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OverlayScrollers())
            }
            .frame(height: min(CGFloat(max(items.count, 1)) * 34 + 12, model.listHeight))
            .onChange(of: model.selection) { _, index in
                if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.kind != .input, model.visible.count > 1 { hint("↑↓", "Navigate") }
            hint("↩", model.button)
            hint("esc", "Cancel")
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func move(_ delta: Int) {
        let count = model.visible.count
        guard count > 0 else { return }
        model.selection = (model.selection + delta + count) % count
    }
}

private struct DialogRow: View {
    let choice: PaletteDialog.Choice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: choice.icon)
                .foregroundStyle(choice.destructive ? Color.red : Color.secondary)
                .frame(width: 18)
            Text(choice.title)
                .lineLimit(1)
                .foregroundStyle(choice.destructive ? Color.red : Color.primary)
            if let subtitle = choice.subtitle {
                Text(subtitle)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let checked = choice.checked {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? 0.1 : 0)))
    }
}
