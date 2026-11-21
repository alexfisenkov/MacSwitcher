import XCTest
@testable import RuSwitcher

final class AutoCorrectionLoopGuardTests: XCTestCase {
    private var trips = 0

    private func makeGuard() -> AutoCorrectionLoopGuard {
        trips = 0
        return AutoCorrectionLoopGuard(onTrip: { [unowned self] in self.trips += 1 })
    }

    func testIdleGuardAllows() {
        XCTAssertTrue(makeGuard().allow(now: 10))
    }

    func testReversalOfSameWordWithinWindowFreezesForTwoAndHalfSeconds() {
        let guardrail = makeGuard()
        guardrail.record(original: "ghbdtn", replacement: "привет", now: 10)
        XCTAssertFalse(guardrail.allow(now: 10.5, original: "привет", replacement: "ghbdtn"))
        XCTAssertEqual(trips, 1)
        XCTAssertFalse(guardrail.allow(now: 12.9))
        XCTAssertTrue(guardrail.allow(now: 13.1))
    }

    func testReversalIsAlsoCaughtWhenRecordedAfterTheFact() {
        let guardrail = makeGuard()
        guardrail.record(original: "ghbdtn", replacement: "привет", now: 10)
        guardrail.record(original: "привет", replacement: "ghbdtn", now: 10.4)
        XCTAssertEqual(trips, 1)
        XCTAssertFalse(guardrail.allow(now: 11))
    }

    func testReversalAfterSevenTenthsIsNotALoop() {
        let guardrail = makeGuard()
        guardrail.record(original: "ghbdtn", replacement: "привет", now: 10)
        XCTAssertTrue(guardrail.allow(now: 10.8, original: "привет", replacement: "ghbdtn"))
        XCTAssertEqual(trips, 0)
    }

    func testDifferentWordsAreNotAReversal() {
        let guardrail = makeGuard()
        guardrail.record(original: "ghbdtn", replacement: "привет", now: 10)
        XCTAssertTrue(guardrail.allow(now: 10.2, original: "rfr", replacement: "как"))
        XCTAssertEqual(trips, 0)
    }

    func testSixCorrectionsPerSecondPassAndSeventhFreezes() {
        let guardrail = makeGuard()
        for index in 0..<6 {
            let now = 20 + Double(index) * 0.1
            XCTAssertTrue(guardrail.allow(now: now), "correction \(index + 1)")
            guardrail.record(original: "a\(index)", replacement: "b\(index)", now: now)
        }
        XCTAssertFalse(guardrail.allow(now: 20.65))
        XCTAssertEqual(trips, 1)
        XCTAssertFalse(guardrail.allow(now: 23.0))
        XCTAssertTrue(guardrail.allow(now: 23.2))
    }

    func testSlowCorrectionsNeverTrip() {
        let guardrail = makeGuard()
        for index in 0..<20 {
            let now = 30 + Double(index) * 0.5
            XCTAssertTrue(guardrail.allow(now: now))
            guardrail.record(original: "a\(index)", replacement: "b\(index)", now: now)
        }
        XCTAssertEqual(trips, 0)
    }

    func testTripCodeIsRepeatableAndHasNoTextPayload() {
        XCTAssertFalse(RuntimeDiagnosticEvent.autoLoopGuardTripped.logOnce)
        XCTAssertTrue(RuntimeDiagnosticEvent.autoEditPosted.logOnce)
    }
}
