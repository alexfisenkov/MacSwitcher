import Foundation

/// Callers select the source only after their text edit has an independent AX
/// acknowledgement. A queued Unicode receipt never proves delivery.
@MainActor
final class NativeQueuedSourceCommit {
    private let isCurrent: () -> Bool
    private let request: (String) -> LayoutSelectionCommit.Outcome
    private let onUnconfirmed: (String) -> Void
    private(set) var targetLayoutID: String?
    private(set) var outcome: LayoutSelectionCommit.Outcome?
    var confirmedLayoutID: String? { outcome == .confirmed ? targetLayoutID : nil }

    init(isCurrent: @escaping () -> Bool,
         request: @escaping (String) -> LayoutSelectionCommit.Outcome,
         onUnconfirmed: @escaping (String) -> Void = { _ in }) {
        self.isCurrent = isCurrent
        self.request = request
        self.onUnconfirmed = onUnconfirmed
    }

    func textQueued(targetID: String) {
        guard !targetID.isEmpty, targetLayoutID == nil else { return }
        targetLayoutID = targetID
        guard isCurrent() else { outcome = .refused; return }
        let requested = request(targetID)
        outcome = requested == .confirmed && !isCurrent() ? .unconfirmed : requested
        if outcome == .unconfirmed { onUnconfirmed(targetID) }
    }
}
