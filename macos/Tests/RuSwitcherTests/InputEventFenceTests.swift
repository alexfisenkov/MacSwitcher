import Foundation
import XCTest
@testable import RuSwitcher

final class InputEventFenceTests: XCTestCase {
    private final class Callback: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let mayLeave = DispatchSemaphore(value: 0)
        let left = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: InputEventFence.Admission?

        var admission: InputEventFence.Admission? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        init(_ fence: InputEventFence, eventTimestamp: UInt64? = nil) {
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                started.signal()
                let admitted = fence.enterPhysicalEvent(eventTimestamp: eventTimestamp)
                lock.lock()
                result = admitted
                lock.unlock()
                returned.signal()
                mayLeave.wait()
                fence.leavePhysicalEvent(admitted)
                left.signal()
            }
        }

        func release() { mayLeave.signal() }
    }

    func testForwardingCallbacksPreventLeaseUntilEveryCallbackLeaves() throws {
        let fence = InputEventFence()
        let first = fence.enterPhysicalEvent()
        let second = fence.enterPhysicalEvent()
        XCTAssertFalse(first.wasHeld)
        XCTAssertFalse(first.needsSourceRefresh)
        XCTAssertNil(first.replayLayoutID)
        XCTAssertFalse(first.interrupted)
        XCTAssertFalse(second.wasHeld)
        XCTAssertNil(fence.begin(processID: 42))
        fence.leavePhysicalEvent()
        XCTAssertNil(fence.begin(processID: 42))
        fence.leavePhysicalEvent()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        XCTAssertTrue(fence.isCurrent(lease))
        fence.finish(lease, replayLayoutID: nil)
    }

    func testInvalidProcessAndBudgetCannotOpenLease() throws {
        let fence = InputEventFence()
        for processID: Int32 in [0, -1] {
            XCTAssertNil(fence.begin(processID: processID))
        }
        for budget in [0, -0.001, 0.251, TimeInterval.nan, .infinity, -.infinity] {
            XCTAssertNil(fence.begin(processID: 42, maximumDuration: budget))
        }
        XCTAssertTrue(fence.isAvailable)
        let lease = try XCTUnwrap(fence.begin(processID: 42, maximumDuration: 0.250))
        XCTAssertTrue(fence.hasActiveLease)
        XCTAssertNil(fence.begin(processID: 43))
        fence.finish(lease, replayLayoutID: nil)
        XCTAssertFalse(fence.hasActiveLease)
        XCTAssertFalse(fence.isCurrent(lease))
    }

    func testHeldCallbackWaitsForFinishAndKeepsConfirmedReplaySource() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let callback = Callback(fence)
        defer { callback.release() }
        XCTAssertEqual(callback.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 0.020), .timedOut)

        fence.finish(lease, replayLayoutID: "com.apple.keylayout.Russian")
        // This must also hold before the waiting callback has reacquired its lock.
        XCTAssertNil(fence.begin(processID: 43))

        XCTAssertEqual(callback.returned.wait(timeout: .now() + 1), .success)
        let admission = try XCTUnwrap(callback.admission)
        XCTAssertTrue(admission.wasHeld)
        XCTAssertTrue(admission.needsSourceRefresh)
        XCTAssertEqual(admission.replayLayoutID, "com.apple.keylayout.Russian")
        XCTAssertFalse(admission.interrupted)
        XCTAssertNil(fence.begin(processID: 43))
        callback.release()
        XCTAssertEqual(callback.left.wait(timeout: .now() + 1), .success)
        let next = try XCTUnwrap(fence.begin(processID: 43))
        XCTAssertNotEqual(next.generation, lease.generation)
        fence.finish(next, replayLayoutID: nil)
    }

    func testSuccessfulLeaseHoldingShiftDownStillAllowsOneSoloSwitch() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let downTime = DispatchTime.now().uptimeNanoseconds
        let downClock = KeyboardInputClock(rawTimestamp: downTime, receivedAt: downTime,
            numerator: 1, denominator: 1)
        let callback = Callback(fence, eventTimestamp: downClock.eventTimestamp)
        defer { callback.release() }
        XCTAssertEqual(callback.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 0.020), .timedOut)
        fence.finish(lease, replayLayoutID: "ru")
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 1), .success)
        let admission = try XCTUnwrap(callback.admission)
        XCTAssertTrue(admission.wasHeld)
        XCTAssertFalse(admission.interrupted)
        let monitor = KeyboardMonitor()
        XCTAssertTrue(monitor.allowCombinedShift(after: admission))

        let direction = CombinedShiftContext(sourceLayoutID: "en", targetLayoutID: "ru")
        var gesture = CombinedShiftGesture(configuration: .init(doubleWindowNanoseconds: 120_000_000))
        gesture.press(.left, clock: downClock, context: direction)
        let upClock = KeyboardInputClock(rawTimestamp: downTime + 50_000_000,
            receivedAt: downTime + 200_000_000, numerator: 1, denominator: 1)
        XCTAssertEqual(gesture.release(.left, clock: upClock), .switchLayout(direction))
        XCTAssertNil(gesture.release(.left, clock: upClock))
    }

    func testFinishWithoutConfirmedSourceStillReleasesOriginalCallback() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let callback = Callback(fence)
        defer { callback.release() }
        XCTAssertEqual(callback.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 0.020), .timedOut)
        fence.finish(lease, replayLayoutID: nil)
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(try XCTUnwrap(callback.admission).wasHeld)
        XCTAssertEqual(callback.admission?.needsSourceRefresh, true)
        XCTAssertNil(callback.admission?.replayLayoutID)
        XCTAssertEqual(callback.admission?.interrupted, false)
        XCTAssertTrue(fence.isAvailable)
    }

    func testWrongOrStaleLeaseCannotReleaseCurrentTransaction() throws {
        let fence = InputEventFence()
        let previous = try XCTUnwrap(fence.begin(processID: 42))
        fence.finish(previous, replayLayoutID: nil)
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let callback = Callback(fence)
        defer { callback.release() }
        XCTAssertEqual(callback.started.wait(timeout: .now() + 1), .success)
        fence.finish(previous, replayLayoutID: "stale")
        fence.finish(.init(generation: lease.generation, processID: 43, fenceID: lease.fenceID), replayLayoutID: "wrong-pid")
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 0.020), .timedOut)
        XCTAssertTrue(fence.isCurrent(lease))
        fence.finish(lease, replayLayoutID: "confirmed")
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(callback.admission?.replayLayoutID, "confirmed")
    }

    func testLeaseFromPreviousFenceCannotAuthorizeOrFinishFreshFenceWithSamePIDAndGeneration() throws {
        let previousFence = InputEventFence()
        let previous = try XCTUnwrap(previousFence.begin(processID: 42))
        previousFence.interrupt()
        let freshFence = InputEventFence()
        let current = try XCTUnwrap(freshFence.begin(processID: 42))
        XCTAssertEqual(previous.generation, current.generation)
        XCTAssertEqual(previous.processID, current.processID)
        XCTAssertNotEqual(previous, current)
        XCTAssertFalse(freshFence.isCurrent(previous))

        let callback = Callback(freshFence)
        defer { callback.release() }
        XCTAssertEqual(callback.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 0.020), .timedOut)
        freshFence.finish(previous, replayLayoutID: "foreign-fence")
        XCTAssertTrue(freshFence.isCurrent(current))
        XCTAssertTrue(freshFence.hasActiveLease)
        freshFence.finish(current, replayLayoutID: "current-fence")
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(callback.admission?.replayLayoutID, "current-fence")
    }

    func testTimeoutReleasesWaiterAndPermanentlyRejectsFutureLeases() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42, maximumDuration: 0.030))
        let callback = Callback(fence)
        defer { callback.release() }
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(try XCTUnwrap(callback.admission).wasHeld)
        XCTAssertEqual(callback.admission?.needsSourceRefresh, true)
        XCTAssertNil(callback.admission?.replayLayoutID)
        XCTAssertEqual(callback.admission?.interrupted, true)
        XCTAssertFalse(fence.isAvailable)
        XCTAssertFalse(fence.hasActiveLease)
        XCTAssertFalse(fence.isCurrent(lease))
        XCTAssertNotEqual(fence.generation, lease.generation)
        fence.finish(lease, replayLayoutID: "too-late")
        callback.release()
        XCTAssertEqual(callback.left.wait(timeout: .now() + 1), .success)
        XCTAssertNil(fence.begin(processID: 43))
        let later = fence.enterPhysicalEvent()
        XCTAssertFalse(later.wasHeld)
        XCTAssertFalse(later.needsSourceRefresh)
        XCTAssertTrue(later.interrupted)
        XCTAssertNil(later.replayLayoutID)
        fence.leavePhysicalEvent()
    }

    func testInterruptReleasesWaitersAndInvalidatesLeaseWithoutRecovery() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let callbacks = [Callback(fence), Callback(fence)]
        defer { callbacks.forEach { $0.release() } }
        for callback in callbacks {
            XCTAssertEqual(callback.started.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(callback.returned.wait(timeout: .now() + 0.010), .timedOut)
        }
        fence.interrupt()
        fence.finish(lease, replayLayoutID: "too-late")
        for callback in callbacks {
            XCTAssertEqual(callback.returned.wait(timeout: .now() + 1), .success)
            XCTAssertTrue(try XCTUnwrap(callback.admission).wasHeld)
            XCTAssertEqual(callback.admission?.needsSourceRefresh, true)
            XCTAssertEqual(callback.admission?.interrupted, true)
            XCTAssertNil(callback.admission?.replayLayoutID)
            callback.release()
            XCTAssertEqual(callback.left.wait(timeout: .now() + 1), .success)
        }
        XCTAssertFalse(fence.isCurrent(lease))
        XCTAssertFalse(fence.isAvailable)
        XCTAssertNil(fence.begin(processID: 43))
    }

    func testExpiredLeaseCannotBeConfirmedWithoutWaitingCallback() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42, maximumDuration: 0.010))
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.020)
        fence.finish(lease, replayLayoutID: "too-late")
        XCTAssertFalse(fence.isAvailable)
        XCTAssertFalse(fence.isCurrent(lease))
        XCTAssertNil(fence.begin(processID: 43))
    }

    func testEveryHeldCallbackReceivesSameCompletionAndBlocksNextLease() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let callbacks = [Callback(fence), Callback(fence)]
        defer { callbacks.forEach { $0.release() } }
        for callback in callbacks {
            XCTAssertEqual(callback.started.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(callback.returned.wait(timeout: .now() + 0.010), .timedOut)
        }
        fence.finish(lease, replayLayoutID: "confirmed")
        for callback in callbacks {
            XCTAssertEqual(callback.returned.wait(timeout: .now() + 1), .success)
            XCTAssertTrue(try XCTUnwrap(callback.admission).wasHeld)
            XCTAssertEqual(callback.admission?.replayLayoutID, "confirmed")
            XCTAssertEqual(callback.admission?.interrupted, false)
        }
        callbacks[0].release()
        XCTAssertEqual(callbacks[0].left.wait(timeout: .now() + 1), .success)
        XCTAssertNil(fence.begin(processID: 43))
        callbacks[1].release()
        XCTAssertEqual(callbacks[1].left.wait(timeout: .now() + 1), .success)
        let next = try XCTUnwrap(fence.begin(processID: 43))
        fence.finish(next, replayLayoutID: nil)
        let unheld = fence.enterPhysicalEvent()
        XCTAssertFalse(unheld.wasHeld)
        XCTAssertNil(unheld.replayLayoutID)
        fence.leavePhysicalEvent()
    }

    func testSequentialQueuedEventsCreatedDuringLeaseKeepConfirmedReplaySource() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let queuedTimestamps = [DispatchTime.now().uptimeNanoseconds, DispatchTime.now().uptimeNanoseconds]
        fence.finish(lease, replayLayoutID: "com.apple.keylayout.Russian")

        for timestamp in queuedTimestamps {
            let admission = fence.enterPhysicalEvent(eventTimestamp: timestamp)
            XCTAssertFalse(admission.wasHeld)
            XCTAssertTrue(admission.needsSourceRefresh)
            XCTAssertFalse(admission.interrupted)
            XCTAssertEqual(admission.replayLayoutID, "com.apple.keylayout.Russian")
            XCTAssertNil(fence.begin(processID: 43))
            fence.leavePhysicalEvent()
        }
    }

    func testUnheldCallbacksWithoutTimestampInsideCompletedWindowDoNotReplay() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        fence.finish(lease, replayLayoutID: "com.apple.keylayout.Russian")
        let afterFinish = DispatchTime.now().uptimeNanoseconds + 1

        for timestamp: UInt64? in [nil, 0, 1, afterFinish, UInt64.max] {
            let admission = fence.enterPhysicalEvent(eventTimestamp: timestamp)
            XCTAssertFalse(admission.wasHeld)
            XCTAssertFalse(admission.needsSourceRefresh)
            XCTAssertFalse(admission.interrupted)
            XCTAssertNil(admission.replayLayoutID)
            fence.leavePhysicalEvent()
        }
    }

    func testInterruptionDiscardsCompletedTimestampWindow() throws {
        let fence = InputEventFence()
        var queuedTimestamps: [UInt64] = []
        for source in ["com.apple.keylayout.Russian", "com.apple.keylayout.ABC"] {
            let lease = try XCTUnwrap(fence.begin(processID: 42))
            queuedTimestamps.append(DispatchTime.now().uptimeNanoseconds)
            fence.finish(lease, replayLayoutID: source)
        }
        fence.interrupt()

        for timestamp in queuedTimestamps {
            let admission = fence.enterPhysicalEvent(eventTimestamp: timestamp)
            XCTAssertFalse(admission.wasHeld)
            XCTAssertFalse(admission.needsSourceRefresh)
            XCTAssertTrue(admission.interrupted)
            XCTAssertNil(admission.replayLayoutID)
            fence.leavePhysicalEvent()
        }
    }

    func testSecondQueuedCallbackKeepsReceiptAfterFirstLeavesAndAnotherLeaseCompletes() throws {
        let fence = InputEventFence()
        let previous = try XCTUnwrap(fence.begin(processID: 42))
        let oldTimestamp = DispatchTime.now().uptimeNanoseconds
        let firstCallback = Callback(fence)
        defer { firstCallback.release() }
        XCTAssertEqual(firstCallback.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(firstCallback.returned.wait(timeout: .now() + 0.020), .timedOut)
        fence.finish(previous, replayLayoutID: "com.apple.keylayout.Russian")
        XCTAssertEqual(firstCallback.returned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(firstCallback.admission?.needsSourceRefresh, true)
        XCTAssertEqual(firstCallback.admission?.replayLayoutID, "com.apple.keylayout.Russian")
        XCTAssertNil(fence.begin(processID: 43))
        firstCallback.release()
        XCTAssertEqual(firstCallback.left.wait(timeout: .now() + 1), .success)

        let current = try XCTUnwrap(fence.begin(processID: 42))
        let currentTimestamp = DispatchTime.now().uptimeNanoseconds
        fence.finish(current, replayLayoutID: "com.apple.keylayout.ABC")

        let oldAdmission = fence.enterPhysicalEvent(eventTimestamp: oldTimestamp)
        XCTAssertFalse(oldAdmission.wasHeld)
        XCTAssertTrue(oldAdmission.needsSourceRefresh)
        XCTAssertEqual(oldAdmission.replayLayoutID, "com.apple.keylayout.Russian")
        XCTAssertNil(fence.begin(processID: 43))
        fence.leavePhysicalEvent()
        let currentAdmission = fence.enterPhysicalEvent(eventTimestamp: currentTimestamp)
        XCTAssertFalse(currentAdmission.wasHeld)
        XCTAssertTrue(currentAdmission.needsSourceRefresh)
        XCTAssertEqual(currentAdmission.replayLayoutID, "com.apple.keylayout.ABC")
        fence.leavePhysicalEvent()
    }

    func testQueuedTimestampCannotInventUnconfirmedReplaySource() throws {
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let queuedTimestamp = DispatchTime.now().uptimeNanoseconds
        fence.finish(lease, replayLayoutID: nil)
        let newer = try XCTUnwrap(fence.begin(processID: 42))
        fence.finish(newer, replayLayoutID: "com.apple.keylayout.ABC")
        let admission = fence.enterPhysicalEvent(eventTimestamp: queuedTimestamp)
        XCTAssertTrue(admission.needsSourceRefresh)
        XCTAssertNil(admission.replayLayoutID)
        XCTAssertFalse(admission.interrupted)
        fence.leavePhysicalEvent()
    }

    func testOnlyLatest64CompletedWindowsRetainSourceReceipts() throws {
        let fence = InputEventFence()
        var timestamps: [UInt64] = []
        for _ in 0..<65 {
            let lease = try XCTUnwrap(fence.begin(processID: 42))
            timestamps.append(DispatchTime.now().uptimeNanoseconds)
            fence.finish(lease, replayLayoutID: "com.apple.keylayout.Russian")
        }
        for (index, expectedRefresh) in [(0, false), (1, true), (64, true)] {
            let admission = fence.enterPhysicalEvent(eventTimestamp: timestamps[index])
            XCTAssertEqual(admission.needsSourceRefresh, expectedRefresh)
            XCTAssertEqual(admission.replayLayoutID, expectedRefresh ? "com.apple.keylayout.Russian" : nil)
            fence.leavePhysicalEvent()
        }
    }

    func testCompletedWindowStartsAfterKnownForwardedEventBeforeLeaseStart() throws {
        let fence = InputEventFence()
        let baseline = DispatchTime.now().uptimeNanoseconds
        let prior = fence.enterPhysicalEvent(eventTimestamp: baseline)
        fence.leavePhysicalEvent(prior)
        let queuedBeforeLease = DispatchTime.now().uptimeNanoseconds
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        fence.finish(lease, replayLayoutID: "ru")

        for (timestamp, expected) in [(baseline - 1, false), (baseline, false),
                                       (UInt64(0), false), (queuedBeforeLease, true)] {
            let admission = fence.enterPhysicalEvent(eventTimestamp: timestamp)
            XCTAssertEqual(admission.needsSourceRefresh, expected)
            XCTAssertEqual(admission.replayLayoutID, expected ? "ru" : nil)
            fence.leavePhysicalEvent(admission)
        }
    }

    func testConsumedOrUnknownTimestampCannotEstablishEarlierWindowBaseline() throws {
        let cases: [(UInt64?, Bool)] = [(nil, true), (0, true), (UInt64.max, true),
                                       (DispatchTime.now().uptimeNanoseconds, false)]
        for (timestamp, forwarded) in cases {
            let fence = InputEventFence()
            let consumed = fence.enterPhysicalEvent(eventTimestamp: timestamp)
            fence.leavePhysicalEvent(consumed, wasForwarded: forwarded)
            let beforeLease = DispatchTime.now().uptimeNanoseconds
            let lease = try XCTUnwrap(fence.begin(processID: 42))
            fence.finish(lease, replayLayoutID: "ru")
            let queued = fence.enterPhysicalEvent(eventTimestamp: beforeLease)
            XCTAssertFalse(queued.needsSourceRefresh)
            fence.leavePhysicalEvent(queued)
        }
    }

    func testOutOfOrderForwardingCannotMoveBaselineBackwards() throws {
        let fence = InputEventFence()
        let oldest = DispatchTime.now().uptimeNanoseconds
        let older = fence.enterPhysicalEvent(eventTimestamp: oldest)
        let newerTimestamp = DispatchTime.now().uptimeNanoseconds
        let newer = fence.enterPhysicalEvent(eventTimestamp: newerTimestamp)
        fence.leavePhysicalEvent(newer)
        fence.leavePhysicalEvent(older)
        let queued = DispatchTime.now().uptimeNanoseconds
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        fence.finish(lease, replayLayoutID: "ru")
        for (timestamp, expected) in [(oldest, false), (newerTimestamp, false), (queued, true)] {
            let admission = fence.enterPhysicalEvent(eventTimestamp: timestamp)
            XCTAssertEqual(admission.needsSourceRefresh, expected)
            fence.leavePhysicalEvent(admission)
        }
    }

    func testHeldCallbackCompletionCannotReplaceFrozenEarlierReceiptBoundary() throws {
        let fence = InputEventFence()
        let prior = fence.enterPhysicalEvent(eventTimestamp: DispatchTime.now().uptimeNanoseconds)
        fence.leavePhysicalEvent(prior)
        let queuedBeforeLease = DispatchTime.now().uptimeNanoseconds
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let held = Callback(fence, eventTimestamp: DispatchTime.now().uptimeNanoseconds)
        defer { held.release() }
        XCTAssertEqual(held.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(held.returned.wait(timeout: .now() + 0.010), .timedOut)
        fence.finish(lease, replayLayoutID: "ru")
        XCTAssertEqual(held.returned.wait(timeout: .now() + 1), .success)
        held.release()
        XCTAssertEqual(held.left.wait(timeout: .now() + 1), .success)

        let queued = fence.enterPhysicalEvent(eventTimestamp: queuedBeforeLease)
        XCTAssertTrue(queued.needsSourceRefresh)
        XCTAssertEqual(queued.replayLayoutID, "ru")
        fence.leavePhysicalEvent(queued)
    }
}
