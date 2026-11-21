import Foundation

/// Read-only background check of an edit whose editor applied the queued text
/// after the acknowledgement deadline. It holds no field writer, clipboard or
/// input-source handle: only a whole-field reader and an identity predicate.
@MainActor
final class LateAcknowledgementCheck {
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    /// Delays after the input lease is released.
    static let offsets: [TimeInterval] = [0.300, 0.550, 0.800]

    static let mainQueue: Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }

    struct Probe {
        let expected: NativeFieldObservation
        let read: () -> NativeFieldObservation?
        /// Same PID, exact element, unchanged input revision, record still held.
        let isCurrent: () -> Bool
    }

    private(set) var isFinished = false

    /// Two consecutive reads exactly equal to the expected value and caret.
    static func verify(_ probe: Probe) -> Bool {
        guard probe.isCurrent(), let first = probe.read(), first == probe.expected,
              probe.isCurrent(), let second = probe.read(), second == probe.expected,
              probe.isCurrent() else { return false }
        return true
    }

    func cancel() { isFinished = true }

    func start(_ probe: Probe, schedule: Scheduler, onConfirmed: @escaping @MainActor () -> Void) {
        let last = Self.offsets.last
        for offset in Self.offsets {
            schedule(offset) { [weak self] in
                guard let self, !self.isFinished else { return }
                guard probe.isCurrent() else { self.isFinished = true; return }
                guard Self.verify(probe) else {
                    if offset == last { self.isFinished = true }
                    return
                }
                self.isFinished = true
                onConfirmed()
            }
        }
    }
}
