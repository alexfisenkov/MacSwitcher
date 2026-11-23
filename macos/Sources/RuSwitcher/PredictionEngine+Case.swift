import Foundation

/// CAPS words, «ПРивет» and one-letter Russian words next to a corrected word.
extension PredictionEngine {
    enum CaseShape: Equatable { case plain, allCaps, twoInitialCapitals }

    static func caseShape(of core: String) -> CaseShape {
        let letters = core.filter(\.isLetter)
        guard letters.count >= 2, letters != letters.lowercased() else { return .plain }
        if letters == letters.uppercased() { return .allCaps }
        let characters = Array(core)
        guard characters.count >= 4, characters.allSatisfy(\.isLetter),
              characters[0].isUppercase, characters[1].isUppercase,
              characters.dropFirst(2).allSatisfy(\.isLowercase) else { return .plain }
        return .twoInitialCapitals
    }

    /// nil means "not a case question": the caller keeps the ordinary decision,
    /// so every earlier protection of CAPS and camelCase stays as it was.
    func caseRestoredDecision(suffix: String, context: DecisionContext) -> PredictionDecision? {
        guard context.atBoundary || suffix.last?.isWhitespace == true else { return nil }
        let words = wordRanges(in: suffix)
        guard let range = words.last else { return nil }
        let current = String(suffix[range])
        let core = stripTrailingPunctuation(current).core
        let shape = Self.caseShape(of: core)
        guard shape != .plain, !lexicon.isProtectedTerm(core, language: context.source) else { return nil }
        let rewritten: String
        switch shape {
        case .plain: return nil
        case .twoInitialCapitals:
            rewritten = String(current.prefix(1)) + current.dropFirst().lowercased()
            let typo = twoCapitalsTypo(core, language: context.source)
            if typo == true {
                var replacement = suffix
                replacement.replaceSubrange(range, with: rewritten)
                return .apply(PredictionProposal(originalSuffix: suffix, replacementSuffix: replacement,
                    targetLanguage: context.source, reason: .capsRestored))
            }
            // A known source word that is not a clear typo is an accepted spelling.
            if typo == false { return PredictionDecision.none }
        case .allCaps:
            guard followsCapitalWord(suffix, words, context) else { return nil }
            rewritten = current.lowercased()
        }
        guard rewritten.count == current.count else { return nil }
        var working = suffix
        working.replaceSubrange(range, with: rewritten)
        let inner = decide(suffix: working, context: context)
        let restore: (PredictionProposal) -> PredictionProposal = { proposal in
            var replacement = proposal.replacementSuffix
            if shape == .allCaps, let last = wordRanges(in: replacement).last {
                replacement.replaceSubrange(last, with: replacement[last].uppercased())
            }
            if shape == .allCaps { replacement = self.withPreviousCapsWord(replacement, original: suffix, context: context) }
            return PredictionProposal(originalSuffix: suffix, replacementSuffix: replacement,
                targetLanguage: proposal.targetLanguage,
                reason: proposal.reason == .currentWord ? .capsRestored : proposal.reason)
        }
        switch inner {
        case .apply(let proposal): return .apply(restore(proposal))
        case .hint(let proposal): return .hint(restore(proposal))
        case .none: return nil
        }
    }

    /// Lowercase forms at least this common are ordinary words, not brand spellings.
    static let twoCapitalsTypoMinimumFrequency = 1_000

    /// «ПРивет» is a held Shift only when the lowercase word is common and the tail is
    /// not a likelier word of its own (В + Контакте, J + Unit). The bundled word lists are
    /// case-folded, so protected and personal terms are the exact-case record.
    /// true — fix the case; false — a known spelling, leave it; nil — unknown in the source
    /// language, so the word may be typed in the other layout (GHbdtn).
    private func twoCapitalsTypo(_ core: String, language: String) -> Bool? {
        let whole = lexicon.frequency(of: core, language: language)
        let tail = lexicon.frequency(of: String(core.dropFirst()), language: language)
        if tail > 0, tail >= whole { return false }
        guard whole > 0 else { return nil }
        return whole >= Self.twoCapitalsTypoMinimumFrequency
    }

    /// A lone CAPS word may be an abbreviation (РЕЕЗ is HTTP), so it stays. Only a
    /// CAPS word after another CAPS word, or after a capital one-letter Russian
    /// word typed in the other layout (D UJCNBYJQ), is read as text typed in capitals.
    private func followsCapitalWord(_ suffix: String, _ words: [Range<String.Index>],
                                    _ context: DecisionContext) -> Bool {
        guard words.count >= 2 else { return false }
        let previous = String(suffix[words[words.count - 2]])
        let letters = previous.filter(\.isLetter)
        guard !letters.isEmpty, letters == letters.uppercased(), letters != letters.lowercased() else { return false }
        if letters.count >= 2 { return true }
        guard context.source == "en", previous.count == 1,
              let mapped = map(previous, source: "en", characterMapping: context.characterMapping) else { return false }
        return Self.shortRussianWords.contains(mapped.lowercased())
    }

    /// When a CAPS word was converted, the CAPS word right before it is converted
    /// too, if it is a common target word and not a source word (PF XNJ → ЗА ЧТО).
    private func withPreviousCapsWord(_ replacement: String, original: String,
                                      context: DecisionContext) -> String {
        let before = wordRanges(in: original), after = wordRanges(in: replacement)
        guard before.count >= 2, after.count == before.count else { return replacement }
        let previous = String(original[before[before.count - 2]])
        let letters = previous.filter(\.isLetter)
        guard String(replacement[after[after.count - 2]]) == previous, letters.count >= 2,
              letters == previous, letters == letters.uppercased(),
              letters.allSatisfy({ context.source == "en" ? Self.isLatin($0) : Self.isCyrillic($0) }),
              !lexicon.isProtectedTerm(previous, language: context.source),
              let mapped = map(previous.lowercased(), source: context.source,
                               characterMapping: context.characterMapping), lexicalToken(mapped) else { return replacement }
        let targetFrequency = lexicon.frequency(of: mapped, language: context.target)
        let sourceFrequency = lexicon.frequency(of: previous, language: context.source)
        guard targetFrequency >= 500,
              sourceFrequency.multipliedReportingOverflow(by: 100).partialValue < targetFrequency else { return replacement }
        var result = replacement
        result.replaceSubrange(after[after.count - 2], with: mapped.uppercased())
        return result
    }

    /// z ghbdtn → я привет: a one-letter Latin word becomes a Russian one-letter
    /// word only when the next word was itself converted to a strong Russian word.
    func shortWordContextReplacement(previous: String, current: String, corrected: String?,
                                     technical: Bool, context: DecisionContext) -> String? {
        guard context.source == "en", previous.count == 1, previous != "f", !technical,
              let corrected, corrected != current,
              strongRussianContext(corrected.lowercased()),
              !lexicon.isPersonalWord(previous, language: "en"),
              let mapped = map(previous, source: "en", characterMapping: context.characterMapping),
              Self.shortRussianWords.contains(mapped.lowercased()) else { return nil }
        return mapped
    }
}
