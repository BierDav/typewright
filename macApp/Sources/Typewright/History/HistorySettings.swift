import AppKit
import SwiftUI

/// How many old versions to keep, like a backup prune; see `twj_squash` in `JJBridge.h`. Negative means all.
struct RetentionPolicy: Codable, Equatable {
    var last = 100
    var hourly = 48
    var daily = 14
    var weekly = 8
    var monthly = 12
    var yearly = -1

    static let standard = RetentionPolicy()

    var json: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }
}

/// Where the spaces live and how much old history stays.
struct HistorySettings: View {
    static let squashKey = "historySquash"
    static let lastSquashKey = "historyLastSquash"
    /// The old "squash after N days" setting; its value isn't carried over, the new defaults replace it.
    static let legacyDaysKey = "historySquashDays"
    static let keys = (
        last: "historyKeepLast", hourly: "historyKeepHourly", daily: "historyKeepDaily",
        weekly: "historyKeepWeekly", monthly: "historyKeepMonthly", yearly: "historyKeepYearly"
    )

    @AppStorage(squashKey) private var squash = true
    @AppStorage(keys.last) private var last = RetentionPolicy.standard.last
    @AppStorage(keys.hourly) private var hourly = RetentionPolicy.standard.hourly
    @AppStorage(keys.daily) private var daily = RetentionPolicy.standard.daily
    @AppStorage(keys.weekly) private var weekly = RetentionPolicy.standard.weekly
    @AppStorage(keys.monthly) private var monthly = RetentionPolicy.standard.monthly
    @AppStorage(keys.yearly) private var yearly = RetentionPolicy.standard.yearly

    /// The policy to thin out with, nil when thinning out is off.
    static func policy(_ defaults: UserDefaults = .standard) -> RetentionPolicy? {
        guard defaults.object(forKey: squashKey) as? Bool ?? true else { return nil }
        let standard = RetentionPolicy.standard
        func value(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        return RetentionPolicy(
            last: max(value(keys.last, standard.last), 0), hourly: max(value(keys.hourly, standard.hourly), 0),
            daily: max(value(keys.daily, standard.daily), 0), weekly: max(value(keys.weekly, standard.weekly), 0),
            monthly: max(value(keys.monthly, standard.monthly), 0), yearly: value(keys.yearly, standard.yearly)
        )
    }

    /// Drops the old days setting, so the new defaults apply.
    static func migrate(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyDaysKey)
    }

    /// Thinning out runs at most once an hour.
    static func squashIsDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 3600 || now < last
    }

    private var currentPolicy: RetentionPolicy {
        RetentionPolicy(last: last, hourly: hourly, daily: daily, weekly: weekly, monthly: monthly, yearly: yearly)
    }

    private func restoreDefaults() {
        let standard = RetentionPolicy.standard
        (last, hourly, daily, weekly, monthly, yearly) =
            (standard.last, standard.hourly, standard.daily, standard.weekly, standard.monthly, standard.yearly)
    }

    private func count(_ title: LocalizedStringKey, _ value: Binding<Int>) -> some View {
        LabeledContent(title) { field(value) }
    }

    private func field(_ value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
            Stepper("", value: value, in: 0...9999).labelsHidden()
        }
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
                Group {
                    count("Most recent", $last)
                    count("Hourly", $hourly)
                    count("Daily", $daily)
                    count("Weekly", $weekly)
                    count("Monthly", $monthly)
                    LabeledContent("Yearly") {
                        HStack {
                            if yearly >= 0 { field($yearly) }
                            Toggle("All", isOn: Binding(get: { yearly < 0 }, set: { yearly = $0 ? -1 : 10 }))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
                .disabled(!squash)
            } header: {
                Text("History")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Typewright keeps the most recent versions, then the last version of each of that many hours, days, weeks, months and years; the versions in between are combined into the next one kept.")
                        .foregroundStyle(.secondary)
                    Button("Restore Defaults") { restoreDefaults() }
                        .disabled(currentPolicy == .standard)
                }
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
