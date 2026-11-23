import ApplicationServices

/// Inline autocompletion (Spotlight, browser address bars): a selected tail
/// that begins exactly at the caret right after the typed word and runs to
/// the end of the field. It is never converted. To correct the word before
/// it, the caret is moved to the start of the selection — a selection change,
/// never a text write — and the field must then show the word alone with a
/// collapsed caret. Anything else refuses with `autocompleteSuggestionRefused`.
enum AutocompleteSuggestion {
    enum Verification: Equatable { case dismissed, tailRetained, changed }

    /// Only the open typed word qualifies: any user selection action (mouse,
    /// arrows, modifier shortcuts) has already cleared the typed buffer.
    static func isCandidate(request: CombinedShiftRequest, selection: CFRange?,
                            pendingRecovery: Bool, automaticUndo: DoubleShiftAutomaticUndo) -> Bool {
        guard case .manual = automaticUndo, !pendingRecovery, !request.reconvert,
              !request.wordKeys.isEmpty, let selection, selection.length > 0 else { return false }
        return selection.location >= request.wordKeys.count
    }

    static func isSuggestion(_ field: NativeFieldObservation, selection: CFRange) -> Bool {
        let count = field.text.utf16.count
        return selection.location > 0 && selection.length > 0
            && field.caretUTF16Location == selection.location
            && field.selectionLength == selection.length
            && selection.location <= count - selection.length
            && selection.location + selection.length == count
    }

    /// The text before the caret must be exactly the text before the
    /// suggestion; the suggestion itself must be gone and the caret collapsed.
    static func verify(before: NativeFieldObservation, after: NativeFieldObservation?,
                       caret: Int) -> Verification {
        guard let after, after.caretUTF16Location == caret, after.selectionLength == 0 else { return .changed }
        let units = Array(before.text.utf16)
        guard caret >= 0, caret <= units.count else { return .changed }
        let prefix = String(decoding: units[..<caret], as: UTF16.self)
        if after.text.utf16.elementsEqual(prefix.utf16) { return .dismissed }
        if after.text.utf16.elementsEqual(before.text.utf16) { return .tailRetained }
        return .changed
    }
}

enum AutocompleteDismissal {
    case dismissed(CombinedShiftExecutionContext)
    case refused
}

@MainActor
extension TextConverter {
    /// Runs under the caller's input lease. Reads the bounded whole field
    /// (secure fields are refused by `allowsTextRead`), moves only the caret,
    /// verifies, and restores the original selection if the tail stayed as text.
    func dismissAutocompleteSuggestion(execution: CombinedShiftExecutionContext,
                                       inputBarrierIsActive: () -> Bool) -> AutocompleteDismissal {
        let focus = execution.focus
        guard let initial = focus.initialSelection, initial.length > 0,
              inputBarrierIsActive(), execution.isValid(),
              let before = wholeFieldObservation(focus: focus),
              AutocompleteSuggestion.isSuggestion(before, selection: initial),
              inputBarrierIsActive(), execution.isValid() else { return .refused }
        _ = focus.select(range: CFRange(location: initial.location, length: 0))
        let after = wholeFieldObservation(focus: focus)
        switch AutocompleteSuggestion.verify(before: before, after: after, caret: initial.location) {
        case .dismissed:
            guard let after, inputBarrierIsActive(), execution.isValid() else { return .refused }
            return .dismissed(CombinedShiftExecutionContext(
                focus: focus.collapsed(at: initial.location, fieldText: after.text),
                inputRevision: execution.inputRevision,
                currentInputRevision: execution.currentInputRevision))
        case .tailRetained:
            if inputBarrierIsActive() { _ = focus.select(range: initial) }
            return .refused
        case .changed:
            return .refused
        }
    }
}
