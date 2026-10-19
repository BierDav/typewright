import Foundation
import Observation

/// Text size of the reflowing previews (HTML without A4 pages, and Markdown); zooming them changes it everywhere.
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
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private init() {
        let saved = UserDefaults.standard.double(forKey: "previewTextSize")
        size = saved > 0 ? saved : Self.standard
    }
}
