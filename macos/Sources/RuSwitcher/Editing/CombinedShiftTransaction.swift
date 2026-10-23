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
    }

    struct Result {
        let outcome: CombinedShiftCompletion.Outcome?
        let failureNotice: CombinedShiftFailure?
        let pendingSourceTargetID: String?
        let confirmedAutomaticUndo: ConfirmedCorrectionReceipt?
    }

    static func run(request: CombinedShiftRequest, context: CombinedShiftContext,
                    execution: CombinedShiftExecutionContext, converter: TextConverter,
                    monitor: KeyboardMonitor, platform: Platform, convertWholeLine: Bool,
                    contextForSource: (String) -> CombinedShiftContext?,
                    selectionKnownWord: ((String, String) -> Bool?)? = nil,
                    automaticUndo: DoubleShiftAutomaticUndo = .manual) -> Result {
        converter.beginManualTransaction()
        // Selection policy can consult a lexicon. Prepare it after ShiftUp has
        // returned, before holding physical input, then revalidate under lease.
        let preparedSelection: TextConverter.PreparedNativeSelection?
        let sourceBeforePreparation = platform.currentSourceID()
        if (execution.focus.initialSelection?.length ?? 0) > 0,
           !converter.hasUnconfirmedAXEdit(in: execution.focus) {
            guard sourceBeforePreparation == context.targetLayoutID,
                  let prepared = converter.prepareNativeSelection(context: context,
                      execution: execution, restorePrevious: request.reconvert,
                      observedSourceLayoutID: sourceBeforePreparation,
                      knownWord: selectionKnownWord),
                  execution.isValid(),
                  monitor.inputRevision == execution.inputRevision,
                  platform.frontProcessID() == execution.focus.processID,
                  !platform.secureInputActive(),
                  platform.observeWholeField(execution.focus) == prepared.before,
                  platform.currentSourceID() == sourceBeforePreparation else {
                RuntimeDiagnostics.record(.selectionSnapshotUnavailable)
                return Result(outcome: .stopped, failureNotice: .noSafeEdit,
                    pendingSourceTargetID: platform.pendingSourceTargetID(), confirmedAutomaticUndo: nil)
            }
            preparedSelection = prepared
        } else {
            preparedSelection = nil
        }
        guard let lease = platform.beginLease(execution.focus.processID) else {
            RuntimeDiagnostics.record(.nativeFenceUnavailable)
            RuntimeDiagnostics.record(.doubleFailed)
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
                && !platform.secureInputActive()
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
        var failureNotice: CombinedShiftFailure?
        let succeeded = converter.withNativeInputBudget({ platform.leaseRemaining(lease) }) {
            converter.withNativeTextQueuedHandler({ _ in
                // Queued Unicode alone cannot authorize a source selection.
            }) {
                CombinedShiftEditing.perform(request: request, context: context,
                    execution: execution, converter: converter,
                    inputBarrierIsActive: isCurrent, convertWholeLine: convertWholeLine,
                    contextForSource: contextForSource,
                    onFailure: { failureNotice = $0 },
                    onDiagnostic: { RuntimeDiagnostics.record($0) },
                    application: platform.applicationFamily(),
                    preparedSelection: preparedSelection,
                    fallbackSourceIsCurrent: {
                        platform.currentSourceID() == context.targetLayoutID && isCurrent()
                    }, automaticUndo: automaticUndo)
            }
        }
        let outcome = CombinedShiftCompletion.finish(succeeded: succeeded, request: request,
            context: context, sourceCommit: sourceCommit, converter: converter,
            monitor: monitor, isInputCurrent: isCurrent)
        if case .confirmed = outcome, case .receipt(let receipt) = automaticUndo {
            converter.armManualRedoAfterConfirmedAutomaticUndo(receipt)
        }
        platform.finishLease(lease, sourceCommit.confirmedLayoutID)
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
