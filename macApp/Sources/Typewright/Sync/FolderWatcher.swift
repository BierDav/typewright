import CoreServices
import Foundation

/// Reports changes anywhere below a folder, coalesced by FSEvents.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onPaths: ([String]) -> Void

    convenience init(_ url: URL, onChange: @escaping () -> Void) {
        self.init(url) { (_: [String]) in onChange() }
    }

    /// Reports the changed paths, so callers can skip their own bookkeeping folders.
    init(_ url: URL, onPaths: @escaping ([String]) -> Void) {
        self.onPaths = onPaths
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onPaths(list)
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
