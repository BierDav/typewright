import CoreServices
import Foundation

/// Reports changes anywhere below a folder, coalesced by FSEvents.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onPaths: ([String]) -> Void
    private let contentChangesOnly: Bool

    convenience init(_ url: URL, onChange: @escaping () -> Void) {
        self.init(url) { (_: [String]) in onChange() }
    }

    /// Reports the changed paths, so callers can skip their own bookkeeping folders.
    init(_ url: URL, contentChangesOnly: Bool = false, onPaths: @escaping ([String]) -> Void) {
        self.onPaths = onPaths
        self.contentChangesOnly = contentChangesOnly
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = watcher.contentChangesOnly
                ? list.enumerated().filter { $0.offset < count && FolderWatcher.affectsContents(flags[$0.offset]) }.map(\.element)
                : list
            if !changed.isEmpty { watcher.onPaths(changed) }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    static func affectsContents(_ flags: FSEventStreamEventFlags) -> Bool {
        let changes = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
            | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        let metadata = kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemXattrMod
            | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner
        return flags & FSEventStreamEventFlags(changes) != 0 || flags & FSEventStreamEventFlags(metadata) == 0
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
