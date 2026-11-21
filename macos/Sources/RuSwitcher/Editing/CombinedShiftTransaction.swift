import Foundation

/// The lease/edit/source sequence shared by the live Shift handler and its
/// headless transaction test. Platform closures own OS observation and delivery.
@MainActor
enum CombinedShiftTransaction {
    struct Platform {
        let currentSourceID: () -> String
        let frontProcessID: () -> Int32?
        let secureInputActive: () -> Bool
        let beginLease: (Int32) -> InputEventFence.Lease?
        let leaseIsCurrent: (InputEventFence.Lease) -> Bool
        let leaseRemaining: (InputEventFence.Lease) -> TimeInterval?
        let finishLease: (InputEventFence.Lease, String?) -> Void
        let pendingSourceTargetID: () -> String?
        let selectSource: (String) -> LayoutSelectionCommit.Outcome
        let noteUnconfirmedSource: (String, UInt64) -> Void
        let observeWholeField: (CombinedShiftFocus) -> NativeFieldObservation?
        let applicationFamily: () -> CombinedShiftApplicationFamily
        /// Timer for the read-only late-acknowledgement check after the lease.
        var lateAcknowledgementScheduler: LateAcknowledgementCheck.Scheduler? = nil
    }

    struct Result {
        let outcome: CombinedShiftCompletion.Outcome?
        let failureNotice: CombinedShiftFailure?
        let pendingSourceTargetID: String?
        let confirmedAutomaticUndo: ConfirmedCorrectionReceipt?
    }

    /// The live handler's entry check: a selected-text gesture in an unlocked
    /// field first gathers local lexicon evidence, before `run` is called.
    /// It writes nothing: `run` records a field lock once for the gesture.
    static func needsSelectionEvidence(execution: CombinedShiftExecutionContext,
                                       converter: TextConverter, convertByText: Bool,
                                       smartConversion: Bool, nativeRUEN: Bool) -> Bool {
        (execution.focus.initialSelection?.length ?? 0) > 0
            && !converter.isFieldLocked(execution.focus)
            && !convertByText && smartConversion && nativeRUEN
    }

    /// An inline autocomplete suggestion is not a user selection: it skips the
    /// selection evidence and goes to the word path after its dismissal.
    static func needsSelectionEvidence(request: CombinedShiftRequest, execution: CombinedShiftExecutionContext,
                                       converter: TextConverter, convertByText: Bool,
                                       smartConversion: Bool, nativeRUEN: Bool,
                                       automaticUndo: DoubleShiftAutomaticUndo) -> Bool {
        !AutocompleteSuggestion.isCandidate(request: request, selection: execution.focus.initialSelection,
            pendingRecovery: converter.hasUnconfirmedAXEdit(in: execution.focus), automaticUndo: automaticUndo)
            && needsSelectionEvidence(execution: execution, converter: converter,
                convertByText: convertByText, smartConversion: smartConversion, nativeRUEN: nativeRUEN)
    }

    static func run(request: CombinedShiftRequest, context: CombinedShiftContext,
                    execution: CombinedShiftExecutionContext, converter: TextConverter,
                    monitor: KeyboardMonitor, platform: Platform, convertWholeLine: Bool,
                    contextForSource: (String) -> CombinedShiftContext?,
                    selectionKnownWord: ((String, String) -> Bool?)? = nil,
                    automaticUndo: DoubleShiftAutomaticUndo = .manual,
                    diagnosticsEnabled: Bool = RuntimeDiagnostics.enabled,
                    onDiagnostic: (CombinedShiftDiagnostic) -> Void = RuntimeDiagnostics.record,
                    onEvent: (RuntimeDiagnosticEvent) -> Void = RuntimeDiagnostics.record) -> Result {
        converter.beginManualTransaction()
        converter.beginDiagnosticGesture()
        defer { converter.endDiagnosticGesture() }
        let pendingRecovery = converter.hasUnconfirmedAXEdit(in: execution.focus)
        let automaticUndoRequested: Bool
        if case .receipt = automaticUndo { automaticUndoRequested = true }
        else { automaticUndoRequested = false }
        // The session flag alone no longer refuses: the exact field decides.
        let flagRaised = { platform.secureInputActive() || AutoSwitchPolicy.secureInputActive }
        let securePermit = SecureFlagFieldPermit(focus: execution.focus, flagRaised: flagRaised)
        let suggestion = AutocompleteSuggestion.isCandidate(request: request,
            selection: execution.focus.initialSelection, pendingRecovery: pendingRecovery,
            automaticUndo: automaticUndo)
        let operation: CombinedShiftDiagnostic.Operation = pendingRecovery ? .recovery
            : suggestion ? .word
            : (execution.focus.initialSelection?.length ?? 0) > 0 ? .selection
            : request.reconvert || automaticUndoRequested ? .undo : .word
        func report(_ result: CombinedShiftDiagnostic.Result) {
            guard diagnosticsEnabled else { return }
            // The family is sampled at the terminal boundary. The caller uses
            // frontmost application metadata, without an AX read for logging.
            let family: CombinedShiftApplicationFamily = flagRaised()
                ? .other : platform.applicationFamily()
            onDiagnostic(.init(application: family,
                operation: operation, result: result))
        }
        func stoppedBeforeEdit() -> Result {
            onEvent(.doubleFailed)
            report(.refused)
            return Result(outcome: .stopped, failureNotice: .noSafeEdit,
                pendingSourceTargetID: platform.pendingSourceTargetID(), confirmedAutomaticUndo: nil)
        }
        // Before any field read: under the raised flag a password, unknown or
        // flag-holder field ends the gesture here, with nothing read or held.
        guard securePermit.allows() else {
            RuntimeDiagnostics.recordFailure(.transactionSecureInput)
            return stoppedBeforeEdit()
        }
        // Selection policy can consult a lexicon. Prepare it after ShiftUp has
        // returned, before holding physical input, then revalidate under lease.
        let preparedSelection: TextConverter.PreparedNativeSelection?
        let sourceBeforePreparation = platform.currentSourceID()
        if (execution.focus.initialSelection?.length ?? 0) > 0,
           !pendingRecovery, !suggestion {
            func stoppedSelection() -> Result { stoppedBeforeEdit() }
            guard sourceBeforePreparation == context.targetLayoutID else {
                RuntimeDiagnostics.recordFailure(.selectionSourceMismatch)
                return stoppedSelection()
            }
            guard let prepared = converter.prepareNativeSelection(context: context,
                      execution: execution, restorePrevious: request.reconvert,
                      observedSourceLayoutID: sourceBeforePreparation,
                      knownWord: selectionKnownWord) else {
                RuntimeDiagnostics.recordFailure(.transactionCandidateUnavailable)
                return stoppedSelection()
            }
            guard execution.isValid() else {
                RuntimeDiagnostics.recordFailure(.transactionInvalidExecution)
                return stoppedSelection()
            }
            guard monitor.inputRevision == execution.inputRevision else {
                RuntimeDiagnostics.recordFailure(.transactionRevisionChanged)
                return stoppedSelection()
            }
            guard platform.frontProcessID() == execution.focus.processID else {
                RuntimeDiagnostics.recordFailure(.transactionWrongProcess)
                return stoppedSelection()
            }
            guard securePermit.allows() else {
                RuntimeDiagnostics.recordFailure(.transactionSecureInput)
                return stoppedSelection()
            }
            guard platform.observeWholeField(execution.focus) == prepared.before else {
                RuntimeDiagnostics.recordFailure(.transactionFieldChanged)
                return stoppedSelection()
            }
            guard platform.currentSourceID() == sourceBeforePreparation else {
                RuntimeDiagnostics.recordFailure(.transactionSourceChanged)
                return stoppedSelection()
            }
            preparedSelection = prepared
        } else {
            preparedSelection = nil
        }
        guard let lease = platform.beginLease(execution.focus.processID) else {
            // Its own counter; not a failed edit attempt.
            onEvent(.nativeFenceUnavailable)
            report(.refused)
            return Result(outcome: nil, failureNotice: nil,
                pendingSourceTargetID: platform.pendingSourceTargetID(), confirmedAutomaticUndo: nil)
        }
        let needsAutomaticSource = { () -> Bool in
            if case .receipt = automaticUndo { return true }
            return false
        }()
        let isCurrent = {
            platform.leaseIsCurrent(lease)
                && monitor.inputRevision == execution.inputRevision
                && platform.frontProcessID() == execution.focus.processID
                && securePermit.allows()
                && (preparedSelection == nil || platform.currentSourceID() == sourceBeforePreparation)
                && (!needsAutomaticSource || platform.currentSourceID() == context.targetLayoutID)
        }
        var requestedAt: UInt64 = 0
        let sourceCommit = NativeQueuedSourceCommit(isCurrent: isCurrent, request: { target in
            requestedAt = DispatchTime.now().uptimeNanoseconds
            return platform.selectSource(target)
        }, onUnconfirmed: { target in
            platform.noteUnconfirmedSource(target, requestedAt)
        })
        var dismissedExecution: CombinedShiftExecutionContext?
        if suggestion {
            // Caret-only move under the lease; no text is written here.
            switch converter.dismissAutocompleteSuggestion(execution: execution,
                                                           inputBarrierIsActive: isCurrent) {
            case .dismissed(let collapsed):
                dismissedExecution = collapsed
            case .refused:
                onEvent(.autocompleteSuggestionRefused)
                platform.finishLease(lease, nil)
                return stoppedBeforeEdit()
            }
        }
        let editExecution = dismissedExecution ?? execution
        var failureNotice: CombinedShiftFailure?
        var editDiagnostic: CombinedShiftDiagnostic?
        let succeeded = converter.withNativeInputBudget({ platform.leaseRemaining(lease) }) {
            converter.withNativeTextQueuedHandler({ _ in
                // Queued Unicode alone cannot authorize a source selection.
            }) {
                CombinedShiftEditing.perform(request: request, context: context,
                    execution: editExecution, converter: converter,
                    inputBarrierIsActive: isCurrent, convertWholeLine: convertWholeLine,
                    contextForSource: contextForSource,
                    onFailure: { failureNotice = $0 },
                    onDiagnostic: { editDiagnostic = $0 },
                    application: .other,
                    preparedSelection: preparedSelection,
                    fallbackSourceIsCurrent: {
                        platform.currentSourceID() == context.targetLayoutID && isCurrent()
                    }, automaticUndo: automaticUndo)
            }
        }
        let outcome = CombinedShiftCompletion.finish(succeeded: succeeded, request: request,
            context: context, sourceCommit: sourceCommit, converter: converter,
            monitor: monitor, isInputCurrent: isCurrent, record: onEvent)
        let diagnosticResult: CombinedShiftDiagnostic.Result
        switch outcome {
        case .confirmed: diagnosticResult = .confirmed
        case .sourceNotConfirmed: diagnosticResult = .sourceUnconfirmed
        case .stopped: diagnosticResult = editDiagnostic?.result ?? .refused
        }
        if case .confirmed = outcome, case .receipt(let receipt) = automaticUndo {
            converter.armManualRedoAfterConfirmedAutomaticUndo(receipt)
        }
        platform.finishLease(lease, sourceCommit.confirmedLayoutID)
        if case .stopped = outcome {
            // Only reads the field; a confirmed late result arms the ordinary repeat.
            // Any later Shift press cancels it: its first tap revises no input.
            let shiftPresses = monitor.combinedShiftPressCount
            converter.scheduleLateAcknowledgement(execution: editExecution,
                read: { platform.observeWholeField(editExecution.focus) },
                schedule: platform.lateAcknowledgementScheduler ?? LateAcknowledgementCheck.mainQueue,
                newGestureStarted: { monitor.combinedShiftPressCount != shiftPresses }) {
                    monitor.markConverted()
                }
        }
        report(diagnosticResult)
        let confirmedAutomaticUndo: ConfirmedCorrectionReceipt?
        if case .confirmed = outcome, case .receipt(let receipt) = automaticUndo {
            confirmedAutomaticUndo = receipt
        } else {
            confirmedAutomaticUndo = nil
        }
        return Result(outcome: outcome, failureNotice: failureNotice,
            pendingSourceTargetID: nil, confirmedAutomaticUndo: confirmedAutomaticUndo)
    }
}
