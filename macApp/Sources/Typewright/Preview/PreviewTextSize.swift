import Foundation
import Observation

/// Markdown text size, shared across previews.
@MainActor @Observable
final class PreviewTextSize {
    static let shared = PreviewTextSize()
    static let didChange = Notification.Name("PreviewTextSizeDidChange")
    static let standard = 16.0
    static let range = 9.0...40.0

    /// CSS pixels.
    var size: Double {
        didSet {
            let clamped = min(max(size, Self.range.lowerBound), Self.range.upperBound)
            if clamped != size { size = clamped; return }
            UserDefaults.standard.set(size, forKey: "previewTextSize")
            NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: [Self.animatedKey: animatesChange])
        }
    }

    /// In `didChange`'s user info: whether the previews ease to the new size.
    nonisolated static let animatedKey = "animated"
    @ObservationIgnored private var animatesChange = true

    /// Pinching and scrolling already move smoothly; easing them on top lags behind.
    func set(_ value: Double, animated: Bool) {
        animatesChange = animated
        size = value
        animatesChange = true
    }

    private init() {
        let saved = UserDefaults.standard.double(forKey: "previewTextSize")
        size = saved > 0 ? saved : Self.standard
    }
}
