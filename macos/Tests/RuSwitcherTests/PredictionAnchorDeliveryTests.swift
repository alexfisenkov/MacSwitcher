import XCTest
@testable import RuSwitcher

final class PredictionAnchorDeliveryTests: XCTestCase {
    func testFirstCaptureBeforeGlyphResolvesAfterCompleteWordIsRendered() throws {
        var pending = try XCTUnwrap(PredictionPendingCaretAnchor(sessionID: 7,
            caretUTF16Location: 100, inputUTF16Offset: 1, eventUTF16Length: 1))
        let resolved = try XCTUnwrap(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertTrue(resolved.permits(location: 106, selectionLength: 0, cumulativeOffset: 6))
        XCTAssertTrue(resolved.permits(location: 107, selectionLength: 0, cumulativeOffset: 7))
        XCTAssertFalse(resolved.permits(location: 506, selectionLength: 0, cumulativeOffset: 6))
    }

    func testFirstCaptureAfterGlyphKeepsDeliveredOffset() throws {
        var pending = try XCTUnwrap(PredictionPendingCaretAnchor(sessionID: 7,
            caretUTF16Location: 101, inputUTF16Offset: 1, eventUTF16Length: 1))
        let resolved = try XCTUnwrap(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertEqual(resolved.inputUTF16Offset, 1)
        XCTAssertEqual(resolved.caretUTF16Location, 101)
    }

    func testStaleFirstSnapshotDoesNotPoisonTheSameOriginalFieldAfterBurst() throws {
        var pending = try XCTUnwrap(PredictionPendingCaretAnchor(sessionID: 7,
            caretUTF16Location: 40, inputUTF16Offset: 1, eventUTF16Length: 1))
        XCTAssertNil(pending.resolve(sessionID: 7, location: 40, selectionLength: 0,
            cumulativeOffset: 1, sameField: true, snapshotIsCurrent: false, suffixMatches: false))
        let current = try XCTUnwrap(pending.resolve(sessionID: 7, location: 42, selectionLength: 0,
            cumulativeOffset: 2, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertTrue(current.permits(location: 46, selectionLength: 0, cumulativeOffset: 6))
    }

    func testDifferentFieldCancelsPendingAnchorEvenIfOriginalFieldReturns() throws {
        var pending = try XCTUnwrap(PredictionPendingCaretAnchor(sessionID: 7,
            caretUTF16Location: 100, inputUTF16Offset: 1, eventUTF16Length: 1))
        XCTAssertNil(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 6, sameField: false, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertNil(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
    }

    func testExactSuffixAndBoundedCaretCandidatesAreRequiredBeforeResolution() throws {
        var pending = try XCTUnwrap(PredictionPendingCaretAnchor(sessionID: 7,
            caretUTF16Location: 100, inputUTF16Offset: 1, eventUTF16Length: 1))
        XCTAssertNil(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: false))
        XCTAssertNil(pending.resolve(sessionID: 7, location: 506, selectionLength: 0,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertNil(pending.resolve(sessionID: 7, location: 106, selectionLength: 1,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertNotNil(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
    }

    func testFirstPayloadLengthIsUTF16AndCannotExpandToAnArbitraryJump() throws {
        var pending = try XCTUnwrap(PredictionPendingCaretAnchor(sessionID: 7,
            caretUTF16Location: 100, inputUTF16Offset: 2, eventUTF16Length: 2))
        XCTAssertNil(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 5, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertNotNil(pending.resolve(sessionID: 7, location: 105, selectionLength: 0,
            cumulativeOffset: 5, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertNil(PredictionPendingCaretAnchor(sessionID: 7,
            caretUTF16Location: 0, inputUTF16Offset: 1, eventUTF16Length: 2))
    }

    func testSessionResetCannotReusePendingCaret() throws {
        var pending = try XCTUnwrap(PredictionPendingCaretAnchor(sessionID: 7,
            caretUTF16Location: 100, inputUTF16Offset: 1, eventUTF16Length: 1))
        XCTAssertNil(pending.resolve(sessionID: 8, location: 106, selectionLength: 0,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertNil(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
    }

    func testResolvedCaretCannotSwitchToTheOtherDeliveryCandidateLater() throws {
        var pending = try XCTUnwrap(PredictionPendingCaretAnchor(sessionID: 7,
            caretUTF16Location: 100, inputUTF16Offset: 1, eventUTF16Length: 1))
        XCTAssertNotNil(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 6, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        // Once the before-delivery interpretation is established, a one-unit
        // programmatic caret jump must not acquire the other candidate.
        XCTAssertNil(pending.resolve(sessionID: 7, location: 106, selectionLength: 0,
            cumulativeOffset: 7, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
        XCTAssertNotNil(pending.resolve(sessionID: 7, location: 107, selectionLength: 0,
            cumulativeOffset: 7, sameField: true, snapshotIsCurrent: true, suffixMatches: true))
    }

    func testSnapshotTracksTheLatestPayloadRatherThanWholeWindowLength() throws {
        var buffer = PredictionInputBuffer()
        buffer.append("  ", processID: 123)
        buffer.append("😀", processID: 123)
        let first = try XCTUnwrap(buffer.snapshot(sourceLayoutID: "en", inputRevision: 1, generation: 1))
        XCTAssertEqual(first.cumulativeUTF16Offset, 4)
        XCTAssertEqual(first.eventUTF16Length, 2)
        buffer.append("g", processID: 123)
        let next = try XCTUnwrap(buffer.snapshot(sourceLayoutID: "en", inputRevision: 2, generation: 2))
        XCTAssertEqual(next.cumulativeUTF16Offset, 5)
        XCTAssertEqual(next.eventUTF16Length, 1)
    }
}
