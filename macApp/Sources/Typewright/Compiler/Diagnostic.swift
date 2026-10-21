import Foundation
import TypewrightCore

struct Diagnostic: Identifiable, Hashable {
    enum Severity: String { case error, warning }

    let id = UUID()
    let path: String
    let line: Int
    let column: Int
    let severity: Severity
    let message: String
    /// UTF-16 length of what it's about; nil underlines to the line's end.
    var length: Int? = nil

    /// Package paths look like `@preview/name:1.0.0/lib.typ`.
    var isFromPackage: Bool { path.hasPrefix("@") }

    /// Parses typst's `--diagnostic-format short` output.
    static func parse(_ output: String) -> [Diagnostic] {
        parseDiagnostics(output: output).map { d in
            Diagnostic(path: d.path, line: Int(d.line), column: Int(d.column),
                       severity: d.severity == .warning ? .warning : .error, message: d.message)
        }
    }
}
