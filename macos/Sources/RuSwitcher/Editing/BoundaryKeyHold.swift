import Foundation

/// Keeps one physical Enter/Tab on the tap thread while main corrects the
/// word typed before it. The event itself is never stored, copied or posted:
/// the tap callback simply returns it later, exactly once. Without a write in
/// progress the key goes after at most `maximumHold`; a write already under
/// its input lease is waited for, so the key never lands inside an edit.
final class BoundaryKeyHold: @unchecked Sendable {
    struct Ticket: Equatable, Sendable { fileprivate let id: UInt64 }
    enum Outcome: Equatable, Sendable { case completed, timedOut }

    /// Owner's decision of 22.11: a short delay, at most 150 ms.
    static let maximumHold: TimeInterval = 0.150
    /// A write that began inside the window ends under its own lease (≤250 ms).
    static let writeCap: TimeInterval = 0.300

    private enum State { case deciding, writing, done }
    private let condition = NSCondition()
    private var nextID: UInt64 = 0
    private var current: (ticket: Ticket, state: State)?

    /// Main: one hold at a time; a newer key retires an older one.
    func arm() -> Ticket {
        condition.lock(); defer { condition.unlock() }
        nextID &+= 1
        let ticket = Ticket(id: nextID)
        current = (ticket, .deciding)
        condition.broadcast()
        return ticket
    }

    /// Main: a write may start only while the key is still held and undecided.
    func beginWrite(_ ticket: Ticket) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard let current, current.ticket == ticket, current.state == .deciding else { return false }
        self.current = (ticket, .writing)
        return true
    }

    /// Main: correction finished, refused or never started.
    func complete(_ ticket: Ticket) {
        condition.lock(); defer { condition.unlock() }
        guard let current, current.ticket == ticket else { return }
        self.current = (ticket, .done)
        condition.broadcast()
    }

    func isFinished(_ ticket: Ticket) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard let current, current.ticket == ticket else { return true }
        return current.state == .done
    }

    /// Tap thread only. On timeout an undecided hold is closed, so no write
    /// can begin after the key has gone.
    func wait(_ ticket: Ticket, timeout: TimeInterval = maximumHold,
              writeCap: TimeInterval = writeCap) -> Outcome {
        condition.lock(); defer { condition.unlock() }
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            guard let current, current.ticket == ticket else { return .completed }
            if current.state == .done { return .completed }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let limit = current.state == .writing ? writeCap : timeout
            if elapsed >= limit {
                if current.state == .deciding { self.current = (ticket, .done) }
                return .timedOut
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(limit - elapsed, 0.005)))
        }
    }

    /// Tap thread: wait for the decision, then pass the physical fence once
    /// more (it holds every key while a lease is active) and return the
    /// original value. The caller has already left the fence for this event.
    func forward<T>(_ value: T, ticket: Ticket, fence: InputEventFence,
                    eventTimestamp: UInt64?, timeout: TimeInterval = maximumHold) -> (value: T, outcome: Outcome) {
        let outcome = wait(ticket, timeout: timeout)
        let admission = fence.enterPhysicalEvent(eventTimestamp: eventTimestamp)
        fence.leavePhysicalEvent(admission, wasForwarded: true)
        return (value, outcome)
    }
}
