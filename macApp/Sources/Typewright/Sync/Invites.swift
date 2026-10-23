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
        let synced = sync.isSynced(url)
        let alert = NSAlert()
        alert.messageText = "Share “\(url.lastPathComponent)”"
        alert.informativeText = (synced ? "It syncs across your devices. " : "")
            + "Anyone with an invite link can download it and edit it, so only send links to people you trust. They need a Typewright account to join, in the app or with the web link in their browser."
        alert.addButton(withTitle: "Copy Invite Link")
        alert.addButton(withTitle: "Copy Web Link")
        alert.addButton(withTitle: synced ? "Stop Syncing on This Mac" : "Sync to My Devices")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: copyLink(url, web: false)
        case .alertSecondButtonReturn: copyLink(url, web: true)
        case .alertThirdButtonReturn: if synced { sync.stopSyncing(url) } else { sync.share(url) }
        default: break
        }
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
            let alert = NSAlert()
            alert.messageText = "Sign in to join “\(invite.name)”"
            alert.informativeText = SyncIdentity.passkeyDomain == nil
                ? "Shared spaces sync through a Typewright account, which this build can't use. Release builds can."
                : "Shared spaces sync through a Typewright account. Create a passkey or sign in with yours in the Devices settings, then open the link again."
            alert.addButton(withTitle: "Open Devices Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { SettingsWindowController.shared.show(tab: 4) }
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
        guard let destination = LibraryPanel.destination(for: invite.name, file: invite.file, in: sync.repository) else { return }
        guard let joined = sync.join(invite, at: destination) else {
            return message("Couldn't join “\(invite.name)”.", sync.lastError ?? "")
        }
        reveal(joined)
    }

    /// Opens the space a share lives in.
    static func reveal(_ url: URL) {
        let repository = SyncService.shared.repository
        guard let path = repository.relativePath(of: url), let space = path.split(separator: "/").first else { return }
        Opener.shared.open(repository.url(of: String(space)))
    }

    private static func message(_ text: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = detail
        alert.runModal()
    }
}

/// A save panel that only picks places in the library: the root for a new space, or a folder in a space.
@MainActor
final class LibraryPanel: NSObject, NSOpenSavePanelDelegate {
    private let root: URL
    private let file: Bool

    private init(root: URL, file: Bool) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.file = file
    }

    /// Where a share named `name` goes; nil if cancelled.
    static func destination(for name: String, file: Bool, in repository: SpaceRepository) -> URL? {
        let delegate = LibraryPanel(root: repository.root, file: file)
        let panel = NSSavePanel()
        panel.delegate = delegate
        panel.directoryURL = repository.root
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.prompt = "Join Here"
        panel.message = file
            ? "Choose a folder in one of your spaces for “\(name)”. It stays in sync with everyone it's shared with."
            : "Keep the library to make “\(name)” a new space, or choose a folder in one of your spaces. It stays in sync with everyone it's shared with."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return withExtendedLifetime(delegate) { url }
    }

    private func inside(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool { inside(url) }

    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        // Wandering out of the library leads back into it.
        if let url, !inside(url), let panel = sender as? NSSavePanel { panel.directoryURL = root }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard inside(parent) else {
            throw NSError(domain: "Typewright", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shares sync into Typewright's library."])
        }
        if file && parent.path == root.path {
            throw NSError(domain: "Typewright", code: 2, userInfo: [NSLocalizedDescriptionKey: "Choose a folder in one of your spaces for a shared file."])
        }
    }
}
