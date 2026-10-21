import XCTest
@testable import RuSwitcher

final class PredictionSourceNotificationTests: XCTestCase {
    private let english = "com.apple.keylayout.US"
    private let russian = "com.apple.keylayout.Russian"

    @MainActor
    func testDelayedSameSourceNotificationKeepsQueuedSnapshotAndFurtherPrefix() throws {
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        var invalidations = 0
        monitor.onPredictionInput = { snapshots.append($0) }
        monitor.onPredictionInvalidated = { invalidations += 1 }
        monitor.recordPredictionText("ghbd", processID: 123, sourceLayoutID: english)
        let queued = try XCTUnwrap(snapshots.last)

        monitor.resetLineBuffer(sourceLayoutID: english)

        XCTAssertEqual(invalidations, 0, "A delayed acknowledgement must not cancel the pending evaluation")
        XCTAssertEqual(monitor.predictionSessionID, queued.sessionID)
        XCTAssertTrue(queued.isCurrent(processID: 123, revision: monitor.inputRevision,
            generation: monitor.predictionGeneration))
        monitor.recordPredictionText("t", processID: 123, sourceLayoutID: english)
        let continued = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(continued.suffix, "ghbdt")
        XCTAssertEqual(continued.sessionID, queued.sessionID)
        XCTAssertEqual(continued.generation, queued.generation)
        XCTAssertEqual(continued.cumulativeUTF16Offset, 5)
    }

    @MainActor
    func testDifferentSourceNotificationInvalidatesAndClearsOldPrefix() throws {
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        var invalidations = 0
        monitor.onPredictionInput = { snapshots.append($0) }
        monitor.onPredictionInvalidated = { invalidations += 1 }
        monitor.recordPredictionText("ghbd", processID: 123, sourceLayoutID: english)
        let queued = try XCTUnwrap(snapshots.last)

        monitor.resetLineBuffer(sourceLayoutID: russian)

        XCTAssertEqual(invalidations, 1)
        XCTAssertNotEqual(monitor.predictionSessionID, queued.sessionID)
        XCTAssertFalse(queued.isCurrent(processID: 123, revision: monitor.inputRevision,
            generation: monitor.predictionGeneration))
        monitor.recordPredictionText("п", processID: 123, sourceLayoutID: russian)
        let fresh = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(fresh.suffix, "п", "Text from a previous source must not survive a real source change")
        XCTAssertEqual(fresh.cumulativeUTF16Offset, 1)
        XCTAssertEqual(fresh.sourceLayoutID, russian)
    }

    @MainActor
    func testNewSourceCharacterBeforeItsNotificationStartsFreshContext() throws {
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        var invalidations = 0
        monitor.onPredictionInput = { snapshots.append($0) }
        monitor.onPredictionInvalidated = { invalidations += 1 }
        monitor.recordPredictionText("ghbd", processID: 123, sourceLayoutID: english)
        let old = try XCTUnwrap(snapshots.last)
        monitor.recordPredictionText("п", processID: 123, sourceLayoutID: russian)
        monitor.resetLineBuffer(sourceLayoutID: russian)
        let current = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(current.suffix, "п")
        XCTAssertNotEqual(current.sessionID, old.sessionID)
        XCTAssertEqual(invalidations, 1)
        XCTAssertTrue(current.isCurrent(processID: 123, revision: monitor.inputRevision,
            generation: monitor.predictionGeneration))
    }

    @MainActor
    func testUnknownSourceCannotEnterLaterKnownSourceSnapshot() throws {
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        monitor.onPredictionInput = { snapshots.append($0) }
        monitor.recordPredictionText("unknown", processID: 123, sourceLayoutID: "")
        XCTAssertTrue(snapshots.isEmpty)
        monitor.recordPredictionText("ghbd", processID: 123, sourceLayoutID: english)
        XCTAssertEqual(try XCTUnwrap(snapshots.last).suffix, "ghbd")
    }

    @MainActor
    func testOldSourceAfterContextResetCannotPreserveAnEmptySession() throws {
        let monitor = KeyboardMonitor()
        var invalidations = 0
        monitor.onPredictionInvalidated = { invalidations += 1 }
        monitor.recordPredictionText("ghbd", processID: 123, sourceLayoutID: english)
        monitor.resetPredictionContext()
        invalidations = 0
        let generation = monitor.predictionGeneration

        monitor.resetLineBuffer(sourceLayoutID: english)

        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(monitor.predictionGeneration, generation + 1)
    }

    @MainActor
    func testVerifiedAutomaticResultAcceptsItsOwnSourceAcknowledgement() throws {
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        var invalidations = 0
        monitor.onPredictionInput = { snapshots.append($0) }
        monitor.onPredictionInvalidated = { invalidations += 1 }
        monitor.recordPredictionText("ghbd", processID: 123, sourceLayoutID: english)
        monitor.recordPredictionResult(original: "ghbd", replacement: "прив", resultLayoutID: russian)
        invalidations = 0
        let session = monitor.predictionSessionID
        let generation = monitor.predictionGeneration

        monitor.resetLineBuffer(sourceLayoutID: russian)
        monitor.recordPredictionText("е", processID: 123, sourceLayoutID: russian)

        XCTAssertEqual(invalidations, 0)
        let continued = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(continued.suffix, "приве")
        XCTAssertEqual(continued.sessionID, session)
        XCTAssertEqual(continued.generation, generation)
        XCTAssertEqual(continued.sourceLayoutID, russian)
    }
}
