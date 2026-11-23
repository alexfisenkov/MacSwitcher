@testable import RuSwitcher

extension PredictionEngine {
    /// Tests written before the three outcomes check only what would be written
    /// automatically: a hint is not a write, so it reads as nil here.
    func appliedProposal(suffix: String, sourceLanguage: String, atBoundary: Bool = false,
                         precedingWords: [String] = [], alwaysConvertWords: Set<String> = [],
                         characterMapping: [Character: Character]? = nil,
                         russianPriority: Bool = false,
                         adaptiveRules: [AdaptiveRule] = []) -> PredictionProposal? {
        evaluate(suffix: suffix, sourceLanguage: sourceLanguage, atBoundary: atBoundary,
                 precedingWords: precedingWords, alwaysConvertWords: alwaysConvertWords,
                 characterMapping: characterMapping, russianPriority: russianPriority,
                 adaptiveRules: adaptiveRules).applied
    }
}
