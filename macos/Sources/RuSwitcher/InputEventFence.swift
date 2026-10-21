import Foundation

/// Holds the OS-owned callback on the tap thread; it never stores input events.
/// Every enter must be paired with leave after the callback finishes forwarding.
final class InputEventFence: @unchecked Sendable {
    struct Lease: Equatable, Sendable {
        let generation: UInt64
        let processID: Int32
        let fenceID: UUID

        init(generation: UInt64, processID: Int32, fenceID: UUID = UUID()) {
            self.generation = generation
            self.processID = processID
            self.fenceID = fenceID
        }
    }

    struct Admission: Sendable {
        let wasHeld: Bool
        /// Re-read the actual source at forwarding time; replay ID is a receipt.
        let needsSourceRefresh: Bool
        let replayLayoutID: String?
        let interrupted: Bool
    }

    private struct ActiveLease {
        let lease: Lease
        let startedAt: UInt64
        let deadline: TimeInterval
    }

    private struct Completion {
        let generation: UInt64
        let startedAt: UInt64
        let finishedAt: UInt64
        let replayLayoutID: String?
    }

    private let fenceID = UUID()
    private let condition = NSCondition()
    private var currentGeneration: UInt64 = 0
    private var active: ActiveLease?
    private var waitingCallbacks = 0
    private var forwardingCallbacks = 0
    private var blocked = false
    // Later leases must not erase receipts for events still queued by the OS.
    private var completions: [Completion] = []

    func begin(processID: Int32, maximumDuration: TimeInterval = 0.200) -> Lease? {
        condition.lock()
        defer { condition.unlock() }
        expireLease()
        guard processID > 0, maximumDuration.isFinite, maximumDuration > 0,
              maximumDuration <= 0.250, !blocked, active == nil,
              waitingCallbacks == 0, forwardingCallbacks == 0 else { return nil }
        currentGeneration &+= 1
        let lease = Lease(generation: currentGeneration, processID: processID, fenceID: fenceID)
        active = ActiveLease(lease: lease, startedAt: DispatchTime.now().uptimeNanoseconds,
                             deadline: ProcessInfo.processInfo.systemUptime + maximumDuration)
        return lease
    }

    /// Only the background event-tap callback may wait here, never the AX writer.
    func enterPhysicalEvent(eventTimestamp: UInt64? = nil) -> Admission {
        condition.lock()
        defer { condition.unlock() }
        expireLease()
        let heldGeneration = active?.lease.generation
        if let heldGeneration {
            // Reserve the callback before waiting so a competing begin cannot
            // replace completion metadata before the awakened callback resumes.
            waitingCallbacks += 1
            while let active, active.lease.generation == heldGeneration {
                let remaining = active.deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 {
                    invalidate()
                    break
                }
                _ = condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.005)))
            }
            waitingCallbacks -= 1
        }
        forwardingCallbacks += 1
        let receipt = completions.last { completed in
            guard !blocked else { return false }
            if let heldGeneration {
                return completed.generation == heldGeneration
            }
            guard let eventTimestamp, eventTimestamp > 0 else { return false }
            return eventTimestamp >= completed.startedAt && eventTimestamp <= completed.finishedAt
        }
        return Admission(wasHeld: heldGeneration != nil,
                         needsSourceRefresh: heldGeneration != nil || receipt != nil,
                         replayLayoutID: receipt?.replayLayoutID, interrupted: blocked)
    }

    func leavePhysicalEvent() {
        condition.lock()
        defer { condition.unlock() }
        guard forwardingCallbacks > 0 else {
            invalidate()
            return
        }
        forwardingCallbacks -= 1
    }

    func finish(_ lease: Lease, replayLayoutID: String?) {
        condition.lock()
        defer { condition.unlock() }
        expireLease()
        guard !blocked, let finished = active, finished.lease == lease else { return }
        completions.append(Completion(generation: lease.generation, startedAt: finished.startedAt,
                                      finishedAt: DispatchTime.now().uptimeNanoseconds, replayLayoutID: replayLayoutID))
        if completions.count > 64 { completions.removeFirst(completions.count - 64) }
        active = nil
        condition.broadcast()
    }

    func interrupt() {
        condition.lock()
        defer { condition.unlock() }
        invalidate()
    }

    func isCurrent(_ lease: Lease) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        expireLease()
        return !blocked && active?.lease == lease
    }

    var generation: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        expireLease()
        return currentGeneration
    }

    var isAvailable: Bool {
        condition.lock()
        defer { condition.unlock() }
        expireLease()
        return !blocked
    }

    var hasActiveLease: Bool {
        condition.lock()
        defer { condition.unlock() }
        expireLease()
        return active != nil
    }

    private func expireLease() {
        if let active, ProcessInfo.processInfo.systemUptime >= active.deadline {
            invalidate()
        }
    }

    /// Called with the condition locked. Unknown writes cannot be recovered here.
    private func invalidate() {
        guard !blocked else { return }
        blocked = true
        currentGeneration &+= 1
        active = nil
        completions.removeAll()
        condition.broadcast()
    }
}
