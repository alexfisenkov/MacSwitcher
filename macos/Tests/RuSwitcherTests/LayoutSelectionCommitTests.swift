import XCTest
@testable import RuSwitcher

final class LayoutSelectionCommitTests: XCTestCase {
    func testAlreadySelectedSourceDoesNotRequestAgain() {
        var requests = 0
        XCTAssertTrue(LayoutSelectionCommit.select(targetID: "ru", currentID: { "ru" },
            request: { requests += 1; return true }, now: { 0 }, pause: { _ in }))
        XCTAssertEqual(requests, 0)
    }

    func testDelayedAcknowledgementCommitsOnlyObservedSource() {
        var clock: TimeInterval = 0
        var source = "en"
        var requests = 0
        XCTAssertTrue(LayoutSelectionCommit.select(targetID: "ru", currentID: { source },
            request: { requests += 1; return true }, now: { clock }, pause: {
                clock += $0
                if clock >= 0.002 { source = "ru" }
            }))
        XCTAssertEqual(requests, 1)
        XCTAssertGreaterThanOrEqual(clock, 0.002)
    }

    func testFailedRequestDoesNotClaimRequestedSource() {
        var reads = 0
        XCTAssertFalse(LayoutSelectionCommit.select(targetID: "ru", currentID: { reads += 1; return "en" },
            request: { false }, now: { 0 }, pause: { _ in XCTFail("Failed request must not retry") }))
        XCTAssertEqual(reads, 1)
    }

    func testUnacknowledgedSourceHasBoundedWaitEvenWithFrozenClock() {
        for advance in [false, true] {
            var clock: TimeInterval = 0
            var reads = 0
            XCTAssertFalse(LayoutSelectionCommit.select(targetID: "ru", currentID: { reads += 1; return "en" },
                request: { true }, now: { clock }, pause: { if advance { clock += $0 } }))
            XCTAssertLessThanOrEqual(reads, 42)
            XCTAssertLessThanOrEqual(clock, 0.021)
        }
    }

    func testAcknowledgementFinishingAfterBudgetDoesNotCommit() {
        var clock: TimeInterval = 0
        var reads = 0
        XCTAssertFalse(LayoutSelectionCommit.select(targetID: "ru", currentID: {
            reads += 1
            if reads > 1 { clock = 0.021; return "ru" }
            return "en"
        }, request: { true }, now: { clock }, pause: { clock += $0 }))
    }

    func testInvalidClockAndEmptyTargetNeverRequest() {
        for start in [TimeInterval.nan, .infinity, -1] {
            XCTAssertFalse(LayoutSelectionCommit.select(targetID: "ru", currentID: { "en" },
                request: { XCTFail("Invalid clock must not request"); return true }, now: { start }, pause: { _ in }))
        }
        XCTAssertFalse(LayoutSelectionCommit.select(targetID: "", currentID: { "en" },
            request: { XCTFail("Empty source must not request"); return true }, now: { 0 }, pause: { _ in }))
    }
}
