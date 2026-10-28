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
        PalettePage(title: "Sharing “\(url.lastPathComponent)”", placeholder: "Manage sharing and device sync…", kind: .list {
            let sync = SyncService.shared
            let account = sync.accountShare(for: url)
            let synced = sync.isSynced(url)
            var items = [PaletteItem(id: "share.sync", title: synced ? "Unlink Across My Devices" : "Enable Device Sync",
                                    subtitle: synced ? "Keep the files on every device" : "Make this space available to your devices",
                                    icon: "laptopcomputer.and.iphone", section: "Device Sync", action: .run {
                Task {
                    guard sync.share(url) != nil,
                          await sync.configure(url, devices: !synced, shared: account?.shared ?? false) else { return showError(sync) }
                }
            })]
            if !sync.elsewhere.filter({ $0.kind == .space }).isEmpty, url.deletingLastPathComponent().standardizedFileURL == sync.repository.root.standardizedFileURL {
                items.append(PaletteItem(id: "share.relink", title: "Link to a Space on Another Device…",
                                         subtitle: "Merge its contents with this space", icon: "link", section: "Device Sync",
                                         action: .page(relinkPage(url))))
            }
            if account?.joined != true {
                items.append(PaletteItem(id: "share.new", title: account?.shared == true ? "Create New Sharing Link…" : "Create Sharing Link",
                                         subtitle: account?.shared == true ? "Replace the old link and disconnect its participants" : "Anyone with the link can join and edit",
                                         icon: "person.badge.plus", section: "Sharing Links", action: .stay {
                    Task { await createLink(url, replace: account?.shared == true) }
                }))
            }
            if account?.shared == true {
                items += [
                    PaletteItem(id: "share.invite", title: "Copy Invite Link", icon: "link", section: "Sharing Links", action: .run { copyLink(url, web: false) }),
                    PaletteItem(id: "share.web", title: "Copy Web Link", icon: "globe", section: "Sharing Links", action: .run { copyLink(url, web: true) }),
                ]
                if !account!.joined {
                    items.append(PaletteItem(id: "share.revoke", title: "Revoke Sharing Link…",
                                             subtitle: "Disconnect everyone using this link; keep device sync", icon: "person.2.slash", section: "Sharing Links",
                                             action: .run { Task { await revoke(url) } }))
                }
            }
            if sync.shareID(for: url) != nil {
                items.append(PaletteItem(id: "share.leave", title: "Disconnect This Mac", subtitle: "Keep your local files",
                                         icon: "xmark.icloud", section: "This Mac", action: .run { sync.stopSyncing(url) }))
            }
            return items
        })
    }

    static func downloadPage(_ share: AccountShare, download: @escaping () -> Void) -> PalettePage {
        PalettePage(title: "Link “\(share.name)”", placeholder: "Download or merge into a space…", kind: .list {
            var items = [PaletteItem(id: "share.download", title: "Download as a New Space", icon: "icloud.and.arrow.down", section: "New Space", action: .run(download))]
            let sync = SyncService.shared
            items += SpaceFolders.spaces(in: sync.repository.root).map { url in
                PaletteItem(id: "share.merge.\(url.path)", title: url.lastPathComponent, subtitle: "Link and merge the contents",
                            icon: "square.stack", section: "Existing Spaces", action: .run { link(share, to: url) })
            }
            return items
        })
    }

    private static func link(_ share: AccountShare, to url: URL) {
        let sync = SyncService.shared
        guard confirm("Merge “\(share.name)” into “\(url.lastPathComponent)”?", detail: "Both spaces' contents are merged. Conflicting edits stay available to resolve.") else { return }
        Task {
            await sync.repository.commit()
            guard let joined = sync.join(share, at: url, merge: true) else { return showError(sync) }
            reveal(joined)
        }
    }

    static func relinkPage(_ url: URL) -> PalettePage {
        PalettePage(title: "Link “\(url.lastPathComponent)”", placeholder: "Choose a space on another device…", kind: .list {
            SyncService.shared.elsewhere.filter { $0.kind == .space }.map { share in
                PaletteItem(id: "share.link.\(share.id)", title: share.name, subtitle: "Merge into \(url.lastPathComponent)",
                            icon: "laptopcomputer.and.iphone", section: "On Your Devices", action: .run {
                    link(share, to: url)
                })
            }
        })
    }

    static func copyLink(for url: URL) { share(url) }

    private static func createLink(_ url: URL, replace: Bool) async {
        let sync = SyncService.shared
        if replace && !confirm("Replace the sharing link?", detail: "The old link and everyone who used it lose future access. Your devices keep syncing.") { return }
        let devices = sync.isSynced(url)
        guard sync.share(url) != nil, await sync.configure(url, devices: devices, shared: true, rotate: replace) else { return showError(sync) }
        copyLink(url, web: false)
    }

    private static func revoke(_ url: URL) async {
        let sync = SyncService.shared
        guard confirm("Revoke the sharing link?", detail: "Everyone using this link loses future access. Their existing copies stay on their devices. Your device-sync setting stays unchanged.") else { return }
        if !(await sync.configure(url, devices: sync.isSynced(url), shared: false)) { showError(sync) }
    }

    private static func confirm(_ title: String, detail: String) -> Bool {
        PaletteDialog.choose(title, detail: detail, choices: [
            PaletteDialog.Choice(id: "continue", title: "Continue", icon: "checkmark"),
            PaletteDialog.Choice(id: "cancel", title: "Cancel", icon: "xmark"),
        ]) == "continue"
    }

    private static func showError(_ sync: SyncService) {
        message("Couldn't change sharing.", sync.lastError ?? "Check Devices settings and try again.")
    }

    private static func copyLink(_ url: URL, web: Bool) {
        let sync = SyncService.shared
        guard let link = sync.inviteLink(for: url) else { return showError(sync) }
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
        if let existing = sync.url(of: invite.id) {
            if let joined = sync.join(invite, at: existing) { reveal(joined) }
            return
        }
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
