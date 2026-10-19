import AppKit
import SwiftUI

/// Account, devices, synced spaces and the LFS limit.
struct DeviceSettings: View {
    @Bindable private var identity = SyncIdentity.shared
    @Bindable private var sync = SyncService.shared
    @State private var recoveryInput = ""

    var body: some View {
        Form {
            Section {
                if let fingerprint = identity.fingerprint {
                    LabeledContent("Account", value: fingerprint)
                    LabeledContent("Signed in with", value: identity.kind == .passkey ? "Passkey" : "Recovery key")
                    if let key = identity.recoveryKey {
                        LabeledContent("Recovery key") {
                            Text(key).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    LabeledContent("") {
                        Button("Sign Out", role: .destructive) { identity.signOut() }
                    }
                } else {
                    LabeledContent("Passkey") {
                        HStack {
                            Button("Create…") { Task { await identity.createPasskey() } }
                            Button("Sign In…") { Task { await identity.signInWithPasskey() } }
                        }
                        .disabled(SyncIdentity.passkeyDomain == nil || identity.isWorking)
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                if let error = identity.error {
                    Text(error).foregroundStyle(.red)
                } else if identity.account == nil, SyncIdentity.passkeyDomain == nil {
                    Text("Passkeys aren't set up in this build; use a recovery key on each Mac instead.")
                        .foregroundStyle(.secondary)
                } else if identity.account == nil {
                    Text("Sign in with the same passkey on each Mac; iCloud Keychain brings it along. Synced spaces then show up on all of them, with nothing to exchange.")
                        .foregroundStyle(.secondary)
                }
            }

            if identity.account == nil {
                Section {
                    LabeledContent("New account") {
                        Button("Generate Key") { _ = identity.generateRecoveryKey() }
                    }
                    HStack {
                        TextField("Key from another Mac", text: $recoveryInput)
                            .font(.system(.body, design: .monospaced))
                        Button("Use") { identity.useRecoveryKey(recoveryInput) }
                            .disabled(recoveryInput.isEmpty)
                    }
                } header: {
                    Text("Recovery Key")
                } footer: {
                    Text("Without passkeys, devices share an account through a key you copy over once.")
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
                    ForEach(sync.spaces.sorted { $0.value.lastPathComponent < $1.value.lastPathComponent }, id: \.key) { _, root in
                        LabeledContent {
                            HStack {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([root]) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless)
                                Button("Stop Syncing") { sync.stopSyncing(root) }
                            }
                        } label: {
                            Text(root.lastPathComponent)
                            Text(root.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
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
                        Text("The whole folder syncs, except what its .gitignore files exclude.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("Merge text files up to") {
                    HStack(spacing: 4) {
                        TextField("", value: $sync.lfsThresholdMB, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("MB")
                    }
                }
            } header: {
                Text("Large and Binary Files")
            } footer: {
                Text("Edits of the same text file on two Macs are merged line by line. Larger files and binary files like PDFs, Office documents and images use LFS mode instead: they're never diffed and are replaced whole, and when two Macs change one at once both versions are kept.")
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
