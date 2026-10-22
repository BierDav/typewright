import AppKit
import SwiftUI

/// Account, devices, synced spaces and the LFS limit.
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
                    ForEach(sync.spaces.sorted { $0.value.lastPathComponent < $1.value.lastPathComponent }, id: \.key) { id, root in
                        LabeledContent {
                            HStack {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([root]) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless)
                                Button { Invites.copyLink(for: root) } label: { Image(systemName: "person.badge.plus") }
                                    .buttonStyle(.borderless)
                                    .help("Copy Invite Link")
                                Menu("Stop Syncing") {
                                    Button("On This Mac") { sync.stopSyncing(root) }
                                    Button("On All Devices") { sync.removeEverywhere(id) }
                                }
                                .fixedSize()
                            }
                        } label: {
                            Text(root.lastPathComponent)
                            Text((sync.isShared(root) ? "Shared · " : "") + root.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        }
                    }
                    if sync.spaces.isEmpty {
                        Text("Turn on syncing from a space's context menu in the spaces overview.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Synced Spaces")
                } footer: {
                    if let error = sync.lastError {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        Text("The whole folder syncs, except what its .gitignore files exclude. Invite links let other people's accounts sync a space too; anyone with a link can edit it.")
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

    private static func short(_ id: String?) -> String {
        guard let id else { return "—" }
        return String(id.prefix(10)) + "…"
    }
}
