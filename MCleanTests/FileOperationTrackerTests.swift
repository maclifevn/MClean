import XCTest
@testable import MClean

@MainActor
final class FileOperationTrackerTests: XCTestCase {
    func testOverlappingOperationsRemainBusyUntilEveryLeaseEnds() {
        let tracker = FileOperationTracker()
        let first = tracker.begin()
        let second = tracker.begin()
        tracker.end(first)
        tracker.end(first)
        tracker.end(UUID())
        XCTAssertTrue(tracker.isBusy)
        tracker.end(second)
        XCTAssertFalse(tracker.isBusy)
    }

    func testIndependentToolMutationBlocksBothUpdaterAndBackgroundCleanup() {
        let state = AppState(performStartupTasks: false)
        let operation = FileOperationTracker.shared.begin()
        XCTAssertFalse(state.canInstallAppUpdate)
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        FileOperationTracker.shared.end(operation)
        XCTAssertTrue(state.canInstallAppUpdate)
        XCTAssertTrue(state.canRunScheduledScan(isAppActive: false))
    }

    func testConcurrentWorkersCannotReleaseOneAnothersLease() async {
        let tracker = FileOperationTracker()
        let retained = tracker.begin()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let token = tracker.begin()
                    tracker.end(token)
                }
            }
        }
        XCTAssertTrue(tracker.isBusy)
        tracker.end(retained)
        XCTAssertFalse(tracker.isBusy)
    }
}
