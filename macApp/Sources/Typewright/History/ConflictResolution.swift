import Foundation

/// The choices made for a conflicted file's hunks, and the text they add up to.
struct ConflictResolution: Equatable {
    enum Choice: Equatable {
        /// One side's text.
        case side(Int)
        /// Every side's text, in the order of the sides.
        case both
        /// Text typed by hand.
        case manual(String)
    }

    let conflict: FileConflict
    /// Choices by hunk index; only conflicting hunks have one.
    var choices: [Int: Choice] = [:]

    init(_ conflict: FileConflict) {
        self.conflict = conflict
    }

    /// Indices of the hunks that conflict.
    var conflictIndices: [Int] {
        conflict.hunks.indices.filter {
            if case .conflict = conflict.hunks[$0] { return true }
            return false
        }
    }

    var unresolvedCount: Int { conflictIndices.filter { choices[$0] == nil }.count }

    var isComplete: Bool { unresolvedCount == 0 }

    func label(of side: Int) -> String {
        conflict.sides.indices.contains(side) ? conflict.sides[side] : "Side \(side + 1)"
    }

    /// The resolved text, once every conflict has a choice.
    var text: String? {
        guard isComplete else { return nil }
        return segments.map(\.text).joined()
    }

    /// A piece of the result: agreed text, a resolved conflict, or a conflict still waiting for a choice (empty text).
    struct Segment: Identifiable, Equatable {
        enum Kind { case agreed, resolved, unresolved }
        let id: Int
        let kind: Kind
        let text: String
    }

    var segments: [Segment] {
        conflict.hunks.indices.map { index in
            switch conflict.hunks[index] {
            case .text(let text):
                return Segment(id: index, kind: .agreed, text: text)
            case .conflict:
                guard let choice = choices[index] else { return Segment(id: index, kind: .unresolved, text: "") }
                return Segment(id: index, kind: .resolved, text: text(of: index, choosing: choice))
            }
        }
    }

    /// The text a hunk resolves to with `choice`.
    func text(of index: Int, choosing choice: Choice) -> String {
        guard case .conflict(_, let sides) = conflict.hunks[index] else { return "" }
        switch choice {
        case .side(let side): return sides.indices.contains(side) ? sides[side] : ""
        case .manual(let text): return text
        case .both:
            // Sides of a hunk usually end in a line break; one that doesn't mustn't glue onto the next.
            let present = sides.filter { !$0.isEmpty }
            return present.enumerated().map { i, side in i < present.count - 1 ? Self.terminated(side) : side }.joined()
        }
    }

    private static func terminated(_ text: String) -> String {
        text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
    }
}
