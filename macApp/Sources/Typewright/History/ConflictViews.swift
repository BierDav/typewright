import SwiftUI

/// Strip under the editor while the shown file has conflicting changes.
struct ConflictBar: View {
    let onShowHistory: () -> Void
    let onResolve: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("This file has conflicting changes from another device.")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Show History…", action: onShowHistory)
            Button("Resolve…", action: onResolve)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }
}

/// Small mark on conflicted files and the folders holding them in the file sidebar.
struct ConflictBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.yellow)
            .help("Conflicting changes")
            .accessibilityLabel("Conflicting changes")
    }
}

/// Resolves a conflicted file: a choice per conflicting hunk for text, a side for binary files.
struct ConflictResolveView: View {
    let file: URL
    /// The space the file belongs to; nil in previews.
    let workspace: Workspace?
    /// Loads the conflict; the repository by default.
    let load: () async -> FileConflict?
    @Environment(\.dismiss) private var dismiss
    @State private var resolution: ConflictResolution?
    @State private var loaded = false
    @State private var side = 0
    @State private var editing: Int?
    @State private var draft = ""
    @State private var working = false
    @State private var failed = false

    init(file: URL, workspace: Workspace?, load: (() async -> FileConflict?)? = nil) {
        self.file = file
        self.workspace = workspace
        self.load = load ?? { await SpaceRepository.shared.conflict(at: file) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let resolution {
                    if resolution.conflict.binary { binary(resolution) } else { hunks(resolution) }
                } else if loaded {
                    ContentUnavailableView("No Conflict", systemImage: "checkmark.circle",
                                           description: Text("This file has no conflicting changes left."))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 480, idealHeight: 620)
        .task {
            resolution = await load().map(ConflictResolution.init)
            loaded = true
        }
        .alert("Couldn't Resolve the Conflict", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The file couldn't be saved. Try again in a moment.")
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.merge").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Resolve “\(file.lastPathComponent)”").font(.headline)
                if let resolution {
                    Text("Changed on \(ListFormatter.localizedString(byJoining: resolution.conflict.sides.indices.map(resolution.label(of:))))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            if let resolution, !resolution.conflict.binary {
                let left = resolution.unresolvedCount
                Text(left == 0 ? "All conflicts resolved" : left == 1 ? "1 conflict left" : "\(left) conflicts left")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Resolve") { Task { await resolve() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canResolve)
        }
        .padding(12)
    }

    private var canResolve: Bool {
        guard let resolution, !working, editing == nil else { return false }
        return resolution.conflict.binary || resolution.isComplete
    }

    // MARK: - Text

    private func hunks(_ resolution: ConflictResolution) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(resolution.conflict.hunks.indices, id: \.self) { index in
                    switch resolution.conflict.hunks[index] {
                    case .text(let text): AgreedText(text: text)
                    case .conflict(_, let sides): conflictCard(index, sides: sides, resolution)
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func conflictCard(_ index: Int, sides: [String], _ resolution: ConflictResolution) -> some View {
        let choice = resolution.choices[index]
        return VStack(alignment: .leading, spacing: 8) {
            if editing == index {
                TextEditor(text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }
                    Button("Use Edited Text") {
                        self.resolution?.choices[index] = .manual(draft)
                        editing = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(sides.indices, id: \.self) { side in
                        SideColumn(label: resolution.label(of: side), text: sides[side], chosen: choice == .side(side)) {
                            self.resolution?.choices[index] = .side(side)
                        }
                    }
                }
                HStack {
                    if case .manual(let text)? = choice {
                        Label("Edited by hand", systemImage: "pencil").font(.caption).foregroundStyle(.secondary)
                            .help(text)
                    } else if choice == .both {
                        Label("Keeping all sides, one after another", systemImage: "square.stack").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(sides.count > 2 ? "Keep All" : "Keep Both", isOn: .init(
                        get: { choice == .both },
                        set: { self.resolution?.choices[index] = $0 ? .both : nil }
                    ))
                    .toggleStyle(.button)
                    Button("Edit…") {
                        draft = choice.map { resolution.text(of: index, choosing: $0) } ?? sides.first ?? ""
                        editing = index
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.yellow.opacity(choice == nil ? 0.10 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(choice == nil ? Color.yellow.opacity(0.6) : Color.secondary.opacity(0.2)))
    }

    /// One side of a conflicting hunk, picked by clicking it.
    private struct SideColumn: View {
        let label: String
        let text: String
        let chosen: Bool
        let onChoose: () -> Void

        var body: some View {
            Button(action: onChoose) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosen ? Color.accentColor : .secondary)
                        Text(label).font(.caption.weight(.semibold))
                    }
                    Text(text.isEmpty ? "(nothing)" : text.trimmingCharacters(in: .newlines))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(chosen ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Use \(label)'s version")
        }
    }

    /// Text every side agrees on; long runs show only their ends.
    private struct AgreedText: View {
        let text: String
        @State private var expanded = false

        var body: some View {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let trimmed = lines.last == "" ? Array(lines.dropLast()) : lines
            VStack(alignment: .leading, spacing: 0) {
                if trimmed.count > 8 && !expanded {
                    Text(trimmed.prefix(3).joined(separator: "\n"))
                    Button("\(trimmed.count - 6) more lines") { expanded = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.vertical, 2)
                    Text(trimmed.suffix(3).joined(separator: "\n"))
                } else {
                    Text(trimmed.joined(separator: "\n"))
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    // MARK: - Binary

    private func binary(_ resolution: ConflictResolution) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("This file can't be merged. Keep one version:")
            Picker("Version", selection: $side) {
                ForEach(resolution.conflict.sides.indices, id: \.self) { Text(resolution.label(of: $0)).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .fixedSize()
        }
        .padding()
    }

    // MARK: - Resolving

    private func resolve() async {
        guard let resolution else { return }
        working = true
        defer { working = false }
        // The editor's unsaved buffer would otherwise be written over the resolved file.
        workspace?.flushSaves()
        let ok: Bool
        if resolution.conflict.binary {
            ok = await SpaceRepository.shared.resolve(file, text: nil, side: side)
        } else if let text = resolution.text {
            ok = await SpaceRepository.shared.resolve(file, text: text)
        } else {
            return
        }
        guard ok else {
            failed = true
            return
        }
        workspace?.refreshFromDisk()
        dismiss()
    }
}

// MARK: - Previews

extension FileConflict {
    static let sample = FileConflict(
        path: "Thesis/main.typ", binary: false, sides: ["This Mac", "Laptop"],
        hunks: [
            .text("= Thesis\n\n"),
            .conflict(base: "Intro.\n", sides: ["Intro, from the Mac.\n", "Intro, from the laptop.\n"]),
            .text((1...12).map { "Line \($0)\n" }.joined()),
            .conflict(base: "", sides: ["== Method\n", ""]),
        ]
    )
}

#Preview("Conflict Bar") {
    ConflictBar(onShowHistory: {}, onResolve: {}).frame(width: 560)
}

#Preview("Resolve") {
    ConflictResolveView(file: URL(fileURLWithPath: "/tmp/Thesis/main.typ"), workspace: nil) { .sample }
}

#Preview("Resolve Binary") {
    ConflictResolveView(file: URL(fileURLWithPath: "/tmp/Thesis/logo.png"), workspace: nil) {
        FileConflict(path: "Thesis/logo.png", binary: true, sides: ["This Mac", "Laptop"], hunks: [])
    }
}
