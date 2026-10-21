import Foundation

enum VerifiedNativeFieldEditResult: Equatable {
    case confirmed
    case refused
    /// Last actual whole-field read, never a predicted insertion/result. It may
    /// predate the last queued pair; callers must revalidate before any recovery.
    case uncertain(observation: NativeFieldObservation?)
}

/// Read-only AX and PID-only marked key pairs are supplied by the platform
/// bridge. validateOriginalIdentity must retain the original exact AX element,
/// PID, input revision and secure-input policy, sharing the absolute deadline.
/// post sends exactly one pair and always releases a posted key-down. A true
/// return means queued, never delivered. No AX setter or clipboard is allowed.
@MainActor
struct NativeFieldAccess {
    let validateOriginalIdentity: (_ deadline: TimeInterval) -> Bool
    let cheapGate: () -> Bool
    let isEditable: () -> Bool
    let observe: () -> NativeFieldObservation?
    let post: (NativeFieldEditOperation) -> Bool
    let now: () -> TimeInterval
    let pause: (TimeInterval) -> Void
}

/// Paced acknowledgement protocol, not an AX/DOM atomic transaction. Physical
/// input exclusion belongs to the caller's independent input fence. A same-PID
/// programmatic focus/text change can still race the final check and event.
/// Any unknown state stops further pairs; no replay, alternate writer or rollback.
@MainActor
enum VerifiedNativeFieldEditor {
    static let maximumDuration: TimeInterval = 0.180
    static let maximumObservations = 256
    private static let pollInterval: TimeInterval = 0.001

    static func execute(original: String, replacement: String, start: Int,
                        access: NativeFieldAccess, absoluteDeadline: TimeInterval? = nil,
                        onPrepared: (NativeFieldObservation) -> Void = { _ in }) -> VerifiedNativeFieldEditResult {
        execute(access: access, absoluteDeadline: absoluteDeadline, onPrepared: onPrepared) { snapshot in
            NativeFieldEditPlan.make(original: original, replacement: replacement, start: start, snapshot: snapshot)
        }
    }

    static func executeSelection(original: String, replacement: String, start: Int,
                                 access: NativeFieldAccess, absoluteDeadline: TimeInterval? = nil,
                                 onPrepared: (NativeFieldObservation) -> Void = { _ in }) -> VerifiedNativeFieldEditResult {
        execute(access: access, absoluteDeadline: absoluteDeadline, onPrepared: onPrepared) { snapshot in
            NativeFieldEditPlan.makeSelected(original: original, replacement: replacement, start: start, snapshot: snapshot)
        }
    }

    private static func execute(access: NativeFieldAccess, absoluteDeadline: TimeInterval?,
                                onPrepared: (NativeFieldObservation) -> Void,
                                planFrom: (NativeFieldObservation) -> Result<NativeFieldEditPlan, NativeFieldEditRefusal>)
        -> VerifiedNativeFieldEditResult {
        let started = access.now()
        guard started.isFinite, started >= 0, (started + maximumDuration).isFinite else { return .refused }
        let deadline = absoluteDeadline ?? started + maximumDuration
        guard deadline.isFinite, deadline > started, deadline <= started + maximumDuration else { return .refused }
        var lastTime = started
        var observationCount = 0
        var lastObservation: NativeFieldObservation?

        func cheapCheckpoint() -> Bool {
            let time = access.now()
            guard time.isFinite, time >= lastTime, time < deadline, access.cheapGate() else { return false }
            let afterGate = access.now()
            guard afterGate.isFinite, afterGate >= time, afterGate < deadline else { return false }
            lastTime = afterGate
            return true
        }
        func checkpoint() -> Bool {
            cheapCheckpoint() && access.validateOriginalIdentity(deadline) && cheapCheckpoint()
        }
        func read() -> (value: NativeFieldObservation?, valid: Bool) {
            guard checkpoint(), observationCount < maximumObservations else { return (nil, false) }
            observationCount += 1
            let observed = access.observe()
            if let observed { lastObservation = observed }
            // A valid-looking response cannot authorize a later event if the
            // read finished after the deadline, revision/focus change or fence loss.
            return (observed, checkpoint())
        }
        func pause() -> Bool {
            guard checkpoint(), observationCount < maximumObservations else { return false }
            access.pause(min(pollInterval, max(0, deadline - lastTime)))
            return cheapCheckpoint()
        }
        func awaitAcknowledgement(_ step: NativeFieldEditStep) -> Bool {
            while observationCount < maximumObservations {
                let response = read()
                guard response.valid else { return false }
                if response.value == step.expectedAfter { return true }
                // Only the exact previous state can be an undelivered pair.
                // Wrong caret, noncollapsed selection or another text is a hard stop.
                if let observed = response.value, observed != step.expectedBefore { return false }
                guard pause() else { return false }
            }
            return false
        }
        func uncertaintyAfterFailedPost() -> VerifiedNativeFieldEditResult {
            // False can mean a posted key-down was released after gate loss.
            // If identity/gate still permit a read, retain actual partial delivery.
            _ = read()
            return .uncertain(observation: lastObservation)
        }

        guard checkpoint(), access.isEditable(), checkpoint() else { return .refused }
        let initial = read()
        guard initial.valid, let snapshot = initial.value,
              case .success(let plan) = planFrom(snapshot) else { return .refused }
        onPrepared(plan.originalSnapshot)
        for (index, step) in plan.steps.enumerated() {
            // Re-read the entire fixed field before every pair. In particular,
            // a navigation acknowledgement must precede every Backspace.
            let before = read()
            guard before.valid, before.value == step.expectedBefore, checkpoint() else {
                return index == 0 ? .refused : .uncertain(observation: lastObservation)
            }
            guard access.post(step.operation) else { return uncertaintyAfterFailedPost() }
            guard awaitAcknowledgement(step) else { return .uncertain(observation: lastObservation) }
        }
        return .confirmed
    }
}

/// One down/up pair only. Even gate loss immediately after key-down must release
/// that same key; it cannot authorize another pair.
@MainActor
enum NativeFieldKeyPairPoster {
    static func post(mayContinue: () -> Bool, keyDown: () -> Void, keyUp: () -> Void) -> Bool {
        guard mayContinue() else { return false }
        keyDown()
        let current = mayContinue()
        keyUp()
        return current && mayContinue()
    }
}
