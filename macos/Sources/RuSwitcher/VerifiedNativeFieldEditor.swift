import Foundation

enum VerifiedNativeFieldEditResult: Equatable {
    case confirmed
    /// No text replacement was queued. Preparation/cancellation navigation may
    /// have been queued; this does not assert delivery of those non-text events.
    case refused
    /// No Unicode was queued, but preparation/cancellation navigation has no
    /// exact acknowledgement. A future attempt must capture a fresh field state.
    case preparationUncertain(observation: NativeFieldObservation?)
    /// Last actual whole-field read, never a predicted insertion/result. It may
    /// predate queued Unicode; callers must revalidate before any recovery.
    case uncertain(observation: NativeFieldObservation?)
}

/// Read-only AX and PID-only marked key pairs are supplied by the platform
/// bridge. validateOriginalIdentity must retain the original exact AX element,
/// PID, input revision and secure-input policy, sharing the absolute deadline.
/// postBatch admits one complete prepared fixed-PID phase. False means no
/// event was posted; true means all phase pairs were queued, never delivered.
/// Once admitted a phase cannot abort between pairs. No AX setter or clipboard.
@MainActor
struct NativeFieldAccess {
    let validateOriginalIdentity: (_ deadline: TimeInterval) -> Bool
    let cheapGate: () -> Bool
    let isEditable: (_ deadline: TimeInterval) -> Bool
    let observe: (_ deadline: TimeInterval) -> NativeFieldObservation?
    let postBatch: ([NativeFieldEditOperation]) -> Bool
    let cancelPreparedSelection: ((_ deadline: TimeInterval) -> Bool)?
    let now: () -> TimeInterval
    let pause: (TimeInterval) -> Void
    /// Closed-vocabulary sinks; nil uses the opt-in process logger.
    let recordFailure: ((RuntimeDiagnosticFailureReason) -> Void)?
    let recordEvent: ((RuntimeDiagnosticEvent) -> Void)?

    init(validateOriginalIdentity: @escaping (TimeInterval) -> Bool,
         cheapGate: @escaping () -> Bool, isEditable: @escaping (TimeInterval) -> Bool,
         observe: @escaping (TimeInterval) -> NativeFieldObservation?,
         postBatch: @escaping ([NativeFieldEditOperation]) -> Bool,
         cancelPreparedSelection: ((TimeInterval) -> Bool)? = nil,
         now: @escaping () -> TimeInterval, pause: @escaping (TimeInterval) -> Void,
         recordFailure: ((RuntimeDiagnosticFailureReason) -> Void)? = nil,
         recordEvent: ((RuntimeDiagnosticEvent) -> Void)? = nil) {
        self.recordFailure = recordFailure
        self.recordEvent = recordEvent
        self.validateOriginalIdentity = validateOriginalIdentity
        self.cheapGate = cheapGate
        self.isEditable = isEditable
        self.observe = observe
        self.postBatch = postBatch
        self.cancelPreparedSelection = cancelPreparedSelection
        self.now = now
        self.pause = pause
    }
}

/// Two bounded phases: select without changing text, verify that exact field,
/// then queue one text replacement with an exact whole-field acknowledgement.
/// Physical input exclusion belongs to the caller's independent input fence.
/// This is not an AX/DOM transaction: programmatic changes can still race the
/// final admission. Unknown delivery never authorizes replay or another writer.
@MainActor
enum VerifiedNativeFieldEditor {
    static let maximumDuration: TimeInterval = 0.180
    static let maximumObservations = 256
    static let maximumPreparationDuration: TimeInterval = 0.110
    private static let pollInterval: TimeInterval = 0.001

    static func execute(original: String, replacement: String, start: Int,
                        access: NativeFieldAccess, absoluteDeadline: TimeInterval? = nil,
                        onPrepared: (NativeFieldObservation) -> Void = { _ in },
                        onTextQueued: () -> Void = {},
                        formattedStart: Int? = nil,
                        resolvedFormattedStart: (() -> Int?)? = nil) -> VerifiedNativeFieldEditResult {
        execute(access: access, absoluteDeadline: absoluteDeadline, onPrepared: onPrepared,
                onTextQueued: onTextQueued) { snapshot in
            NativeFieldEditPlan.make(original: original, replacement: replacement,
                start: start, snapshot: snapshot,
                formattedStart: resolvedFormattedStart?() ?? formattedStart)
        }
    }

    static func executeSelection(original: String, replacement: String, start: Int,
                                 access: NativeFieldAccess, absoluteDeadline: TimeInterval? = nil,
                                 onPrepared: (NativeFieldObservation) -> Void = { _ in },
                                 onTextQueued: () -> Void = {},
                                 formattedStart: Int? = nil) -> VerifiedNativeFieldEditResult {
        execute(access: access, absoluteDeadline: absoluteDeadline, onPrepared: onPrepared,
                onTextQueued: onTextQueued) { snapshot in
            NativeFieldEditPlan.makeSelected(original: original, replacement: replacement,
                start: start, snapshot: snapshot, formattedStart: formattedStart)
        }
    }

    private static func execute(access: NativeFieldAccess, absoluteDeadline: TimeInterval?,
                                onPrepared: (NativeFieldObservation) -> Void,
                                onTextQueued: () -> Void,
                                planFrom: (NativeFieldObservation) -> Result<NativeFieldEditPlan, NativeFieldEditRefusal>)
        -> VerifiedNativeFieldEditResult {
        // Every refusal names its stage once; no field text enters the code.
        func refuse(_ reason: RuntimeDiagnosticFailureReason) -> VerifiedNativeFieldEditResult {
            if let sink = access.recordFailure { sink(reason) } else { RuntimeDiagnostics.recordFailure(reason) }
            return .refused
        }
        func record(_ event: RuntimeDiagnosticEvent) {
            if let sink = access.recordEvent { sink(event) } else { RuntimeDiagnostics.record(event) }
        }
        let started = access.now()
        guard started.isFinite, started >= 0, (started + maximumDuration).isFinite else { return refuse(.editorClockInvalid) }
        let deadline = absoluteDeadline ?? started + maximumDuration
        guard deadline.isFinite, deadline > started, deadline <= started + maximumDuration else {
            return refuse(.editorClockInvalid)
        }
        let preparationDeadline = min(started + maximumPreparationDuration,
                                      started + max((deadline - started) * 0.4,
                                                    (deadline - started) - 0.070))
        var lastTime = started
        var observationCount = 0
        var lastObservation: NativeFieldObservation?
        var lastValidatedObservation: NativeFieldObservation?

        func cheapCheckpoint(until limit: TimeInterval) -> Bool {
            let time = access.now()
            guard time.isFinite, time >= lastTime, time < limit, access.cheapGate() else { return false }
            let afterGate = access.now()
            guard afterGate.isFinite, afterGate >= time, afterGate < limit else { return false }
            lastTime = afterGate
            return true
        }
        func checkpoint(until limit: TimeInterval) -> Bool {
            cheapCheckpoint(until: limit) && access.validateOriginalIdentity(limit)
                && cheapCheckpoint(until: limit)
        }
        func read(until limit: TimeInterval) -> (value: NativeFieldObservation?, valid: Bool) {
            guard cheapCheckpoint(until: limit), observationCount < maximumObservations else { return (nil, false) }
            observationCount += 1
            let observed = access.observe(limit)
            if let observed { lastObservation = observed }
            let valid = checkpoint(until: limit)
            lastValidatedObservation = valid ? observed : nil
            return (observed, valid)
        }
        /// Text-free comparison of the last whole-field read at the ACK deadline.
        func deadlineSubcode(expected: NativeFieldObservation,
                             source: NativeFieldObservation) -> RuntimeDiagnosticEvent {
            guard let last = lastObservation else { return .ackDeadlineOther }
            if last.text.utf16.elementsEqual(source.text.utf16) { return .ackDeadlineSourceVisible }
            if last.text.utf16.elementsEqual(expected.text.utf16) { return .ackDeadlineCaretOnly }
            return .ackDeadlineOther
        }
        func awaitExact(_ expected: NativeFieldObservation, until limit: TimeInterval,
                        diagnoseFailure: Bool = false,
                        source: NativeFieldObservation? = nil) -> Bool {
            var lastObservationFailure: RuntimeDiagnosticEvent?
            func failed(_ reason: RuntimeDiagnosticEvent) -> Bool {
                if diagnoseFailure {
                    record(reason)
                    if reason == .ackDeadline, let source { record(deadlineSubcode(expected: expected, source: source)) }
                    if let lastObservationFailure { record(lastObservationFailure) }
                }
                return false
            }
            func deadlineOrGate() -> RuntimeDiagnosticEvent {
                access.now() >= limit ? .ackDeadline : .ackGateInvalid
            }
            while observationCount < maximumObservations {
                let response = read(until: limit)
                guard response.valid else { return failed(deadlineOrGate()) }
                if response.value == expected { return true }
                if diagnoseFailure {
                    if let observed = response.value {
                        if !observed.text.utf16.elementsEqual(expected.text.utf16) {
                            lastObservationFailure = .ackTextMismatch
                        } else if observed.caretUTF16Location != expected.caretUTF16Location {
                            lastObservationFailure = .ackCaretMismatch
                        } else {
                            lastObservationFailure = .ackSelectionMismatch
                        }
                    } else {
                        lastObservationFailure = .ackObservationUnavailable
                    }
                }
                // AX text and selection can temporarily describe different
                // moments. Waiting never authorizes a new write on its own.
                guard cheapCheckpoint(until: limit) else { return failed(deadlineOrGate()) }
                guard observationCount < maximumObservations else { return failed(.ackObservationLimit) }
                access.pause(min(pollInterval, max(0, limit - lastTime)))
            }
            return failed(.ackObservationLimit)
        }

        guard checkpoint(until: deadline) else { return refuse(.editorIdentityLost) }
        guard access.isEditable(deadline) else { return refuse(.editorFieldNotEditable) }
        guard cheapCheckpoint(until: deadline) else { return refuse(.editorIdentityLost) }
        let initial = read(until: deadline)
        guard initial.valid, let snapshot = initial.value else { return refuse(.editorFirstReadInvalid) }
        guard case .success(let plan) = planFrom(snapshot) else { return refuse(.editorPlanRefused) }
        onPrepared(plan.originalSnapshot)
        let hasPreparation = !plan.preparationOperations.isEmpty
        let admissionDeadline = hasPreparation ? preparationDeadline : deadline

        func cancelPreparation(_ reason: RuntimeDiagnosticFailureReason = .editorPreparationCancelled)
            -> VerifiedNativeFieldEditResult {
            // No text has been queued. Cleanup is preallocated non-text
            // navigation to the captured PID, under the remaining fence budget.
            // Never post it after losing exact-field identity. Refused means no
            // text queued, not proven delivery of navigation.
            if let current = lastValidatedObservation,
               current.caretUTF16Location == 0, current.selectionLength == 0 {
                // Shift+Left cannot move left at zero; a following Right would
                // move a programmatically collapsed caret forward. Preserve it.
                return .preparationUncertain(observation: lastObservation)
            }
            guard checkpoint(until: deadline) else {
                return .preparationUncertain(observation: lastObservation)
            }
            guard let cancel = access.cancelPreparedSelection, cancel(deadline) else {
                return .preparationUncertain(observation: lastObservation)
            }
            return awaitExact(plan.originalSnapshot, until: deadline)
                ? refuse(reason) : .preparationUncertain(observation: lastObservation)
        }

        guard cheapCheckpoint(until: admissionDeadline) else { return refuse(.editorIdentityLost) }
        guard access.isEditable(admissionDeadline) else { return refuse(.editorFieldNotEditable) }
        guard cheapCheckpoint(until: admissionDeadline) else { return refuse(.editorIdentityLost) }
        let before = read(until: admissionDeadline)
        guard before.valid else { return refuse(.editorIdentityLost) }
        guard before.value == plan.originalSnapshot else { return refuse(.editorFieldChanged) }
        guard cheapCheckpoint(until: admissionDeadline) else { return refuse(.editorIdentityLost) }

        if hasPreparation {
            guard access.postBatch(plan.preparationOperations) else { return refuse(.editorPreparationNotQueued) }
            guard awaitExact(plan.preparedSnapshot, until: preparationDeadline) else { return cancelPreparation() }
            // A programmatic A→B switch during selection must be caught before
            // any Unicode is sent. The full selected original is checked again.
            guard cheapCheckpoint(until: admissionDeadline), access.isEditable(admissionDeadline),
                  cheapCheckpoint(until: admissionDeadline) else { return cancelPreparation() }
            let prepared = read(until: admissionDeadline)
            guard prepared.valid, prepared.value == plan.preparedSnapshot,
                  cheapCheckpoint(until: admissionDeadline) else { return cancelPreparation() }
        }
        guard access.postBatch(plan.replacementOperations) else {
            return hasPreparation ? cancelPreparation(.editorReplacementNotQueued)
                : refuse(.editorReplacementNotQueued)
        }
        // This receipt is about data queued, never observed delivery. Callers
        // must wait for the exact result before selecting a new input source.
        onTextQueued()
        return awaitExact(plan.resultSnapshot, until: deadline,
            diagnoseFailure: RuntimeDiagnostics.enabled || access.recordEvent != nil,
            source: plan.originalSnapshot)
            ? .confirmed : .uncertain(observation: lastObservation)
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


/// Admission is checked exactly once before the first event. Every prepared
/// down/up is then queued even if the deadline or gate changes mid-batch. This
/// closes the former "partially deleted word" path; delivery is still separate.
@MainActor
enum NativeFieldBatchPoster {
    static let maximumEvents = 54

    static func post(eventCount: Int, mayBegin: () -> Bool, postEvent: (Int) -> Void) -> Bool {
        guard eventCount > 0, eventCount <= maximumEvents,
              eventCount.isMultiple(of: 2), mayBegin() else { return false }
        for index in 0..<eventCount { postEvent(index) }
        return true
    }
}
