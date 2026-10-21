import Foundation

/// Source commitment follows the queued text operation, not a possibly stale
/// AX acknowledgement. The receipt never claims that text was delivered.
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
