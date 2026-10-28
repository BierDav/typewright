import XCTest
@testable import Typewright

@MainActor
final class LatestAnalysisTests: XCTestCase {
    func testRunsOffMainAndSkipsSupersededSnapshots() async {
        let started = expectation(description: "First analysis started")
        let release = DispatchSemaphore(value: 0)
        let analysis = LatestAnalysis<Int, Int> { input in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNotEqual(input, 2, "Pending work should be replaced before it runs")
            if input == 1 {
                started.fulfill()
                release.wait()
            }
            return input
        }
        var applied: [Int] = []
        analysis.submit(1) { applied.append($0) }
        await fulfillment(of: [started], timeout: 2)
        analysis.submit(2) { applied.append($0) }
        analysis.submit(3) { applied.append($0) }
        release.signal()
        await analysis.task?.value
        XCTAssertEqual(applied, [3])
    }

    func testInvalidationDiscardsAnInFlightResult() async {
        let started = expectation(description: "Analysis started")
        let release = DispatchSemaphore(value: 0)
        let analysis = LatestAnalysis<Int, Int> { input in
            started.fulfill()
            release.wait()
            return input
        }
        analysis.submit(1) { _ in XCTFail("Invalidated results must not be applied") }
        await fulfillment(of: [started], timeout: 2)
        analysis.invalidate()
        release.signal()
        await analysis.task?.value
        XCTAssertNil(analysis.task)
    }
}
