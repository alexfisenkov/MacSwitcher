import ApplicationServices

/// The text after the first-tap caret, captured by one read scheduled after
/// the key callback returned. Kept in RAM for the gesture only; never logged.
/// Until it is ready, a drifted caret is not re-anchored.
@MainActor
final class CaretSuffixSnapshot {
    enum State: Equatable { case pending, ready(String), unavailable }
    private(set) var state: State = .pending

    var suffix: String? {
        if case .ready(let text) = state { return text }
        return nil
    }

    /// `read` returns the live selection and whole value. The selection must
    /// still be the first tap's collapsed caret; otherwise the snapshot is unusable.
    func capture(caret: CFRange, read: () -> (selection: CFRange?, text: String?)) {
        guard state == .pending else { return }
        let observed = read()
        guard caret.length == 0, let selection = observed.selection,
              selection.location == caret.location, selection.length == 0,
              let text = observed.text else { state = .unavailable; return }
        let units = Array(text.utf16)
        guard units.count <= NativeFieldEditPlan.maximumFieldUnits,
              caret.location >= 0, caret.location <= units.count else { state = .unavailable; return }
        state = .ready(String(decoding: units[caret.location...], as: UTF16.self))
    }

    /// Live AX read; secure fields are refused by `nativeValueText`.
    static func liveRead(_ focus: CombinedShiftFocus) -> (selection: CFRange?, text: String?) {
        (focus.selectionRange(), focus.nativeValueText())
    }
}
