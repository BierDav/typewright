import Foundation

struct Diagnostic: Identifiable, Hashable {
    enum Severity: String { case error, warning }

    let id = UUID()
    let path: String
    let line: Int
    let column: Int
    let severity: Severity
    let message: String

    /// Package paths look like `@preview/name:1.0.0/lib.typ`.
    var isFromPackage: Bool { path.hasPrefix("@") }

    /// Parses typst's `--diagnostic-format short` output.
    static func parse(_ output: String) -> [Diagnostic] {
        output.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(\d+): (error|warning): (.*)$"#
    )

    private static func parseLine(_ line: String) -> Diagnostic? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = pattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ i: Int) -> String { String(line[Range(m.range(at: i), in: line)!]) }
        return Diagnostic(
            path: group(1),
            line: Int(group(2)) ?? 1,
            column: Int(group(3)) ?? 1,
            severity: Severity(rawValue: group(4)) ?? .error,
            message: group(5)
        )
    }
}
