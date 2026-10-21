import Foundation
import TypewrightCore

/// The Rust core's check whether a path relative to `root` is taken.
final class ExistsIn: PathCheck {
    let root: URL

    init(_ root: URL) { self.root = root }

    func test(path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
}
