import Foundation

/// Retry only an unavailable AX focus read, retaining the caller's existing
/// absolute deadline and unchanged identity/revision validation. This helper
/// never writes text, moves a selection, or authorizes another transport.
@MainActor
enum NativeFocusRevalidation {
    static func validate(until deadline: TimeInterval, now: () -> TimeInterval,
                         mayContinue: () -> Bool,
                         read: () -> CombinedShiftExecutionFailure?,
                         pause: (TimeInterval) -> Void) -> Bool {
        guard deadline.isFinite, deadline > 0 else { return false }
        var lastTime: TimeInterval = 0

        func checkpoint() -> Bool {
            let time = now()
            guard time.isFinite, time >= lastTime, time < deadline,
                  mayContinue() else { return false }
            let afterGate = now()
            guard afterGate.isFinite, afterGate >= time,
                  afterGate < deadline else { return false }
            lastTime = afterGate
            return true
        }

        // The cap also bounds execution if an injected clock or pause stops
        // advancing. Production supplies the transaction's monotonic clock.
        for attempt in 0..<100 {
            guard checkpoint() else { return false }
            let failure = read()
            // A successful response is stale if it finished after the budget,
            // after gate loss, or after the clock moved backwards.
            guard checkpoint() else { return false }
            switch failure {
            case nil:
                return true
            case .focusUnavailable?:
                guard attempt < 99 else { return false }
                pause(min(0.001, deadline - lastTime))
            default:
                return false
            }
        }
        return false
    }
}
