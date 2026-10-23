import Foundation

struct FileMove: Equatable {
    let from: URL
    let to: URL

    static func == (lhs: FileMove, rhs: FileMove) -> Bool {
        lhs.from.path == rhs.from.path && lhs.to.path == rhs.to.path
    }

    static func applying(_ moves: [FileMove], to url: URL) -> URL {
        moves.filter { url.path == $0.from.path || url.path.hasPrefix($0.from.path + "/") }
            .max { $0.from.path.count < $1.from.path.count }?.applying(to: url) ?? url
    }

    func applying(to url: URL) -> URL {
        if url.path == from.path { return to }
        guard url.path.hasPrefix(from.path + "/") else { return url }
        return URL(fileURLWithPath: to.path + url.path.dropFirst(from.path.count)).standardizedFileURL
    }
}
