import AppKit

enum FileTrash {
    @MainActor
    static func recycle(_ source: URL) async throws -> URL {
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([source]) { items, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                } else if let target = items[source] {
                    continuation.resume(returning: .success(target))
                } else {
                    continuation.resume(returning: .failure(CocoaError(.fileWriteUnknown)))
                }
            }
        }
        if case .success(let target) = result { return target }
        return try await Task.detached(priority: .userInitiated) {
            let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return try moveToTrash(source, directory: trash)
        }.value
    }

    /// Providers without a volume Trash can still move files into the user's local Trash.
    nonisolated static func moveToTrash(_ source: URL, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var target = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) || (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            let suffix = UUID().uuidString.prefix(8)
            let name = source.deletingPathExtension().lastPathComponent + " (\(suffix))"
            target = directory.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
        }
        try move(source, to: target)
        return target
    }

    nonisolated static func move(_ source: URL, to target: URL) throws {
        if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try FileManager.default.moveItem(at: source, to: target)
            return
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: [], error: &coordinationError) { from, to in
            result = Result {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }
}
