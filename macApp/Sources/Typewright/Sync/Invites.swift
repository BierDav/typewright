import AppKit
import TypewrightCore

/// Sharing a space, folder or file (`typewright://join/…` invite links), and joining a share from a link.
@MainActor
enum Invites {
    static func handles(_ url: URL) -> Bool {
        url.scheme?.lowercased() == inviteScheme()
    }

    /// Asks how to share `url`: with this account's devices only, or with anyone holding a link.
    static func share(_ url: URL) {
        let sync = SyncService.shared
        guard sync.isRunning else { return SettingsWindowController.shared.show(tab: 4) }
        guard sync.repository.contains(url) else {
            return message("“\(url.lastPathComponent)” isn't in Typewright's library.",
                           "Only spaces in the library sync. Import the space from its menu in the spaces overview first.")
        }
        let state = Opener.shared.promptState(nil)
        state.ask(sharePage(url))
    }

    static func sharePage(_ url: URL) -> PalettePage {
        PalettePage(title: "Share “\(url.lastPathComponent)”", placeholder: "Choose how to share…", kind: .list {
            let sync = SyncService.shared
            let synced = sync.isSynced(url)
            return [
                PaletteItem(id: "share.invite", title: "Copy Invite Link", subtitle: "Anyone with the link can join and edit",
                            icon: "link", section: "Share", action: .run { copyLink(url, web: false) }),
                PaletteItem(id: "share.web", title: "Copy Web Link", subtitle: "Anyone with the link can join in their browser and edit",
                            icon: "globe", section: "Share", action: .run { copyLink(url, web: true) }),
                PaletteItem(id: "share.sync", title: synced ? "Stop Syncing on This Mac" : "Sync to My Devices",
                            icon: synced ? "xmark.icloud" : "arrow.triangle.2.circlepath", section: "Share", action: .run {
                    if synced { sync.stopSyncing(url) } else { sync.share(url) }
                }),
            ]
        })
    }

    /// Asks first, since the link lets anyone holding it edit the share.
    static func copyLink(for url: URL) { share(url) }

    private static func copyLink(_ url: URL, web: Bool) {
        let sync = SyncService.shared
        guard sync.share(url) != nil, let link = sync.inviteLink(for: url) else {
            return message("Couldn't create an invite link.", sync.lastError ?? "Syncing has to be running; check the Devices settings.")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(web ? webInviteLink(link: link) ?? link : link, forType: .string)
    }

    /// Joins the share a link invites to, after asking where it goes.
    static func open(_ url: URL) {
        guard let invite = parseInvite(link: url.absoluteString) else {
            return message("This invite link isn't valid.", "It may have been cut off when it was sent; ask for a new one.")
        }
        guard SyncIdentity.shared.account != nil else {
            let choice = PaletteDialog.choose("Sign in to join “\(invite.name)”", detail:
                SyncIdentity.passkeyDomain == nil
                ? "Shared spaces sync through a Typewright account. Create an account key or sign in with yours in the Devices settings, then open the link again."
                : "Shared spaces sync through a Typewright account. Create a passkey or account key, or sign in with yours, in the Devices settings, then open the link again.",
                choices: [
                    PaletteDialog.Choice(id: "settings", title: "Open Devices Settings", icon: "gearshape"),
                    PaletteDialog.Choice(id: "cancel", title: "Cancel", icon: "xmark"),
                ])
            if choice == "settings" { SettingsWindowController.shared.show(tab: 4) }
            return
        }
        Task { await join(invite) }
    }

    private static func join(_ invite: SpaceInvite) async {
        let sync = SyncService.shared
        // Links that launch the app arrive while the node is still starting.
        for _ in 0..<100 where !sync.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        guard sync.isRunning else {
            return message("Syncing isn't running.", sync.lastError ?? "Check the Devices settings, then open the link again.")
        }
        if let existing = sync.url(of: invite.id) { return reveal(existing) }
        LibraryDestination.choose(name: invite.name, file: invite.file, in: sync.repository) { destination in
            guard let joined = sync.join(invite, at: destination) else {
                return message("Couldn't join “\(invite.name)”.", sync.lastError ?? "")
            }
            reveal(joined)
        }
    }

    /// Opens the space a share lives in.
    static func reveal(_ url: URL) {
        let repository = SyncService.shared.repository
        guard let path = repository.relativePath(of: url), let space = path.split(separator: "/").first else { return }
        Opener.shared.open(repository.url(of: String(space)))
    }

    private static func message(_ text: String, _ detail: String) {
        PaletteDialog.message(text, detail: detail)
    }
}

/// Shared items only join into folders inside the library.
@MainActor
enum LibraryDestination {
    static func choose(name: String, file: Bool, in repository: SpaceRepository, state: WindowState? = nil,
                       done: @escaping (URL) -> Void) {
        let state = Opener.shared.promptState(state)
        state.ask(page(at: repository.root, name: name, file: file, root: repository.root, done: done))
    }

    static func page(at folder: URL, name: String, file: Bool, root: URL, done: @escaping (URL) -> Void) -> PalettePage {
        PalettePage(title: folder == root ? "Join “\(name)”" : folder.lastPathComponent,
                    placeholder: "Choose a folder in the library…", kind: .list {
            var items: [PaletteItem] = []
            if !file || folder != root {
                items.append(PaletteItem(id: "join.here", title: "Join Here", subtitle: folder.path, icon: "arrow.down.to.line",
                                         section: "Destination", action: .page(PalettePage(title: "Name", placeholder: "Name for the shared item",
                                                                                           kind: .input(initial: name) { typed in
                    let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return }
                    done(folder.appendingPathComponent(name).standardizedFileURL)
                }))))
            }
            items.append(PaletteItem(id: "join.newFolder", title: "New Folder…", icon: "folder.badge.plus", section: "Destination",
                                     action: .page(PalettePage(title: "New Folder", placeholder: "Folder name",
                                                               kind: .input(initial: "") { typed in
                let folderName = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !folderName.isEmpty, folderName != ".", folderName != "..", !folderName.contains("/"), !folderName.contains("\0") else { return }
                let child = folder.appendingPathComponent(folderName)
                do {
                    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
                    DispatchQueue.main.async {
                        Opener.shared.promptState(nil).ask(page(at: child, name: name, file: file, root: root, done: done))
                    }
                } catch { PaletteDialog.error(error) }
            }))))
            let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                        options: [.skipsHiddenFiles])) ?? []
            items += folders.filter {
                let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
                return path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && !FileManager.default.fileExists(atPath: $0.appendingPathComponent(".jj").path)
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map { child in
                PaletteItem(id: child.path, title: child.lastPathComponent, icon: "folder", section: "Folders",
                            action: .page(page(at: child, name: name, file: file, root: root, done: done)))
            }
            return items
        })
    }
}
