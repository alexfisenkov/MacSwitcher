import XCTest
@testable import RuSwitcher

final class CombinedShiftGestureTests: XCTestCase {
    private let enToRu = CombinedShiftContext(sourceLayoutID: "en", targetLayoutID: "ru")
    private let ruToEn = CombinedShiftContext(sourceLayoutID: "ru", targetLayoutID: "en")
    private let ms: UInt64 = 1_000_000

    private func tap(_ gesture: inout CombinedShiftGesture, _ side: CombinedShiftGesture.Side,
                     down: UInt64, up: UInt64, context: CombinedShiftContext) -> CombinedShiftGesture.Action? {
        gesture.press(side, at: down * ms, context: context)
        return gesture.release(side, at: up * ms)
    }

    func testSingleSwitchesImmediatelyOnReleaseWithOriginalSource() {
        var gesture = CombinedShiftGesture()
        gesture.press(.left, at: 10 * ms, context: enToRu)
        XCTAssertEqual(gesture.release(.left, at: 60 * ms), .switchLayout(enToRu))
    }

    func testWrongScaleRawTimestampCannotTurnTwoSecondsIntoDouble() {
        var gesture = CombinedShiftGesture(configuration: .init(doubleWindowNanoseconds: 120_000_000))
        let base: UInt64 = 100_000_000_000
        func clock(_ nanoseconds: UInt64) -> KeyboardInputClock {
            KeyboardInputClock(rawTimestamp: nanoseconds * 3 / 125, receivedAt: nanoseconds,
                numerator: 125, denominator: 3)
        }
        gesture.press(.left, clock: clock(base), context: enToRu)
        XCTAssertEqual(gesture.release(.left, clock: clock(base + 50_000_000)), .switchLayout(enToRu))
        gesture.press(.right, clock: clock(base + 2_000_000_000), context: ruToEn)
        XCTAssertEqual(gesture.release(.right, clock: clock(base + 2_050_000_000)), .switchLayout(ruToEn))
    }

    func testDoubleConvertsUsingSourceBeforeFirstSwitch() {
        var gesture = CombinedShiftGesture()
        XCTAssertEqual(tap(&gesture, .left, down: 10, up: 60, context: enToRu), .switchLayout(enToRu))
        // The first single has already switched the current source to Russian.
        XCTAssertEqual(tap(&gesture, .left, down: 130, up: 180, context: ruToEn), .convert(enToRu))
    }

    func testEitherSideAndMixedDoubleAreAccepted() {
        for sides: [CombinedShiftGesture.Side] in [[.left, .right], [.right, .left], [.right, .right]] {
            var gesture = CombinedShiftGesture()
            XCTAssertEqual(tap(&gesture, sides[0], down: 10, up: 60, context: enToRu), .switchLayout(enToRu))
            XCTAssertEqual(tap(&gesture, sides[1], down: 130, up: 180, context: ruToEn), .convert(enToRu))
        }
    }

    func testHoldOver250msDoesNothingAndCancelsPendingDouble() {
        var gesture = CombinedShiftGesture()
        XCTAssertEqual(tap(&gesture, .left, down: 10, up: 260, context: enToRu), .switchLayout(enToRu))
        XCTAssertNil(tap(&gesture, .right, down: 300, up: 551, context: ruToEn))
        XCTAssertEqual(tap(&gesture, .left, down: 560, up: 580, context: ruToEn), .switchLayout(ruToEn))
    }

    func testThinkingPauseBeyond180msProducesSeparateImmediateSingleSwitches() {
        var gesture = CombinedShiftGesture()
        XCTAssertEqual(tap(&gesture, .left, down: 10, up: 60, context: enToRu), .switchLayout(enToRu))
        XCTAssertEqual(tap(&gesture, .right, down: 241, up: 291, context: ruToEn), .switchLayout(ruToEn))
    }

    func testSecondReleaseExactly180msAfterFirstStillConverts() {
        var gesture = CombinedShiftGesture()
        XCTAssertEqual(tap(&gesture, .left, down: 10, up: 60, context: enToRu), .switchLayout(enToRu))
        XCTAssertEqual(tap(&gesture, .right, down: 190, up: 240, context: ruToEn), .convert(enToRu))
    }

    func testSecondReleaseOneNanosecondBeyond180msStartsNewSingle() {
        var gesture = CombinedShiftGesture()
        XCTAssertEqual(tap(&gesture, .left, down: 10, up: 60, context: enToRu), .switchLayout(enToRu))
        gesture.press(.right, at: 190 * ms, context: ruToEn)
        XCTAssertEqual(gesture.release(.right, at: 240 * ms + 1), .switchLayout(ruToEn))
    }

    func testTapAfterThinkingPauseStartsItsOwnDoubleInNewDirection() {
        var gesture = CombinedShiftGesture()
        XCTAssertEqual(tap(&gesture, .left, down: 10, up: 60, context: enToRu), .switchLayout(enToRu))
        XCTAssertEqual(tap(&gesture, .right, down: 241, up: 291, context: ruToEn), .switchLayout(ruToEn))
        XCTAssertEqual(tap(&gesture, .left, down: 330, up: 370, context: enToRu), .convert(ruToEn))
    }

    func testKeyMouseOrModifierInterruptionCancelsPressAndPendingTap() {
        // KeyboardMonitor routes every real keyDown, mouse click/scroll, or other modifier here.
        for _ in 0..<3 {
            var gesture = CombinedShiftGesture()
            XCTAssertEqual(tap(&gesture, .left, down: 10, up: 60, context: enToRu), .switchLayout(enToRu))
            gesture.press(.right, at: 100 * ms, context: ruToEn)
            gesture.interrupt()
            XCTAssertNil(gesture.release(.right, at: 160 * ms))
            XCTAssertEqual(tap(&gesture, .left, down: 180, up: 220, context: ruToEn), .switchLayout(ruToEn))
        }
    }

    func testOverlappingShiftChordDoesNotBecomeSolo() {
        var gesture = CombinedShiftGesture()
        gesture.press(.left, at: 10 * ms, context: enToRu)
        gesture.press(.right, at: 20 * ms, context: enToRu)
        XCTAssertNil(gesture.release(.right, at: 30 * ms))
        XCTAssertNil(gesture.release(.left, at: 40 * ms))
    }

    func testTimestampRollbackCannotMasqueradeAsFastTap() {
        var gesture = CombinedShiftGesture()
        gesture.press(.left, at: 100 * ms, context: enToRu)
        XCTAssertNil(gesture.release(.left, at: 90 * ms))
        XCTAssertEqual(tap(&gesture, .right, down: 110, up: 120, context: enToRu), .switchLayout(enToRu))
        // A rolled-back second press/release is not accepted as the previous double.
        XCTAssertEqual(tap(&gesture, .left, down: 70, up: 80, context: ruToEn), .switchLayout(ruToEn))
    }

    func testReleaseWithoutMatchingPressIsIgnored() {
        var gesture = CombinedShiftGesture()
        XCTAssertNil(gesture.release(.left, at: 40 * ms))
        gesture.press(.left, at: 50 * ms, context: enToRu)
        XCTAssertNil(gesture.release(.right, at: 90 * ms))
        XCTAssertNil(gesture.release(.left, at: 100 * ms))
    }

    func testTripleTapProducesSingleDoubleSingle() {
        for (firstDirection, nextDirection) in [(enToRu, ruToEn), (ruToEn, enToRu)] {
            var gesture = CombinedShiftGesture()
            XCTAssertEqual(tap(&gesture, .left, down: 10, up: 50, context: firstDirection), .switchLayout(firstDirection))
            XCTAssertEqual(tap(&gesture, .right, down: 100, up: 140, context: nextDirection), .convert(firstDirection))
            XCTAssertEqual(tap(&gesture, .left, down: 180, up: 220, context: nextDirection), .switchLayout(nextDirection))
        }
    }

    func testTwoDoublePairsPreserveEachOriginalDirectionForUndo() {
        var gesture = CombinedShiftGesture()
        XCTAssertEqual(tap(&gesture, .left, down: 10, up: 50, context: enToRu), .switchLayout(enToRu))
        XCTAssertEqual(tap(&gesture, .right, down: 100, up: 140, context: ruToEn), .convert(enToRu))
        XCTAssertEqual(tap(&gesture, .left, down: 180, up: 220, context: ruToEn), .switchLayout(ruToEn))
        XCTAssertEqual(tap(&gesture, .right, down: 280, up: 320, context: enToRu), .convert(ruToEn))
    }

    func testEmptyTextDoesNotProduceSecondLayoutSwitch() {
        // Empty/nonempty text is deliberately outside this state machine; the second action
        // can only request conversion. A no-op conversion leaves the first switch in place.
        var gesture = CombinedShiftGesture()
        let first = tap(&gesture, .left, down: 10, up: 50, context: enToRu)
        let second = tap(&gesture, .right, down: 100, up: 140, context: ruToEn)
        XCTAssertEqual(first, .switchLayout(enToRu))
        XCTAssertEqual(second, .convert(enToRu))
        XCTAssertNotEqual(second, .switchLayout(ruToEn))
    }
}
