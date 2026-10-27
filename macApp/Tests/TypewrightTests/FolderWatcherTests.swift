import CoreServices
import XCTest
@testable import Typewright

final class FolderWatcherTests: XCTestCase {
    func testCloudMetadataAloneDoesNotRefreshTheFileTree() {
        let metadata = kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemXattrMod
            | kFSEventStreamEventFlagItemInodeMetaMod
        XCTAssertFalse(FolderWatcher.affectsContents(FSEventStreamEventFlags(metadata)))
    }

    func testContentChangesStillRefreshWithCloudMetadata() {
        let flags = kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified
            | kFSEventStreamEventFlagItemXattrMod
        XCTAssertTrue(FolderWatcher.affectsContents(FSEventStreamEventFlags(flags)))
        XCTAssertTrue(FolderWatcher.affectsContents(FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)))
    }

    func testDroppedEventsStillForceARescan() {
        let flags = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemInodeMetaMod
        XCTAssertTrue(FolderWatcher.affectsContents(FSEventStreamEventFlags(flags)))
        XCTAssertTrue(FolderWatcher.affectsContents(0))
    }
}
