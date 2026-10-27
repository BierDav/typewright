import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Views a layout's shortcuts, read-only for built-ins, and records changed ones in forks.
struct LayoutEditorView: View {
    @Binding var selectedID: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var layouts = KeyLayoutStore.shared

    /// The layout shown in the editor; the active one only follows a fork or "Use Layout".
    @State private var chosenID: String
    @State private var recording: ShortcutCommand?
    @State private var monitor: Any?
    @State private var conflict: String?

    init(selectedID: Binding<String>) {
        _selectedID = selectedID
        _chosenID = State(initialValue: selectedID.wrappedValue)
    }

    private var layout: KeyLayout {
        layouts.all.first { $0.id == chosenID } ?? KeyLayout(builtIn: .standard)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 740, height: 580)
        .onChange(of: chosenID) { _, _ in
            stopRecording()
            conflict = nil
        }
        .onChange(of: recording) { _, command in
            stopMonitor()
            guard command != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { record(event) } ? nil : event
            }
        }
        .onDisappear {
            stopRecording()
            stopMonitor()
        }
    }

    private var sidebar: some View {
        List(selection: $chosenID) {
            Section("Built-in") {
                ForEach(BuiltinLayout.allCases) { builtin in
                    Label(builtin.title, systemImage: "keyboard")
                        .tag(builtin.rawValue)
                }
            }
            if !layouts.custom.isEmpty {
                Section("Custom") {
                    ForEach(layouts.custom) { custom in
                        Label(custom.name, systemImage: "keyboard.badge.ellipsis")
                            .tag(custom.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 190)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    note
                    if let conflict {
                        Label(conflict, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    ForEach(sections, id: \.name) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.name)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(section.commands) { command in
                                    row(command)
                                    if command != section.commands.last {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(layout.name).font(.title3.weight(.semibold))
                Text(layout.isBuiltIn ? "Built-in layout, read-only" : "Fork of \(layout.base.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if layout.isBuiltIn {
                Button("Fork Layout…") { fork() }
            } else {
                Button("Rename…") { rename() }
                Button("Reset All") {
                    stopRecording()
                    layouts.resetAll(in: layout.id)
                }
                    .disabled(layout.overrides.isEmpty)
                Button("Delete…", role: .destructive) { delete() }
            }
            if chosenID != selectedID {
                Button("Use Layout") {
                    stopRecording()
                    selectedID = chosenID
                }
                    .buttonStyle(.borderedProminent)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var note: some View {
        Label {
            Text(layout.isBuiltIn
                 ? "Built-in layouts can't be changed. Fork one to record your own shortcuts."
                 : "Only the shortcuts you change are saved, so updates to \(layout.base.title) still reach this layout.")
        } icon: {
            Image(systemName: layout.isBuiltIn ? "lock" : "arrow.triangle.branch")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func row(_ command: ShortcutCommand) -> some View {
        let binding = layout.shortcuts[keyPath: command.keyPath]
        let overridden = layout.overrides[command] != nil
        return HStack(spacing: 10) {
            Text(command.title)
            Spacer()
            if recording == command {
                Text("Press keys…")
                    .font(.callout)
                    .foregroundStyle(.tint)
            } else {
                Text(binding.allDisplay)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(overridden ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            if !layout.isBuiltIn {
                Button(recording == command ? "Cancel" : "Change") {
                    if recording == command { stopRecording() } else { startRecording(command) }
                }
                .buttonStyle(.borderless)
                if overridden {
                    Button { layouts.reset(command, in: layout.id) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Use \(layout.base.title)'s shortcut")
                }
            }
        }
        .frame(minHeight: 26)
    }

    private var sections: [(name: String, commands: [ShortcutCommand])] {
        var order: [String] = []
        var groups: [String: [ShortcutCommand]] = [:]
        for command in ShortcutCommand.allCases {
            if groups[command.section] == nil { order.append(command.section) }
            groups[command.section, default: []].append(command)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    // MARK: Recording

    private func startRecording(_ command: ShortcutCommand) {
        conflict = nil
        KeyLayout.isRecordingShortcut = true
        recording = command
    }

    private func stopRecording() {
        KeyLayout.isRecordingShortcut = false
        recording = nil
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func record(_ event: NSEvent) -> Bool {
        guard let command = recording else { return false }
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return true
        }
        let modifiers = SwiftUI.EventModifiers(nsFlags: event.modifierFlags)
        guard let key = Key(keyCode: event.keyCode),
              key.isFunction || modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.control)
        else {
            NSSound.beep()
            return true
        }
        let shortcut = Shortcut(key: key, modifiers: modifiers)
        if let taken = conflictingCommand(for: shortcut, excluding: command) {
            conflict = "\(shortcut.display) is already used by \(taken.title)."
            return true
        }
        conflict = nil
        // Recording the built-in's own key again drops the fork's patch.
        if shortcut == layout.base.shortcuts[keyPath: command.keyPath].primary {
            layouts.reset(command, in: layout.id)
        } else {
            layouts.setShortcut(shortcut, for: command, in: layout.id)
        }
        stopRecording()
        return true
    }

    private func conflictingCommand(for shortcut: Shortcut, excluding command: ShortcutCommand) -> ShortcutCommand? {
        let shortcuts = layout.shortcuts
        return ShortcutCommand.allCases.first { other in
            other != command && shortcuts[keyPath: other.keyPath].contains(shortcut)
        }
    }

    // MARK: Layouts

    private func fork() {
        stopRecording()
        guard let name = PaletteDialog.input("Fork \(layout.name)",
                                             detail: "The fork follows \(layout.name) until you change a shortcut.",
                                             initial: "\(layout.name) Copy", placeholder: "Layout name",
                                             button: "Create") else { return }
        let fork = layouts.fork(layout, named: name)
        chosenID = fork.id
        selectedID = fork.id
    }

    private func rename() {
        stopRecording()
        guard let name = PaletteDialog.input("Rename Layout", initial: layout.name,
                                             placeholder: "Layout name", button: "Rename") else { return }
        layouts.rename(layout.id, to: name)
    }

    private func delete() {
        stopRecording()
        let base = layout.base.rawValue
        let wasActive = selectedID == layout.id
        layouts.delete(layout.id)
        if wasActive { selectedID = base }
        chosenID = base
    }
}
