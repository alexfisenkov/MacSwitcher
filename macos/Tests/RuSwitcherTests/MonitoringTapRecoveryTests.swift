import XCTest
@testable import RuSwitcher

final class MonitoringTapRecoveryTests: XCTestCase {
    func testTapHealthRequiresHostEnabledTapAndAvailableFence() {
        let cases: [(Bool, Bool, Bool, Bool)] = [
            (false, false, true, true),
            (true, false, true, true),
            (true, true, false, true),
            (true, true, true, false),
        ]
        for (present, enabled, available, expected) in cases {
            XCTAssertEqual(NativeTapRecoveryStatus(tapPresent: present, tapEnabled: enabled,
                fenceAvailable: available).needsRecovery, expected)
        }
    }

    @MainActor
    func testFailedRestartContinuesPastSecondFailureAndKeepsSingleRetry() {
        var active = true
        var outcomes = [false, false, true]
        var attempts = 0
        var scheduled: [@MainActor () -> Void] = []
        let recovery = MonitoringTapRecovery(isActive: { active }, reconfigure: {
            attempts += 1
            return outcomes.removeFirst()
        }, schedule: { delay, action in
            XCTAssertEqual(delay, 3)
            scheduled.append(action)
        })

        recovery.poll(needsRecovery: true)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(recovery.retryScheduled)
        recovery.poll(needsRecovery: true)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(scheduled.count, 1)

        scheduled.removeFirst()()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertTrue(recovery.retryScheduled)
        scheduled.removeFirst()()
        XCTAssertEqual(attempts, 3)
        XCTAssertFalse(recovery.retryScheduled)
        XCTAssertTrue(scheduled.isEmpty)
        active = false
    }

    @MainActor
    func testStopInvalidatesAlreadyScheduledRetry() {
        var attempts = 0
        var scheduled: [@MainActor () -> Void] = []
        let recovery = MonitoringTapRecovery(isActive: { true }, reconfigure: {
            attempts += 1
            return false
        }, schedule: { _, action in scheduled.append(action) })
        recovery.request()
        XCTAssertEqual(attempts, 1)
        recovery.stop()
        scheduled.removeFirst()()
        recovery.poll(needsRecovery: true)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testSuccessfulImmediateRequestRetiresOlderScheduledRetry() {
        var attempts = 0
        var scheduled: [@MainActor () -> Void] = []
        let recovery = MonitoringTapRecovery(isActive: { true }, reconfigure: {
            attempts += 1
            return attempts > 1
        }, schedule: { _, action in scheduled.append(action) })
        recovery.request()
        recovery.request()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(recovery.retryScheduled)
        scheduled.removeFirst()()
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testInactiveMonitoringDropsRetryWithoutRestarting() {
        var active = true
        var attempts = 0
        var scheduled: [@MainActor () -> Void] = []
        let recovery = MonitoringTapRecovery(isActive: { active }, reconfigure: {
            attempts += 1
            return false
        }, schedule: { _, action in scheduled.append(action) })
        recovery.request()
        active = false
        scheduled.removeFirst()()
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(recovery.retryScheduled)
        active = true
        recovery.poll(needsRecovery: true)
        XCTAssertEqual(attempts, 2)
    }
}
