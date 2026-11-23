import Foundation

/// The single place where the engine says what to do with the typed suffix.
/// `apply` keeps the existing verified write path; `hint` is never written by
/// the coordinator itself (a later gesture may accept it); `none` leaves text alone.
enum PredictionDecision: Equatable, Sendable {
    case apply(PredictionProposal)
    case hint(PredictionProposal)
    case none

    var applied: PredictionProposal? {
        if case .apply(let proposal) = self { return proposal }
        return nil
    }

    var hinted: PredictionProposal? {
        if case .hint(let proposal) = self { return proposal }
        return nil
    }
}
