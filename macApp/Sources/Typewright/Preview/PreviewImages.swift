import Foundation
import TypstBridge

/// Large images of one preview's HTML, kept by the bridge and served to the page through `twimage:` URLs, so
/// updates don't carry them as base64 again.
final class PreviewImages: @unchecked Sendable {
    static let scheme = "twimage"
    private let handle = tw_preview_images_new()

    deinit { tw_preview_images_free(handle) }

    func rewrite(_ html: Data) -> Data {
        var len = 0
        let out = html.withUnsafeBytes {
            tw_preview_images_rewrite(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &len)
        }
        defer { tw_bytes_free(out, len) }
        return Data(bytes: out, count: len)
    }

    /// The bytes and type behind `twimage:///<mime>/<id>`.
    static func image(at url: URL) -> (data: Data, mime: String)? {
        guard url.scheme == scheme, let id = UInt64(url.lastPathComponent) else { return nil }
        var len = 0
        guard let bytes = tw_preview_image(id, &len) else { return nil }
        defer { tw_bytes_free(bytes, len) }
        let mime = url.deletingLastPathComponent().path(percentEncoded: false).trimmingCharacters(in: ["/"])
        return (Data(bytes: bytes, count: len), mime)
    }
}
