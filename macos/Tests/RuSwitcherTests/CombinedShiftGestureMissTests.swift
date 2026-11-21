import XCTest
@testable import RuSwitcher

/// Window misses are observed, never acted on: the actions stay exactly as before.
final class CombinedShiftGestureMissTests: XCTestCase {
    private let enToRu = CombinedShiftContext(sourceLayoutID: "en", targetLayoutID: "ru")
    private let ruToEn = CombinedShiftContext(sourceLayoutID: "ru", targetLayoutID: "en")
    private let ms: UInt64 = 1_000_000

    private func clock(event: UInt64, arrival: UInt64) -> KeyboardInputClock {
        KeyboardInputClock(rawTimestamp: event * ms, receivedAt: arrival * ms, numerator: 1, denominator: 1)
    }

    func testSecondTapAfterWindowIsAMissButStillASolo() {
        var gesture = CombinedShiftGesture()
        gesture.press(.left, at: 10 * ms, context: enToRu)
        XCTAssertEqual(gesture.release(.left, at: 60 * ms), .switchLayout(enToRu))
        XCTAssertNil(gesture.lastMiss)
        gesture.press(.left, at: 200 * ms, context: ruToEn)
        XCTAssertEqual(gesture.release(.left, at: 241 * ms), .switchLayout(ruToEn))
        XCTAssertEqual(gesture.lastMiss, .window)
    }

    func testInWindowDoubleAndDistantSoloAreNotMisses() {
        var gesture = CombinedShiftGesture()
        gesture.press(.left, at: 10 * ms, context: enToRu)
        _ = gesture.release(.left, at: 60 * ms)
        gesture.press(.left, at: 130 * ms, context: ruToEn)
        XCTAssertEqual(gesture.release(.left, at: 180 * ms), .convert(enToRu))
        XCTAssertNil(gesture.lastMiss)
        gesture.press(.left, at: 5_000 * ms, context: enToRu)
        XCTAssertEqual(gesture.release(.left, at: 5_050 * ms), .switchLayout(enToRu))
        gesture.press(.left, at: 8_000 * ms, context: ruToEn)
        XCTAssertEqual(gesture.release(.left, at: 8_050 * ms), .switchLayout(ruToEn))
        XCTAssertNil(gesture.lastMiss, "a separate solo seconds later is not a near miss")
    }

    @MainActor
    func testMonitorRecordsBothMissEventsWithoutChangingActions() {
        let monitor = KeyboardMonitor()
        var events: [RuntimeDiagnosticEvent] = []
        monitor.gestureMissRecorder = { events.append($0) }
        func tap(_ down: UInt64, _ up: UInt64, arrivalOffset: UInt64 = 0,
                 _ context: CombinedShiftContext) -> CombinedShiftGesture.Action? {
            _ = monitor.recognizeCombinedShift(side: .left, isPressed: true,
                clock: clock(event: down, arrival: down + arrivalOffset), context: context)
            return monitor.recognizeCombinedShift(side: .left, isPressed: false,
                clock: clock(event: up, arrival: up + arrivalOffset))
        }
        XCTAssertEqual(tap(10, 60, enToRu), .switchLayout(enToRu))
        XCTAssertEqual(tap(200, 250, ruToEn), .switchLayout(ruToEn))
        XCTAssertEqual(events, [.doubleWindowMissed])
        XCTAssertEqual(tap(300, 350, arrivalOffset: 70, enToRu), .switchLayout(enToRu))
        XCTAssertEqual(events, [.doubleWindowMissed, .doubleArrivalSkewRejected])
    }

    func testArrivalSkewRejectionIsReported() {
        var gesture = CombinedShiftGesture()
        gesture.press(.left, clock: clock(event: 10, arrival: 10), context: enToRu)
        XCTAssertEqual(gesture.release(.left, clock: clock(event: 60, arrival: 60)), .switchLayout(enToRu))
        // Event clock: 100 ms between releases; callbacks arrived 170 ms apart.
        gesture.press(.left, clock: clock(event: 110, arrival: 180), context: ruToEn)
        XCTAssertEqual(gesture.release(.left, clock: clock(event: 160, arrival: 230)), .switchLayout(ruToEn))
        XCTAssertEqual(gesture.lastMiss, .arrivalSkew)
    }
}
