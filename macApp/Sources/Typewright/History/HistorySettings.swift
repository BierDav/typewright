import AppKit
import SwiftUI

/// Where the spaces live and how long their history stays detailed.
struct HistorySettings: View {
    static let squashKey = "historySquash"
    static let squashDaysKey = "historySquashDays"
    static let lastSquashKey = "historyLastSquash"

    @AppStorage(squashKey) private var squash = true
    @AppStorage(squashDaysKey) private var days = 30

    /// The age in days after which commits collapse to one per day, nil when off.
    static func squashDays(_ defaults: UserDefaults = .standard) -> Int? {
        guard defaults.object(forKey: squashKey) as? Bool ?? true else { return nil }
        let days = defaults.integer(forKey: squashDaysKey)
        return days > 0 ? days : 30
    }

    /// Squashing runs at most once a day.
    static func squashIsDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 86_400 || now < last
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Spaces folder") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SpaceRepository.shared.root])
                    }
                }
            } footer: {
                Text("Every space is a folder in \(SpaceRepository.shared.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Changes are saved to its history a few seconds after you stop editing, or once a minute while you keep going, including changes made in other apps.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Thin out old history", isOn: $squash)
                Stepper(value: $days, in: 1...365) {
                    LabeledContent("Keep every change for", value: days == 1 ? "1 day" : "\(days) days")
                }
                .disabled(!squash)
            } header: {
                Text("History")
            } footer: {
                Text("Older changes are combined into one version per day, which keeps the history small.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            if let error = SpaceRepository.shared.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding()
            }
        }
    }
}
