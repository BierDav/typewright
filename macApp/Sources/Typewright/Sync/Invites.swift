import AppKit
import TypewrightCore

/// Invite links (`typewright://join/…`): copying one for a synced space, and joining a space from one.
@MainActor
enum Invites {
    static func handles(_ url: URL) -> Bool {
        url.scheme?.lowercased() == inviteScheme()
    }

    /// Asks first, since the link lets anyone holding it edit the space.
    static func copyLink(for root: URL) {
        let sync = SyncService.shared
        guard sync.isSynced(root) else { return }
        let alert = NSAlert()
        alert.messageText = "Invite others to “\(root.lastPathComponent)”?"
        alert.informativeText = "Anyone with the link can download this space and edit its files, so only send it to people you trust. They need a Typewright account to join, in the app or with the web link in their browser."
        alert.addButton(withTitle: "Copy Invite Link")
        alert.addButton(withTitle: "Copy Web Link")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        guard let link = sync.inviteLink(for: root) else {
            return message("Couldn't create an invite link.", "Syncing has to be running; check the Devices settings.")
        }
        NSPasteboard.general.clearContents()
        let web = response == .alertSecondButtonReturn ? webInviteLink(link: link) : nil
        NSPasteboard.general.setString(web ?? link, forType: .string)
    }

    /// Joins the space a link invites to, after asking where its folder goes.
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
        if let root = sync.spaces[invite.id] { return Opener.shared.open(root) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Join Here"
        panel.message = "Choose where to put “\(invite.name)”. Its files download into a new folder and stay in sync with everyone invited."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        guard let root = sync.join(invite, in: parent) else {
            return message("Couldn't join “\(invite.name)”.", sync.lastError ?? "")
        }
        Opener.shared.open(root)
    }

    private static func message(_ text: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = detail
        alert.runModal()
    }
}
