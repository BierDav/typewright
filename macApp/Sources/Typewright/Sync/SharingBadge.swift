import SwiftUI

struct SharingIndicator: Equatable {
    let joined: Bool
    let inherited: Bool

    var title: String { joined ? "Shared with you" : "Shared by you" }
    var symbol: String { joined ? "arrow.down.circle" : "person.2.fill" }
    var help: String { title + (inherited ? " · In a shared folder" : "") }
}

struct SharingBadge: View {
    let url: URL

    var body: some View {
        if let indicator = SyncService.shared.sharingIndicator(for: url) {
            Image(systemName: indicator.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(indicator.help)
                .accessibilityLabel(indicator.help)
        }
    }
}
