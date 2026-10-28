import Foundation

/// Keeps one analysis running and replaces pending work with the newest snapshot.
@MainActor
final class LatestAnalysis<Input: Sendable, Output: Sendable> {
    private var pending: (input: Input, apply: (Output) -> Void)?
    private var revision = 0
    private(set) var task: Task<Void, Never>?
    private let compute: @Sendable (Input) -> Output

    init(compute: @escaping @Sendable (Input) -> Output) {
        self.compute = compute
    }

    func invalidate() {
        revision += 1
        pending = nil
    }

    func submit(_ input: Input, apply: @escaping (Output) -> Void) {
        revision += 1
        pending = (input, apply)
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .milliseconds(40))
                guard let next = self.pending else { self.task = nil; return }
                self.pending = nil
                let revision = self.revision
                let compute = self.compute
                let input = next.input
                let output = await Task.detached(priority: .userInitiated) { compute(input) }.value
                if revision == self.revision { next.apply(output) }
                if self.pending == nil { self.task = nil; return }
            }
        }
    }
}
