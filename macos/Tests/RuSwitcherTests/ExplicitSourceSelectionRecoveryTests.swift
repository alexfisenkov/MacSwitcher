import XCTest
@testable import RuSwitcher

final class ExplicitSourceSelectionRecoveryTests: XCTestCase {
    @MainActor
    func testConfirmedDifferentExplicitSourceClosesOldPendingGate() {
        var tracker = InputSourceTransitionTracker()
        tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
        var currentSource = "ru"
        var confirmations = 0

        ExplicitSourceSelectionRecovery.switchOpposite(intendedTargetID: "en",
            switchSource: { currentSource = "en" },
            observeSource: { currentSource },
            confirm: { target, observed in
                confirmations += 1
                XCTAssertTrue(tracker.confirmExplicitSelection(targetID: target,
                    observedSourceID: observed, at: 20))
            })

        XCTAssertEqual(confirmations, 1)
        XCTAssertFalse(tracker.hasPending)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: 15))
    }

    @MainActor
    func testRefusedOrMismatchedSwitchRetainsOldPendingGate() {
        for observed in ["ru", "other", ""] {
            var tracker = InputSourceTransitionTracker()
            tracker.noteUnconfirmed(targetID: "ru", startingAt: 10)
            var confirmations = 0
            ExplicitSourceSelectionRecovery.switchOpposite(intendedTargetID: "en",
                switchSource: {}, observeSource: { observed },
                confirm: { _, _ in confirmations += 1 })
            XCTAssertEqual(confirmations, 0)
            XCTAssertEqual(tracker.pendingTargetID, "ru")
        }
    }

    @MainActor
    func testUnknownIntendedTargetCannotReleasePendingGate() {
        var confirmations = 0
        ExplicitSourceSelectionRecovery.switchOpposite(intendedTargetID: nil,
            switchSource: {}, observeSource: { "en" },
            confirm: { _, _ in confirmations += 1 })
        XCTAssertEqual(confirmations, 0)
    }
}
