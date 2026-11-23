import ApplicationServices

/// One offered, never written word for the exact field, caret and input
/// revision where it was verified. RAM only; nothing here is logged.
struct PendingCorrectionHint {
    let proposal: PredictionProposal
    let edit: PredictionSuffixEdit
    let focus: CombinedShiftFocus
    let caretUTF16Location: Int
    let inputRevision: UInt64
    let sessionID: UInt64
    let sourceLayoutID: String
    let resultLayoutID: String
    let sourceLanguage: String
    let issuedAt: UInt64

    /// The visible word: the changed token of the offered suffix.
    var word: String {
        let replaced = edit.replacement.trimmingCharacters(in: .whitespaces)
        return replaced.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? replaced
    }

    /// Equal UTF-16 length is the only collapsed-caret write the verified
    /// editor performs; another length needs a user selection, which a hint
    /// never has (the anchor requires a collapsed caret).
    var writableAtCollapsedCaret: Bool {
        edit.original.utf16.count == edit.replacement.utf16.count
            && edit.replacement.utf16.count <= NativeFieldEditPlan.maximumEditUnits
    }

    func matches(focus other: CombinedShiftFocus, inputRevision revision: UInt64) -> Bool {
        guard revision == inputRevision, other.processID == focus.processID,
              CFEqual(other.element, focus.element),
              let selection = other.initialSelection else { return false }
        return selection.length == 0 && selection.location == caretUTF16Location
    }
}

/// Why a visible hint went away; only the panel and tests observe it.
enum CorrectionHintDismissal: Equatable, Sendable {
    case typing, invalidated, accepted, refused, expired, replaced
}

/// Result of a double Shift that met a visible hint.
enum CorrectionHintAcceptance: Equatable, Sendable {
    case confirmed
    case refused
    case unknown
    case sourceNotConfirmed(targetID: String)
}
