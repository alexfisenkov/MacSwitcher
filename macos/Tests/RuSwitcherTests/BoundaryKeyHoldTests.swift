import XCTest
@testable import RuSwitcher

/// The tap-thread half of the Enter/Tab hold: the key value is returned
/// exactly once, after the decision, at most 150 ms without a write, and
/// never while an edit lease is active.
final class BoundaryKeyHoldTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        private var finishedAt: TimeInterval?
        var outcome: BoundaryKeyHold.Outcome?
        func record(_ value: Int, outcome: BoundaryKeyHold.Outcome) {
            lock.lock(); values.append(value); self.outcome = outcome
            finishedAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
        }
        var snapshot: (values: [Int], at: TimeInterval?) {
            lock.lock(); defer { lock.unlock() }; return (values, finishedAt)
        }
    }

    private func forwardInBackground(_ hold: BoundaryKeyHold, _ ticket: BoundaryKeyHold.Ticket,
                                     fence: InputEventFence, box: Box) -> XCTestExpectation {
        let done = expectation(description: "forwarded")
        Thread.detachNewThread {
            let result = hold.forward(7, ticket: ticket, fence: fence, eventTimestamp: nil)
            box.record(result.value, outcome: result.outcome)
            done.fulfill()
        }
        return done
    }

    func testDecisionInsideTheWindowForwardsTheSameKeyOnceAfterCompletion() {
        let hold = BoundaryKeyHold(), fence = InputEventFence(), box = Box()
        let ticket = hold.arm()
        let started = ProcessInfo.processInfo.systemUptime
        let done = forwardInBackground(hold, ticket, fence: fence, box: box)
        Thread.sleep(forTimeInterval: 0.020)
        XCTAssertTrue(box.snapshot.values.isEmpty, "The key must wait for the decision")
        hold.complete(ticket)
        wait(for: [done], timeout: 1)
        XCTAssertEqual(box.snapshot.values, [7])
        XCTAssertEqual(box.outcome, .completed)
        XCTAssertLessThan((box.snapshot.at ?? .infinity) - started, BoundaryKeyHold.maximumHold)
    }

    func testUndecidedHoldReleasesTheKeyUnchangedWithin150msAndRefusesALateWrite() {
        let hold = BoundaryKeyHold(), fence = InputEventFence(), box = Box()
        let ticket = hold.arm()
        let started = ProcessInfo.processInfo.systemUptime
        let done = forwardInBackground(hold, ticket, fence: fence, box: box)
        wait(for: [done], timeout: 1)
        let elapsed = (box.snapshot.at ?? .infinity) - started
        XCTAssertEqual(box.snapshot.values, [7])
        XCTAssertEqual(box.outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(elapsed, BoundaryKeyHold.maximumHold - 0.005)
        XCTAssertLessThan(elapsed, BoundaryKeyHold.maximumHold + 0.080)
        XCTAssertFalse(hold.beginWrite(ticket), "No write may start after the key has gone")
    }

    func testBegunWriteKeepsTheKeyBehindItsLeaseUntilTheLeaseEnds() {
        let hold = BoundaryKeyHold(), fence = InputEventFence(), box = Box()
        let ticket = hold.arm()
        XCTAssertTrue(hold.beginWrite(ticket))
        let lease = fence.begin(processID: 42, maximumDuration: 0.250)
        XCTAssertNotNil(lease)
        let done = forwardInBackground(hold, ticket, fence: fence, box: box)
        // Past the 150 ms window the edit is still running: the key waits.
        Thread.sleep(forTimeInterval: 0.170)
        XCTAssertTrue(box.snapshot.values.isEmpty, "The key must never land inside an edit")
        let finishedLease = ProcessInfo.processInfo.systemUptime
        if let lease { fence.finish(lease, replayLayoutID: nil) }
        hold.complete(ticket)
        wait(for: [done], timeout: 1)
        XCTAssertEqual(box.snapshot.values, [7])
        XCTAssertGreaterThanOrEqual(box.snapshot.at ?? 0, finishedLease)
        XCTAssertTrue(fence.isAvailable)
    }

    func testANewerKeyRetiresAnOlderHold() {
        let hold = BoundaryKeyHold()
        let old = hold.arm()
        let newer = hold.arm()
        XCTAssertFalse(hold.beginWrite(old))
        XCTAssertTrue(hold.isFinished(old))
        XCTAssertTrue(hold.beginWrite(newer))
    }
}
