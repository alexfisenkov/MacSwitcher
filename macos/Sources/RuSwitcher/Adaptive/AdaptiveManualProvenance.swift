import AppKit

/// A manual undo may withdraw only the exact preceding manual word choice in
/// the same field. Automatic undo/redo and unrelated edits invalidate this link.
@MainActor
struct AdaptiveManualProvenance {
    private struct Occurrence {
        let id: UUID
        let pair: AdaptiveWordPair
        let preferred: String
        let focus: CombinedShiftFocus
    }
    private var occurrence: Occurrence?

    mutating func invalidate() { occurrence = nil }

    mutating func confirmed(original: String, replacement: String,
                            focus: CombinedShiftFocus, reconvert: Bool) -> AdaptiveEvidence? {
        guard let parsed = AdaptiveWordPair.make(original, replacement) else {
            occurrence = nil
            return nil
        }
        if reconvert {
            defer { occurrence = nil }
            guard let prior = occurrence,
                  prior.focus.processID == focus.processID,
                  CFEqual(prior.focus.element, focus.element),
                  prior.pair == parsed.pair,
                  prior.preferred != parsed.preferred else { return nil }
            return .manualUndo(id: prior.id)
        }
        let id = UUID()
        occurrence = Occurrence(id: id, pair: parsed.pair,
            preferred: parsed.preferred, focus: focus)
        return .manualConfirmed(id: id, original: original, replacement: replacement)
    }
}

/// Keeps the one confirmed automatic undo eligible for a matching manual redo.
/// Only the word pair and exact field identity are retained in RAM.
@MainActor
struct AdaptiveAutomaticUndoProvenance {
    private struct Occurrence {
        let id: UUID
        let pair: AdaptiveWordPair
        let preferred: String
        let focus: CombinedShiftFocus
    }
    private var occurrence: Occurrence?

    mutating func invalidate() { occurrence = nil }

    mutating func confirmedUndo(id: UUID, original: String, replacement: String,
                                focus: CombinedShiftFocus) {
        guard let parsed = AdaptiveWordPair.make(original, replacement) else {
            occurrence = nil
            return
        }
        occurrence = Occurrence(id: id, pair: parsed.pair,
            preferred: parsed.preferred, focus: focus)
    }

    mutating func confirmedRedo(original: String, replacement: String,
                                focus: CombinedShiftFocus) -> AdaptiveEvidence? {
        defer { occurrence = nil }
        guard let prior = occurrence,
              let parsed = AdaptiveWordPair.make(original, replacement),
              prior.focus.processID == focus.processID,
              CFEqual(prior.focus.element, focus.element),
              prior.pair == parsed.pair,
              prior.preferred != parsed.preferred else { return nil }
        return .automaticRedoConfirmed(id: prior.id)
    }
}
