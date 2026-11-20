import Foundation

/// The production completion decision after the text edit and source request.
/// Keeping this separate from AppDelegate lets headless tests exercise the
/// exact source-failure branch without a status item or user window.
@MainActor
enum CombinedShiftCompletion {
    enum Outcome: Equatable {
        case stopped
        case sourceNotConfirmed(targetID: String, sourceOutcome: LayoutSelectionCommit.Outcome?)
        case confirmed(resultID: String)
    }

    static func finish(succeeded: Bool, request: CombinedShiftRequest,
                       context: CombinedShiftContext, sourceCommit: NativeQueuedSourceCommit,
                       converter: TextConverter, monitor: KeyboardMonitor,
                       isInputCurrent: () -> Bool,
                       record: (RuntimeDiagnosticEvent) -> Void = RuntimeDiagnostics.record) -> Outcome {
        guard succeeded else {
            record(.doubleFailed)
            return .stopped
        }
        let resultID = converter.lastResultLayoutID ?? context.targetLayoutID
        if isInputCurrent(), sourceCommit.targetLayoutID == nil {
            sourceCommit.textQueued(targetID: resultID)
        }
        guard sourceCommit.confirmedLayoutID == resultID, isInputCurrent() else {
            // Text is confirmed. Retire the old typed-word buffer and arm undo,
            // but do not adopt a requested source or clear pending uncertainty.
            monitor.markConverted()
            monitor.requireObservedInputSource(resultID)
            // The text is fixed; only the layout switch lacks confirmation.
            record(.doubleLayoutUnconfirmed)
            return .sourceNotConfirmed(targetID: resultID, sourceOutcome: sourceCommit.outcome)
        }
        record(.doubleSucceeded)
        if let field = converter.confirmedNativeField, let focus = request.focus,
           field.focus.processID == focus.processID,
           CFEqual(field.focus.element, focus.element) {
            monitor.adoptConfirmedManualField(field, resultLayoutID: resultID)
        } else {
            monitor.markConverted()
        }
        return .confirmed(resultID: resultID)
    }
}
