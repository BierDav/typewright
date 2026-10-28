import SwiftUI

struct SharingIndicator: Equatable {
    let joined: Bool

    var title: String { joined ? "Shared with you" : "Shared by you" }
    var symbol: String { joined ? "arrow.down.circle" : "person.2.fill" }
}

struct SharingBadge: View {
    let url: URL

    var body: some View {
        if let indicator = SyncService.shared.sharingIndicator(for: url) {
            Button { Invites.share(url) } label: {
                Image(systemName: indicator.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ZenPressStyle())
            .help("\(indicator.title) — Sharing…")
            .accessibilityLabel("\(indicator.title) — Sharing…")
        }
    }
}
