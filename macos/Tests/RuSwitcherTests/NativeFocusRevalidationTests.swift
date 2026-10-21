import XCTest
@testable import RuSwitcher

final class NativeFocusRevalidationTests: XCTestCase {
    @MainActor
    private final class Probe {
        var clock: TimeInterval = 0
        var gate = true
        var reads = 0
        var pauses: [TimeInterval] = []
        var readResult: (() -> CombinedShiftExecutionFailure?)?
        var afterPause: (() -> Void)?
        var advanceOnPause = true

        func validate(deadline: TimeInterval = 0.100) -> Bool {
            NativeFocusRevalidation.validate(until: deadline, now: { self.clock },
                mayContinue: { self.gate }, read: {
                    self.reads += 1
                    return self.readResult?()
                }, pause: { interval in
                    self.pauses.append(interval)
                    if self.advanceOnPause { self.clock += interval }
                    self.afterPause?()
                })
        }
    }

    @MainActor
    func testTransientUnavailableCanValidateSameFieldWithinOriginalBudget() {
        let probe = Probe()
        probe.readResult = { probe.reads == 1 ? .focusUnavailable : nil }
        XCTAssertTrue(probe.validate())
        XCTAssertEqual(probe.reads, 2)
        XCTAssertEqual(probe.pauses, [0.001])
    }

    @MainActor
    func testValidReadReturnsWithoutRetryOrPause() {
        let probe = Probe()
        XCTAssertTrue(probe.validate())
        XCTAssertEqual(probe.reads, 1)
        XCTAssertTrue(probe.pauses.isEmpty)
    }

    @MainActor
    func testPersistentUnavailableRemainsBoundedEvenWithFrozenClock() {
        for advances in [true, false] {
            let probe = Probe()
            probe.advanceOnPause = advances
            probe.readResult = { .focusUnavailable }
            XCTAssertFalse(probe.validate())
            XCTAssertGreaterThan(probe.reads, 1)
            XCTAssertLessThanOrEqual(probe.reads, 100)
            XCTAssertLessThan(probe.clock, 0.100)
            XCTAssertTrue(probe.pauses.allSatisfy { $0 > 0 && $0 <= 0.001 })
        }
    }

    @MainActor
    func testHardFailuresAfterTransientUnavailableStopImmediately() {
        for failure in [CombinedShiftExecutionFailure.revisionChanged, .wrongProcess, .secureInput, .focusChanged] {
            let probe = Probe()
            probe.readResult = { probe.reads == 1 ? .focusUnavailable : failure }
            XCTAssertFalse(probe.validate())
            XCTAssertEqual(probe.reads, 2)
            XCTAssertEqual(probe.pauses.count, 1)
        }
    }

    @MainActor
    func testHardFailuresOnFirstReadNeverRetry() {
        for failure in [CombinedShiftExecutionFailure.revisionChanged, .wrongProcess, .secureInput, .focusChanged] {
            let probe = Probe()
            probe.readResult = { failure }
            XCTAssertFalse(probe.validate())
            XCTAssertEqual(probe.reads, 1)
            XCTAssertTrue(probe.pauses.isEmpty)
        }
    }

    @MainActor
    func testGateLossBeforeReadDuringReadOrBetweenRetriesCannotValidate() {
        for stage in 0..<3 {
            let probe = Probe()
            if stage == 0 { probe.gate = false }
            if stage == 1 { probe.readResult = { probe.gate = false; return nil } }
            if stage == 2 {
                probe.readResult = { .focusUnavailable }
                probe.afterPause = { probe.gate = false }
            }
            XCTAssertFalse(probe.validate())
            XCTAssertEqual(probe.reads, stage == 0 ? 0 : 1)
        }
    }

    @MainActor
    func testExpiredOrNonfiniteDeadlineDoesNotRead() {
        for deadline in [0, -1, TimeInterval.nan, .infinity, -.infinity] {
            let probe = Probe()
            XCTAssertFalse(probe.validate(deadline: deadline))
            XCTAssertEqual(probe.reads, 0)
        }
    }

    @MainActor
    func testInvalidClockDoesNotRead() {
        for clock in [-0.001, 0.100, TimeInterval.nan, .infinity, -.infinity] {
            let probe = Probe()
            probe.clock = clock
            XCTAssertFalse(probe.validate())
            XCTAssertEqual(probe.reads, 0)
        }
    }

    @MainActor
    func testClockMovingBackwardsDuringReadRejectsValidResponse() {
        let probe = Probe()
        probe.clock = 0.050
        probe.readResult = { probe.clock = 0.049; return nil }
        XCTAssertFalse(probe.validate())
        XCTAssertEqual(probe.reads, 1)
    }

    @MainActor
    func testValidReadFinishingAtOrAfterDeadlineCannotSucceed() {
        for finished in [0.100, 0.101, TimeInterval.nan] {
            let probe = Probe()
            probe.readResult = { probe.clock = finished; return nil }
            XCTAssertFalse(probe.validate())
            XCTAssertEqual(probe.reads, 1)
            XCTAssertTrue(probe.pauses.isEmpty)
        }
    }

    @MainActor
    func testPostReadGateCrossingDeadlineCannotValidate() {
        var clock: TimeInterval = 0.099
        var gateChecks = 0
        var reads = 0
        let valid = NativeFocusRevalidation.validate(until: 0.100, now: { clock },
            mayContinue: {
                gateChecks += 1
                if gateChecks == 2 { clock = 0.101 }
                return true
            }, read: {
                reads += 1
                return nil
            }, pause: { _ in XCTFail("A successful focus read must not be retried") })
        XCTAssertFalse(valid)
        XCTAssertEqual(reads, 1)
    }

    @MainActor
    func testRetryPauseUsesOnlyRemainingBudgetAndNeverExtendsDeadline() {
        let probe = Probe()
        probe.readResult = { .focusUnavailable }
        XCTAssertFalse(probe.validate(deadline: 0.0004))
        XCTAssertEqual(probe.reads, 1)
        XCTAssertEqual(probe.pauses, [0.0004])
    }
}
