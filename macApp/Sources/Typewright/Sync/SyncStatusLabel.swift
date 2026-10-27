import SwiftUI
import TypewrightCore

/// A share's sync status as a small symbol, for space rows.
struct SyncStatusLabel: View {
    let status: ShareStatus?
    let shared: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: shared ? "person.2" : "laptopcomputer.and.iphone")
            if let statusSymbol {
                Image(systemName: statusSymbol)
                    .foregroundStyle(status == .conflicts ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                    .symbolEffect(.pulse, isActive: status == .syncing)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .help((shared ? "Shared with others" : "Available on your devices") + " · " + Self.title(status ?? .synced))
    }

    private var statusSymbol: String? {
        switch status {
        case .conflicts: "exclamationmark.triangle.fill"
        case .offline: "icloud.slash"
        case .syncing: "arrow.triangle.2.circlepath"
        default: nil
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
