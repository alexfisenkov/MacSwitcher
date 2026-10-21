import Foundation

/// A text replacement and its keyboard-source change are separate commits.
/// No prediction state may adopt the requested source until it is observed.
enum LayoutSelectionCommit {
    enum Outcome: Equatable { case confirmed, refused, unconfirmed }
    static let maximumDuration: TimeInterval = 0.020

    static func select(targetID: String, currentID: () -> String, request: () -> Bool,
                       now: () -> TimeInterval, pause: (TimeInterval) -> Void) -> Bool {
        requestAndObserve(targetID: targetID, currentID: currentID, request: request,
            now: now, pause: pause) == .confirmed
    }

    static func requestAndObserve(targetID: String, currentID: () -> String, request: () -> Bool,
                       now: () -> TimeInterval, pause: (TimeInterval) -> Void) -> Outcome {
        guard !targetID.isEmpty else { return .refused }
        let started = now()
        guard started.isFinite, started >= 0 else { return .refused }
        let deadline = started + maximumDuration
        var lastTime = started
        func inBudget() -> Bool {
            let time = now()
            guard time.isFinite, time >= lastTime, time < deadline else { return false }
            lastTime = time
            return true
        }
        let initial = currentID()
        guard inBudget() else { return .refused }
        if initial == targetID { return .confirmed }
        guard request() else { return .refused }
        guard inBudget() else { return .unconfirmed }
        for _ in 0..<40 {
            let observed = currentID()
            guard inBudget() else { return .unconfirmed }
            if observed == targetID { return .confirmed }
            pause(min(0.0005, deadline - lastTime))
        }
        return .unconfirmed
    }
}
