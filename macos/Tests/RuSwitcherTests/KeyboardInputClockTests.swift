import Dispatch
import XCTest
@testable import RuSwitcher

final class KeyboardInputClockTests: XCTestCase {
    private let enToRu = CombinedShiftContext(sourceLayoutID: "en", targetLayoutID: "ru")
    private let ruToEn = CombinedShiftContext(sourceLayoutID: "ru", targetLayoutID: "en")
    private let base: UInt64 = 100_000_000_000

    private func sample(_ physical: UInt64, raw: UInt64?, numerator: UInt32 = 125,
                        denominator: UInt32 = 3) -> KeyboardInputClock {
        KeyboardInputClock(rawTimestamp: raw ?? physical * UInt64(denominator) / UInt64(numerator),
            receivedAt: physical, numerator: numerator, denominator: denominator)
    }

    private func actions(firstUp: UInt64, gap: UInt64, raw: (UInt64) -> UInt64) ->
        [CombinedShiftGesture.Action?] {
        var gesture = CombinedShiftGesture(configuration: .init(doubleWindowNanoseconds: 120_000_000))
        let secondUp = firstUp + gap
        gesture.press(.left, clock: sample(firstUp - 50_000_000, raw: raw(firstUp - 50_000_000)), context: enToRu)
        let first = gesture.release(.left, clock: sample(firstUp, raw: raw(firstUp)))
        gesture.press(.right, clock: sample(secondUp - 50_000_000, raw: raw(secondUp - 50_000_000)), context: ruToEn)
        let second = gesture.release(.right, clock: sample(secondUp, raw: raw(secondUp)))
        return [first, second]
    }

    func testProductionClockBridgePreserves120MillisecondDoubleAndRejects121OneAndTwoSeconds() {
        for raw: (UInt64) -> UInt64 in [{ $0 * 3 / 125 }, { $0 }] {
            for gap: UInt64 in [120_000_000, 121_000_000, 1_000_000_000, 2_000_000_000] {
                let result = actions(firstUp: base + 50_000_000, gap: gap, raw: raw)
                XCTAssertEqual(result[0], .switchLayout(enToRu))
                XCTAssertEqual(result[1], gap <= 120_000_000 ? .convert(enToRu) : .switchLayout(ruToEn),
                    "gap=\(gap)")
            }
        }
    }

    func testZeroAndConstantRawStampsUseArrivalForFastDoubleAndSeparateSlowSolos() {
        for raw: (UInt64) -> UInt64 in [{ _ in 0 }, { _ in self.base }] {
            for gap: UInt64 in [100_000_000, 120_000_000, 121_000_000, 1_000_000_000, 2_000_000_000] {
                let result = actions(firstUp: base + 50_000_000, gap: gap, raw: raw)
                XCTAssertEqual(result[0], .switchLayout(enToRu))
                XCTAssertEqual(result[1], gap <= 120_000_000 ? .convert(enToRu) : .switchLayout(ruToEn),
                    "gap=\(gap)")
            }
        }
    }

    func testReal120MillisecondEventGapSurvivesOneMillisecondCallbackSkew() {
        var gesture = CombinedShiftGesture(configuration: .init(doubleWindowNanoseconds: 120_000_000))
        let firstDown = sample(base, raw: base, numerator: 1, denominator: 1)
        let firstUp = sample(base + 50_000_000, raw: base + 50_000_000, numerator: 1, denominator: 1)
        let secondDown = sample(base + 121_000_000, raw: base + 120_000_000,
            numerator: 1, denominator: 1)
        let secondUp = sample(base + 171_000_000, raw: base + 170_000_000,
            numerator: 1, denominator: 1)
        gesture.press(.left, clock: firstDown, context: enToRu)
        XCTAssertEqual(gesture.release(.left, clock: firstUp), .switchLayout(enToRu))
        gesture.press(.right, clock: secondDown, context: ruToEn)
        XCTAssertEqual(gesture.release(.right, clock: secondUp), .convert(enToRu))
    }

    func testUnknownFutureStaleOverflowAndAmbiguousStampsCannotAuthorizeEventChronology() {
        XCTAssertNil(sample(base, raw: 0).eventTimestamp)
        XCTAssertNil(sample(base, raw: base + 1).eventTimestamp)
        XCTAssertNil(sample(base, raw: base - 1_000_000_001, numerator: 1, denominator: 1).eventTimestamp)
        XCTAssertNil(sample(base, raw: UInt64.max, numerator: UInt32.max, denominator: 1).eventTimestamp)
        XCTAssertNil(KeyboardInputClock(rawTimestamp: 750_000_000, receivedAt: 1_500_000_000,
            numerator: 2, denominator: 1).eventTimestamp)
        XCTAssertEqual(sample(base, raw: base, numerator: 1, denominator: 1).eventTimestamp, base)
        XCTAssertEqual(sample(base, raw: base * 3 / 125).eventTimestamp, base)
    }

    func testConstantRawTimestampCannotTurnLongHoldIntoSolo() {
        var gesture = CombinedShiftGesture(configuration: .init(doubleWindowNanoseconds: 120_000_000))
        gesture.press(.left, clock: sample(base, raw: base), context: enToRu)
        XCTAssertNil(gesture.release(.left, clock: sample(base + 251_000_000, raw: base)))
        gesture.press(.right, clock: sample(base + 300_000_000, raw: base), context: ruToEn)
        XCTAssertEqual(gesture.release(.right, clock: sample(base + 350_000_000, raw: base)), .switchLayout(ruToEn))
    }

    func testNormalizedQueuedPreLeaseKeyRetainsFenceAndSourceChronology() throws {
        let fence = InputEventFence()
        let before = DispatchTime.now().uptimeNanoseconds
        let prior = fence.enterPhysicalEvent(eventTimestamp: before - 5_000_000)
        fence.leavePhysicalEvent(prior)
        let queued = KeyboardInputClock(rawTimestamp: before * 3 / 125, receivedAt: before,
            numerator: 125, denominator: 3)
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        fence.finish(lease, replayLayoutID: "ru")
        let admission = fence.enterPhysicalEvent(eventTimestamp: queued.eventTimestamp)
        defer { fence.leavePhysicalEvent(admission) }
        XCTAssertTrue(admission.needsSourceRefresh)
        XCTAssertEqual(admission.replayLayoutID, "ru")
        var tracker = InputSourceTransitionTracker()
        tracker.recordCompletedWindow(start: before - 5_000_000, end: DispatchTime.now().uptimeNanoseconds)
        XCTAssertTrue(tracker.needsRefresh(eventTimestamp: try XCTUnwrap(queued.eventTimestamp)))
    }

    func testUntrustedRawTimestampCannotKeepIdleFenceRecoding() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        fence.finish(lease, replayLayoutID: "ru")
        for raw: UInt64 in [0, UInt64.max, 1] {
            let clock = KeyboardInputClock(rawTimestamp: raw,
                receivedAt: DispatchTime.now().uptimeNanoseconds, numerator: 125, denominator: 3)
            let admission = fence.enterPhysicalEvent(eventTimestamp: clock.eventTimestamp)
            XCTAssertFalse(admission.needsSourceRefresh)
            XCTAssertNil(admission.replayLayoutID)
            fence.leavePhysicalEvent(admission)
        }
        let constantAfterOneSecond = KeyboardInputClock(rawTimestamp: base,
            receivedAt: base + 1_000_000_001, numerator: 1, denominator: 1)
        XCTAssertNil(constantAfterOneSecond.eventTimestamp)
    }
}
