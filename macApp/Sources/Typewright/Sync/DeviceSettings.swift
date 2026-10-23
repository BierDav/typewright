import AppKit
import SwiftUI

/// Account, devices, synced shares and the LFS limit.
struct DeviceSettings: View {
    @Bindable private var identity = SyncIdentity.shared
    @Bindable private var sync = SyncService.shared
    @State private var accountName = ""

    var body: some View {
        Form {
            Section {
                if let fingerprint = identity.fingerprint {
                    if let name = identity.name, !name.isEmpty { LabeledContent("Passkey", value: name) }
                    LabeledContent("Account", value: fingerprint)
                    LabeledContent("") {
                        Button("Sign Out", role: .destructive) { identity.signOut() }
                    }
                } else {
                    TextField("Passkey Name", text: $accountName, prompt: Text("Typewright"))
                        .multilineTextAlignment(.trailing)
                    LabeledContent("Passkey") {
                        HStack {
                            Button("Create…") { Task { await identity.createPasskey(name: accountName) } }
                            Button("Sign In…") { Task { await identity.signInWithPasskey() } }
                        }
                    }
                    .disabled(SyncIdentity.passkeyDomain == nil || identity.isWorking)
                }
            } header: {
                Text("Account")
            } footer: {
                if let error = identity.error {
                    Text(error).foregroundStyle(.red)
                } else if identity.account == nil, SyncIdentity.passkeyDomain == nil {
                    Text("This build can't use passkeys, so syncing is off. Release builds signed by the developer can.")
                        .foregroundStyle(.secondary)
                } else if identity.account == nil {
                    Text("The name only labels the passkey in Passwords; no email or other account is needed. Create a passkey once, then sign in with it on each Mac; iCloud Keychain brings it along. Synced spaces then show up on all of them, with nothing to exchange.")
                        .foregroundStyle(.secondary)
                }
            }

            if identity.account != nil {
                Section("Devices") {
                    LabeledContent("This Mac", value: Self.short(sync.deviceID))
                    ForEach(sync.devices.filter { $0 != sync.deviceID }, id: \.self) { device in
                        LabeledContent(Self.short(device)) {
                            Label(sync.connected.contains(device) ? "Connected" : "Not reachable",
                                  systemImage: sync.connected.contains(device) ? "circle.fill" : "circle")
                                .foregroundStyle(sync.connected.contains(device) ? .green : .secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if sync.devices.filter({ $0 != sync.deviceID }).isEmpty {
                        Text("Sign in on another Mac to sync with it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(sync.shares.sorted { $0.value.path.localizedStandardCompare($1.value.path) == .orderedAscending }, id: \.key) { id, share in
                        let url = sync.repository.url(of: share.path)
                        LabeledContent {
                            HStack {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless)
                                    .help("Reveal in Finder")
                                Button { Invites.share(url) } label: { Image(systemName: "person.badge.plus") }
                                    .buttonStyle(.borderless)
                                    .help("Share…")
                                Menu("Stop Syncing") {
                                    Button("On This Mac") { sync.stopSyncing(id: id) }
                                    Button("On All Devices") { sync.removeEverywhere(id) }
                                }
                                .fixedSize()
                            }
                        } label: {
                            Text(url.lastPathComponent)
                            Text(Self.detail(sync, id: id, share: share))
                        }
                    }
                    ForEach(sync.unmigrated.sorted { $0.value.path < $1.value.path }, id: \.key) { id, url in
                        LabeledContent {
                            HStack {
                                Button("Import…") { Opener.shared.askToImport(url, external: false) }
                                Button("Stop Syncing") { sync.forgetUnmigrated(id) }
                            }
                        } label: {
                            Text(url.lastPathComponent)
                            Text("Not syncing until it's in Typewright's library · " + url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        }
                    }
                    ForEach(sync.parked.sorted { $0.value.share.path.localizedStandardCompare($1.value.share.path) == .orderedAscending }, id: \.key) { id, entry in
                        LabeledContent {
                            Button("Forget") { sync.forgetParked(id) }
                        } label: {
                            Text(entry.name)
                            Text(entry.outside != nil
                                ? "Stopped since it left the library · Move it back to sync it again"
                                : "Stopped since it was deleted · Restore it from Recently Deleted to sync it again")
                        }
                    }
                    if sync.shares.isEmpty && sync.unmigrated.isEmpty && sync.parked.isEmpty {
                        Text("Share a space, folder or file from its context menu to sync it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Synced")
                } footer: {
                    if let error = sync.lastError {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        Text("Shares sync through their history: edits on several devices merge, and conflicts wait for you to resolve them. Files open on two connected devices update as you type. Invite links let other people's accounts sync a share too; anyone with a link can edit it.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("LFS limit") {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        TextField("LFS limit", value: $sync.lfsThresholdMB, format: .number)
                            .labelsHidden()
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: sync.lfsThresholdMB) { _, mb in SpaceRepository.shared.setLFSLimit(megabytes: mb) }
            } header: {
                Text("Large and Binary Files")
            } footer: {
                Text("Text files up to this size keep a history and merge line by line when two devices edit them. Larger files and binary files like PDFs, Office documents and images are LFS files: they have no history, sync whole, and when two devices change one at once both versions are kept.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Status, kind and place of a share.
    private static func detail(_ sync: SyncService, id: String, share: LocalShare) -> String {
        var parts: [String] = []
        if let problem = sync.problems[id] {
            parts.append(problem)
        } else if let status = sync.statuses[id] {
            parts.append(SyncStatusLabel.title(status))
        }
        if sync.accountShares.contains(where: { $0.id == id && $0.shared }) { parts.append("Shared") }
        if share.kind != .space { parts.append((share.path as NSString).deletingLastPathComponent) }
        return parts.joined(separator: " · ")
    }

    private static func short(_ id: String?) -> String {
        guard let id else { return "—" }
        return String(id.prefix(10)) + "…"
    }
}
