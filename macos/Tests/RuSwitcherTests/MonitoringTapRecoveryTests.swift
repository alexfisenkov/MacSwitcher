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

    @MainActor
    func testScheduledRetryRechecksSecureAndEditGate() {
        var safe = true
        var attempts = 0
        var scheduled: [@MainActor () -> Void] = []
        let recovery = MonitoringTapRecovery(isActive: { true }, mayReconfigure: { safe },
            reconfigure: { attempts += 1; return false },
            schedule: { _, action in scheduled.append(action) })
        recovery.request()
        XCTAssertEqual(attempts, 1)
        safe = false
        scheduled.removeFirst()()
        XCTAssertEqual(attempts, 1)
        safe = true
        recovery.poll(needsRecovery: true)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testSettingsRequestDeferredDuringLeaseRunsOnNextSafePoll() {
        var safe = false
        var attempts = 0
        let recovery = MonitoringTapRecovery(isActive: { true }, mayReconfigure: { safe },
            reconfigure: { attempts += 1; return true }, schedule: { _, _ in })
        recovery.request(allowNewEpisode: true)
        XCTAssertEqual(attempts, 0)
        recovery.poll(needsRecovery: false)
        XCTAssertEqual(attempts, 0)
        safe = true
        recovery.poll(needsRecovery: false)
        recovery.poll(needsRecovery: false)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testFiveFailedStartsExhaustEpisodeDespiteRepeatedPolls() {
        var attempts = 0
        var scheduled: [@MainActor () -> Void] = []
        let recovery = MonitoringTapRecovery(isActive: { true }, reconfigure: {
            attempts += 1
            return false
        }, schedule: { _, action in scheduled.append(action) })
        recovery.poll(needsRecovery: true)
        for expected in 2...5 {
            XCTAssertEqual(scheduled.count, 1)
            scheduled.removeFirst()()
            XCTAssertEqual(attempts, expected)
        }
        XCTAssertTrue(recovery.isExhausted)
        XCTAssertFalse(recovery.retryScheduled)
        for _ in 0..<20 { recovery.poll(needsRecovery: true) }
        XCTAssertEqual(attempts, 5)
        recovery.request(allowNewEpisode: true)
        XCTAssertEqual(attempts, 6)
        XCTAssertEqual(recovery.failedStartCount, 1)
        recovery.poll(needsRecovery: false) // structural recovery retires queued retry
        XCTAssertFalse(recovery.isExhausted)
        XCTAssertFalse(recovery.retryScheduled)
        scheduled.removeFirst()() // stale generation cannot restart
        XCTAssertEqual(attempts, 6)
    }

    @MainActor
    func testActualAsyncRetryWaitsForLeaseAndRunsOnceAfterSafePoll() async throws {
        var safe = true
        var attempts = 0
        var scheduledCount = 0
        var callbackCount = 0
        var retryTask: Task<Void, Never>?
        defer { retryTask?.cancel() }
        let retryFired = expectation(description: "delayed tap retry callback fired")
        let recovery = MonitoringTapRecovery(retryInterval: 0.015,
            isActive: { true }, mayReconfigure: { safe }, reconfigure: {
                attempts += 1
                return attempts == 2
            }, schedule: { delay, action in
                scheduledCount += 1
                retryTask = Task { @MainActor in
                    // Delay delivery beyond the former 50 ms assumption while
                    // still exercising the real asynchronous callback path.
                    do {
                        try await Task.sleep(nanoseconds: max(
                            UInt64(delay * 1_000_000_000), 75_000_000))
                    } catch { return }
                    action()
                    callbackCount += 1
                    retryFired.fulfill()
                }
            })
        recovery.poll(needsRecovery: true)
        XCTAssertEqual(attempts, 1)
        safe = false // synthetic active edit when the real scheduled task fires
        await fulfillment(of: [retryFired], timeout: 2)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(scheduledCount, 1)
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(recovery.retryScheduled)
        safe = true
        recovery.poll(needsRecovery: true)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(scheduledCount, 1)
        recovery.poll(needsRecovery: false)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(recovery.retryScheduled)
    }
}
