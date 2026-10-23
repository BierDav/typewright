import SwiftUI
import TypewrightCore

/// A share's sync status as a small symbol, for space rows.
struct SyncStatusLabel: View {
    let status: ShareStatus?
    let shared: Bool

    var body: some View {
        Image(systemName: Self.symbol(status, shared: shared))
            .font(.system(size: 10))
            .foregroundStyle(status == .conflicts ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
            .symbolEffect(.pulse, isActive: status == .syncing)
            .help(Self.title(status ?? .synced) + (shared ? " · Shared with others" : " · Synced across your devices"))
    }

    static func symbol(_ status: ShareStatus?, shared: Bool) -> String {
        switch status {
        case .conflicts: "exclamationmark.triangle.fill"
        case .offline: "icloud.slash"
        default: shared ? "person.2" : "arrow.triangle.2.circlepath"
        }
    }

    static func title(_ status: ShareStatus) -> String {
        switch status {
        case .synced: "Synced"
        case .syncing: "Syncing"
        case .conflicts: "Conflicts to resolve"
        case .offline: "Other devices offline"
        }
    }
}
