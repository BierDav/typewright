import CryptoKit
import Quartz
import SwiftUI

/// Coordinates provider downloads before Quick Look opens a stable local copy.
final class DocumentPreviewCopy: @unchecked Sendable {
    let url: URL
    let digest: SHA256.Digest
    private let directory: URL

    private init(directory: URL, url: URL, digest: SHA256.Digest) {
        self.directory = directory
        self.url = url
        self.digest = digest
    }

    nonisolated static func prepare(_ source: URL, data: Data? = nil) throws -> DocumentPreviewCopy {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Typewright-Preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        do {
            if let data {
                try data.write(to: target)
                return DocumentPreviewCopy(directory: directory, url: target, digest: SHA256.hash(data: data))
            }
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                result = Result { try FileManager.default.copyItem(at: readable, to: target) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            try result.get()
            return DocumentPreviewCopy(directory: directory, url: target, digest: try fingerprint(target))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private nonisolated static func fingerprint(_ url: URL) throws -> SHA256.Digest {
        var hasher = SHA256()
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let files: [URL]
        if isDirectory {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
            else { throw CocoaError(.fileReadUnknown) }
            files = (enumerator.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
        } else {
            files = [url]
        }
        for file in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            hasher.update(data: Data(file.path.dropFirst(url.path.count).utf8))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { hasher.update(data: chunk) }
        }
        return hasher.finalize()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct DocumentPreview: View {
    let url: URL
    var revision = 0
    var data: Data?
    @State private var copy: DocumentPreviewCopy?
    @State private var failure: String?

    private struct Request: Equatable {
        let url: URL
        let revision: Int
        let data: Data?
    }

    var body: some View {
        Group {
            if let copy {
                LocalDocumentPreview(copy: copy)
            } else if let failure {
                ContentUnavailableView("Couldn't Preview Document", systemImage: "doc", description: Text(failure))
            } else {
                ProgressView("Loading Document…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: Request(url: url, revision: revision, data: data)) {
            failure = nil
            do {
                let source = url
                let data = data
                let prepared = try await Task.detached(priority: .userInitiated) { try DocumentPreviewCopy.prepare(source, data: data) }.value
                guard !Task.isCancelled else { return }
                if copy?.digest != prepared.digest { copy = prepared }
            } catch {
                guard !Task.isCancelled else { return }
                copy = nil
                failure = error.localizedDescription
            }
        }
        .onChange(of: url) { copy = nil }
    }
}

private struct LocalDocumentPreview: NSViewRepresentable {
    let copy: DocumentPreviewCopy

    final class Coordinator {
        var copy: DocumentPreviewCopy?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        view.autostarts = true
        context.coordinator.copy = copy
        view.previewItem = copy.url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if context.coordinator.copy?.url != copy.url {
            view.previewItem = copy.url as NSURL
            context.coordinator.copy = copy
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
        coordinator.copy = nil
    }

    // The preview's fitting size must never set the split view's minimum.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: QLPreviewView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }
}
