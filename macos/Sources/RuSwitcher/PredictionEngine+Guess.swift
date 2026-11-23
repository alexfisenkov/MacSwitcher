import Foundation

/// Guesses for a finished word that is in no source list and has no exact
/// target reading. Both kinds are returned as `hint`, never applied.
extension PredictionEngine {
    /// A typo guess needs this much target frequency and must beat the next
    /// neighbour by this factor.
    static let typoMinimumFrequency = 1_000
    static let typoDominance = 5
    /// A source neighbour this frequent means the user probably mistyped their own language.
    static let sourceNeighbourFrequency = 2_000
    /// Mean log-probability per letter by which the other layout must look more word-like.
    static let trigramMargin = 1.5
    /// The other layout must also look like an ordinary word on its own.
    static let trigramFloor = -3.2

    func guessedCorrection(for word: String, source: String, target: String,
                           characterMapping: [Character: Character]?) -> (word: String, kind: CorrectionKind)? {
        let stripped = stripTrailingPunctuation(word)
        // The whole word first (a final . or , may be the letter ю or б), then without the tail.
        var readings: [(source: String, mapped: String, tail: String)] = []
        if let whole = map(word, source: source, characterMapping: characterMapping) {
            readings.append((word, whole, ""))
        }
        if !stripped.suffix.isEmpty,
           let core = map(stripped.core, source: source, characterMapping: characterMapping) {
            readings.append((stripped.core, core, stripped.suffix))
        }
        readings = readings.filter { lexicalToken($0.mapped) && $0.mapped.filter(\.isLetter).count >= 4 }
        guard !readings.isEmpty else { return nil }
        if PredictionTypoSearch.hasNeighbour(stripped.core, language: source, lexicon: lexicon,
                                             minimumFrequency: Self.sourceNeighbourFrequency) { return nil }
        // A rare but real target word is never "corrected" into a more frequent neighbour.
        let knownTarget = readings.contains { lexicon.frequency(of: $0.mapped, language: target) > 0 }
        for reading in readings where !knownTarget {
            guard let fixed = PredictionTypoSearch.uniqueCorrection(of: reading.mapped, language: target,
                lexicon: lexicon, minimumFrequency: Self.typoMinimumFrequency,
                dominance: Self.typoDominance) else { continue }
            return (Self.matchingInitialCase(fixed, like: reading.mapped) + reading.tail, .typo)
        }
        for reading in readings {
            guard let sourceScore = lexicon.trigramScore(of: reading.source, language: source),
                  let targetScore = lexicon.trigramScore(of: reading.mapped, language: target),
                  targetScore >= Self.trigramFloor,
                  targetScore - sourceScore >= Self.trigramMargin else { continue }
            return (reading.mapped + reading.tail, .trigram)
        }
        return nil
    }

    static func matchingInitialCase(_ word: String, like model: String) -> String {
        guard model.first?.isUppercase == true else { return word }
        return String(word.prefix(1)).uppercased() + String(word.dropFirst())
    }
}
