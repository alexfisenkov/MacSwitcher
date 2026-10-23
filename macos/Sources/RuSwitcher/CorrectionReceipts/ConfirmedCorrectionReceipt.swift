import AppKit

/// Only this value crosses into UI. The AX element and full field stay in RAM.
struct ConfirmedCorrectionNotice: Sendable {
    let id: UUID
    let original: String
    let replacement: String
    let sourceLanguage: String
}

enum CorrectionUndoResult: Sendable {
    case confirmed
    case refused
    case unknown
    case sourceNotConfirmed(targetID: String)
}

/// Only a matched, one-use automatic receipt may take the gesture's undo path.
/// A stale automatic edit must not fall through to generic word reconversion.
enum DoubleShiftAutomaticUndo {
    case manual
    case receipt(ConfirmedCorrectionReceipt)
    case staleAutomatic
}

/// A specific confirmed automatic edit, independent of mutable reconversion state.
/// The native editor has already acknowledged `after` as the exact whole field.
struct ConfirmedCorrectionReceipt {
    let notice: ConfirmedCorrectionNotice
    let focus: CombinedShiftFocus
    let inputRevision: UInt64
    let sessionID: UInt64
    let sourceLayoutID: String
    let resultLayoutID: String
    let editOriginal: String
    let editReplacement: String
    let before: NativeFieldObservation
    let after: NativeFieldObservation
    let issuedAt: UInt64

    var retainedUTF16Units: Int {
        notice.original.utf16.count + notice.replacement.utf16.count
            + editOriginal.utf16.count + editReplacement.utf16.count
            + before.text.utf16.count + after.text.utf16.count
    }
}

/// Bounded one-use RAM registry. Claiming consumes an ID before any OS mutation;
/// a failed or uncertain attempt cannot replay the same click as a second write.
@MainActor
final class ConfirmedCorrectionReceipts {
    private static let maximumCount = 8
    private static let maximumUTF16Units = 1_048_576
    private static let lifetimeNanoseconds: UInt64 = 15_000_000_000
    private var entries: [ConfirmedCorrectionReceipt] = []
    private var gestureEligibleID: UUID?
    private let now: () -> UInt64

    init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    func retain(_ receipt: ConfirmedCorrectionReceipt) -> Bool {
        expire()
        guard receipt.retainedUTF16Units <= Self.maximumUTF16Units else { return false }
        entries.removeAll { $0.notice.id == receipt.notice.id }
        while entries.count >= Self.maximumCount
            || entries.reduce(0, { $0 + $1.retainedUTF16Units })
                > Self.maximumUTF16Units - receipt.retainedUTF16Units {
            guard !entries.isEmpty else { return false }
            entries.removeFirst()
        }
        entries.append(receipt)
        gestureEligibleID = receipt.notice.id
        return true
    }

    func claim(_ id: UUID) -> ConfirmedCorrectionReceipt? {
        expire()
        guard let index = entries.firstIndex(where: { $0.notice.id == id }),
              isFreshForToast(entries[index], at: now()) else { return nil }
        if gestureEligibleID == id { gestureEligibleID = nil }
        return entries.remove(at: index)
    }

    func claimForGesture(_ id: UUID) -> ConfirmedCorrectionReceipt? {
        guard gestureEligibleID == id,
              let index = entries.firstIndex(where: { $0.notice.id == id }),
              now() >= entries[index].issuedAt else { return nil }
        gestureEligibleID = nil
        return entries.remove(at: index)
    }

    func retireGestureCandidate() {
        gestureEligibleID = nil
        expire()
    }

    private func expire() {
        let now = now()
        entries.removeAll { receipt in
            receipt.notice.id != gestureEligibleID && !isFreshForToast(receipt, at: now)
        }
    }

    private func isFreshForToast(_ receipt: ConfirmedCorrectionReceipt, at now: UInt64) -> Bool {
        now >= receipt.issuedAt && now - receipt.issuedAt <= Self.lifetimeNanoseconds
    }
}

/// An undo suppresses just the next identical automatic proposal in that field.
/// No preference or lexical learning is written from a transient undo.
struct OneShotCorrectionSuppression {
    let focus: CombinedShiftFocus
    let sourceLayoutID: String
    let original: String
    let replacement: String
    let expiresAt: UInt64

    func matches(focus candidate: CombinedShiftFocus, sourceLayoutID: String,
                 original: String, replacement: String) -> Bool {
        self.focus.processID == candidate.processID
            && CFEqual(self.focus.element, candidate.element)
            && self.sourceLayoutID == sourceLayoutID
            && self.original.utf16.elementsEqual(original.utf16)
            && self.replacement.utf16.elementsEqual(replacement.utf16)
            && DispatchTime.now().uptimeNanoseconds <= expiresAt
    }
}
