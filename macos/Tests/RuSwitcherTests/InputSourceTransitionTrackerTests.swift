import XCTest
@testable import RuSwitcher

final class InputSourceTransitionTrackerTests: XCTestCase {
    func testLateSourceAcknowledgementCoversKeyCreatedAfterLeaseFinished() {
        var tracker = InputSourceTransitionTracker()
        tracker.recordCompletedWindow(start: 10, end: 20)
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        tracker.observe(sourceID: "en", at: 20)
        XCTAssertTrue(tracker.hasPending)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 22))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 0))

        tracker.observe(sourceID: "ru", at: 25)

        XCTAssertFalse(tracker.hasPending)
        // The callback at 30 still carries the old-source event created at 22.
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 22))
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 26))
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 0))
    }

    func testWrongEmptyOrEarlierObservationCannotResolvePendingTarget() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        for (source, timestamp): (String, UInt64) in [("en", 20), ("", 30), ("ru", 9)] {
            tracker.observe(sourceID: source, at: timestamp)
            XCTAssertTrue(tracker.hasPending)
        }
        tracker.observe(sourceID: "ru", at: 25)
        XCTAssertFalse(tracker.hasPending)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 15))
    }

    func testResolvedWindowIncludesBothEndpointsAndRejectsOutsideTimestamps() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        tracker.observe(sourceID: "ru", at: 25)
        for (timestamp, expected): (UInt64, Bool) in [(0, false), (9, false), (10, true), (25, true), (26, false)] {
            XCTAssertEqual(tracker.needsRefresh(eventTimestamp: timestamp), expected)
        }
    }

    func testPendingRequestsMergeEarliestStartAndKeepLatestTarget() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 20)
        tracker.noteUnconfirmed(targetID: "en", startingAt: 30)
        tracker.observe(sourceID: "ru", at: 40)
        XCTAssertTrue(tracker.hasPending)
        tracker.noteUnconfirmed(targetID: "fr", startingAt: 10)
        tracker.observe(sourceID: "en", at: 45)
        XCTAssertTrue(tracker.hasPending)

        tracker.observe(sourceID: "fr", at: 50)

        XCTAssertFalse(tracker.hasPending)
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 9))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 10))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 19))
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 51))
    }

    func testEmptyTargetAndZeroStartCannotCreateOrOverwritePendingTransition() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "", startingAt: 10)
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 0)
        XCTAssertFalse(tracker.hasPending)
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 10))
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        tracker.noteUnconfirmed(targetID: "", startingAt: 1)
        tracker.noteUnconfirmed(targetID: "en", startingAt: 0)
        tracker.observe(sourceID: "ru", at: 20)
        XCTAssertFalse(tracker.hasPending)
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 9))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 10))
    }

    func testCompletedLeaseWindowNeedsRefreshWithoutPendingTransition() {
        var tracker = InputSourceTransitionTracker()
        tracker.recordCompletedWindow(start: 10, end: 20)
        XCTAssertFalse(tracker.hasPending)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 15))
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 21))
    }

    func testReversedAndZeroStartCompletedWindowsAreRejected() {
        var tracker = InputSourceTransitionTracker()
        for (start, end): (UInt64, UInt64) in [(0, 20), (30, 20), (0, 0), (10, 0)] {
            tracker.recordCompletedWindow(start: start, end: end)
        }
        for timestamp: UInt64 in [0, 1, 10, 20, 30] {
            XCTAssertFalse(tracker.needsRefresh(eventTimestamp: timestamp))
        }
    }

    func testMaximumClockEndpointWorksWithoutOverflowAndEarlierObservationIsRejected() {
        var tracker = InputSourceTransitionTracker()
        tracker.recordCompletedWindow(start: UInt64.max, end: UInt64.max)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: UInt64.max))
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: UInt64.max - 1))
        tracker.noteUnconfirmed(targetID: "ru", startingAt: UInt64.max)
        tracker.observe(sourceID: "ru", at: UInt64.max - 1)
        XCTAssertTrue(tracker.hasPending)
        tracker.observe(sourceID: "ru", at: UInt64.max)
        XCTAssertFalse(tracker.hasPending)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: UInt64.max))
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: UInt64.max - 1))
    }

    func testOnlyLatest64CompletedWindowsAreRetained() {
        var tracker = InputSourceTransitionTracker()
        for index: UInt64 in 1...65 {
            tracker.recordCompletedWindow(start: index * 10, end: index * 10 + 1)
        }
        for (timestamp, expected): (UInt64, Bool) in [(10, false), (20, true), (21, true), (650, true), (651, true), (652, false)] {
            XCTAssertEqual(tracker.needsRefresh(eventTimestamp: timestamp), expected)
        }
    }

    func testResolvedPendingWindowsUseSame64WindowBudget() {
        var tracker = InputSourceTransitionTracker()
        tracker.recordCompletedWindow(start: 1, end: 2)
        for index: UInt64 in 2...65 {
            tracker.noteUnconfirmed(targetID: "ru", startingAt: index * 10)
            tracker.observe(sourceID: "ru", at: index * 10 + 1)
        }
        XCTAssertFalse(tracker.hasPending)
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 1))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 20))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 650))
    }

    func testNewTransitionKeepsEarlierCompletedSourceChangeWindow() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        tracker.observe(sourceID: "ru", at: 20)
        tracker.noteUnconfirmed(targetID: "en", startingAt: 30)
        tracker.observe(sourceID: "en", at: 40)
        XCTAssertFalse(tracker.hasPending)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 15))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 35))
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 25))
    }

    func testExplicitSameTargetClosesPendingAndPreservesWindow() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        XCTAssertTrue(tracker.confirmExplicitSelection(targetID: "ru", observedSourceID: "ru", at: 20))
        XCTAssertFalse(tracker.hasPending)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 10))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 20))
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 21))
    }

    func testExplicitDifferentTargetSupersedesOldPendingOnlyAfterMatchingObservation() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        tracker.observe(sourceID: "en", at: 15)
        XCTAssertTrue(tracker.hasPending)
        XCTAssertTrue(tracker.confirmExplicitSelection(targetID: "en", observedSourceID: "en", at: 25))
        XCTAssertFalse(tracker.hasPending)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 10))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 15))
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 25))
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 26))
    }

    func testExplicitMismatchedObservationCannotResolveOldPending() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        XCTAssertFalse(tracker.confirmExplicitSelection(targetID: "en", observedSourceID: "ru", at: 20))
        XCTAssertTrue(tracker.hasPending)
        XCTAssertEqual(tracker.pendingTargetID, "ru")
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 21))
    }

    func testExplicitEmptyTargetOrObservationCannotResolvePending() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        XCTAssertFalse(tracker.confirmExplicitSelection(targetID: "", observedSourceID: "ru", at: 20))
        XCTAssertFalse(tracker.confirmExplicitSelection(targetID: "en", observedSourceID: "", at: 20))
        XCTAssertTrue(tracker.hasPending)
    }

    func testExplicitObservationBeforePendingStartCannotResolvePending() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        XCTAssertFalse(tracker.confirmExplicitSelection(targetID: "en", observedSourceID: "en", at: 9))
        XCTAssertFalse(tracker.confirmExplicitSelection(targetID: "en", observedSourceID: "en", at: 0))
        XCTAssertTrue(tracker.hasPending)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 9))
    }

    func testExplicitConfirmationWithoutPendingDoesNotInventTransitionWindow() {
        var tracker = InputSourceTransitionTracker()
        XCTAssertFalse(tracker.confirmExplicitSelection(targetID: "en", observedSourceID: "en", at: 20))
        XCTAssertFalse(tracker.hasPending)
        XCTAssertFalse(tracker.needsRefresh(eventTimestamp: 20))
    }
}
