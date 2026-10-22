/// Flags source re-reads; it never chooses a historical layout for an event.
struct InputSourceTransitionTracker: Sendable {
    private struct Pending: Sendable {
        let targetID: String
        let startedAt: UInt64
    }

    private var pending: Pending?
    private var completedWindows: [ClosedRange<UInt64>] = []

    var hasPending: Bool { pending != nil }
    var pendingTargetID: String? { pending?.targetID }

    /// A confirmed text edit can still have an unverified source, even when
    /// the TIS request was refused. Only a later actual target observation
    /// resolves this gate; time and requested values do not.
    mutating func requireObserved(targetID: String, startingAt: UInt64) {
        noteUnconfirmed(targetID: targetID, startingAt: startingAt)
    }

    mutating func noteUnconfirmed(targetID: String, startingAt: UInt64) {
        guard !targetID.isEmpty, startingAt > 0 else { return }
        pending = Pending(targetID: targetID, startedAt: min(pending?.startedAt ?? startingAt, startingAt))
    }

    mutating func observe(sourceID: String, at timestamp: UInt64) {
        guard !sourceID.isEmpty, let pending, sourceID == pending.targetID,
              timestamp >= pending.startedAt else { return }
        recordCompletedWindow(start: pending.startedAt, end: timestamp)
        self.pending = nil
    }

    /// Retains at most 64 controlled intervals, including completed fence leases.
    mutating func recordCompletedWindow(start: UInt64, end: UInt64) {
        guard start > 0, end >= start else { return }
        completedWindows.append(start...end)
        if completedWindows.count > 64 {
            completedWindows.removeFirst(completedWindows.count - 64)
        }
    }

    func needsRefresh(eventTimestamp: UInt64) -> Bool {
        // An unresolved source requires an actual read even for a missing clock.
        if hasPending { return true }
        guard eventTimestamp > 0 else { return false }
        return completedWindows.contains { $0.contains(eventTimestamp) }
    }
}
