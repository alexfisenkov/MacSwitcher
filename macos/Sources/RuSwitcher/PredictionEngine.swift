import Foundation

struct PredictionProposal: Equatable, Sendable {
    enum Reason: Equatable, Sendable { case currentWord, contextWord }
    let originalSuffix: String
    let replacementSuffix: String
    let targetLanguage: String
    let reason: Reason
}

/// Pure RU/EN decision policy. It proposes a bounded exact suffix; only the runtime's
/// PID/focus/revision/caret verification is allowed to apply that proposal.
struct PredictionEngine: Sendable {
    let lexicon: PredictionLexicon

    private static let technicalContext: Set<String> = [
        "press", "key", "keys", "keyboard", "button", "function", "variable", "symbol",
        "нажми", "нажмите", "клавиша", "клавишу", "клавиши", "клавишей", "буква", "букву",
        "буквы", "символ", "символа", "символом", "функция", "функцию", "переменная", "витамин"
    ]
    private static let literalPunctuation: Set<Character> = [",", ".", "!", "?", ";", ":", ")"]

    func evaluate(suffix: String, sourceLanguage: String, atBoundary: Bool = false,
                  precedingWords: [String] = [], alwaysConvertWords: Set<String> = [],
                  characterMapping: [Character: Character]? = nil) -> PredictionProposal? {
        let source = String(sourceLanguage.lowercased().prefix(2))
        guard source == "ru" || source == "en", !suffix.isEmpty, suffix.count <= 512,
              !suffix.contains(where: { $0.isNewline || $0 == "\t" }) else { return nil }
        // Ranges retain the exact original whitespace and rendered characters.
        let words = wordRanges(in: suffix)
        guard let currentRange = words.last else { return nil }
        let current = String(suffix[currentRange])
        let target = source == "en" ? "ru" : "en"
        let corrected = correction(for: current, source: source, target: target,
                                   atBoundary: atBoundary || suffix.last?.isWhitespace == true,
                                   alwaysConvertWords: alwaysConvertWords, characterMapping: characterMapping)
        let resultingWord = corrected ?? current

        // A closed single f stays unresolved until the following token provides strong
        // Russian evidence. Already-correct Russian words are useful evidence too.
        if words.count >= 2 {
            let previousRange = words[words.count - 2]
            let previous = String(suffix[previousRange])
            let earlier = words.dropLast(2).map { String(suffix[$0]) }
            let cues = (precedingWords + earlier).suffix(3)
            let technical = cues.contains { Self.technicalContext.contains(contextKey($0)) }
            let letterMatchesLayout = characterMapping.map {
                source == "en" ? $0["f"] == "а" : $0["а"] == "f"
            } ?? true
            if previous == "f", !technical, letterMatchesLayout, strongRussianContext(resultingWord) {
                let result = String(suffix[..<previousRange.lowerBound]) + "а"
                    + String(suffix[previousRange.upperBound..<currentRange.lowerBound]) + resultingWord
                    + String(suffix[currentRange.upperBound...])
                return PredictionProposal(originalSuffix: suffix, replacementSuffix: result,
                                          targetLanguage: "ru", reason: .contextWord)
            }
        }

        guard let corrected, corrected != current else { return nil }
        var replacement = suffix
        replacement.replaceSubrange(currentRange, with: corrected)
        return PredictionProposal(originalSuffix: suffix, replacementSuffix: replacement,
                                  targetLanguage: target, reason: .currentWord)
    }

    private func correction(for word: String, source: String, target: String, atBoundary: Bool,
                            alwaysConvertWords: Set<String>, characterMapping: [Character: Character]?) -> String? {
        guard !protectedToken(word) else { return nil }
        let stripped = stripTrailingPunctuation(word)
        guard let mapped = map(word, source: source, characterMapping: characterMapping) else { return nil }
        let candidates: [(core: String, suffix: String)] = stripped.suffix.isEmpty
            ? [(mapped, "")]
            : [(mapped, ""), (map(stripped.core, source: source, characterMapping: characterMapping) ?? "", stripped.suffix)]
        // Owner-maintained exceptions are explicit target forms. Restrict them to
        // boundaries so a short forced word cannot corrupt a longer word's prefix.
        if atBoundary, !alwaysConvertWords.isEmpty {
            for candidate in candidates where lexicalToken(candidate.core) {
                if alwaysConvertWords.contains(candidate.core.lowercased()), candidate.core + candidate.suffix != word {
                    return candidate.core + candidate.suffix
                }
            }
        }
        guard word.count >= 2 else { return nil }
        // A recognized source word, including rare entries and sentence punctuation,
        // always wins over an automatic guess. An explicit owner override above wins.
        if lexicon.frequency(of: word, language: source) > 0
            || lexicon.frequency(of: stripped.core, language: source) > 0 { return nil }
        for candidate in candidates {
            guard lexicalToken(candidate.core), candidate.core.count >= 2 else { continue }
            let sourcePrefix = lexicon.prefixEvidence(for: stripped.core, language: source)
            let frequency = lexicon.frequency(of: candidate.core, language: target)
            if atBoundary {
                if frequency >= 500 { return candidate.core + candidate.suffix }
                continue
            }
            // Midword correction requires four characters and at least two orders of
            // magnitude stronger target evidence. Short prefixes remain untouched.
            guard candidate.core.filter(\.isLetter).count >= 4 else { continue }
            let targetPrefix = lexicon.prefixEvidence(for: candidate.core, language: target)
            let strength = max(frequency, targetPrefix.maximumFrequency)
            guard strength >= 5_000, sourcePrefix.maximumFrequency <= 50,
                  strength / max(1, sourcePrefix.maximumFrequency) >= 100 else { continue }
            if frequency >= 5_000 || (candidate.suffix.isEmpty && targetPrefix.completions > 0) {
                return candidate.core + candidate.suffix
            }
        }
        return nil
    }

    private func strongRussianContext(_ word: String) -> Bool {
        guard !protectedToken(word) else { return false }
        let core = stripTrailingPunctuation(word).core
        guard core.count >= 3, core.allSatisfy({ Self.isCyrillic($0) || $0 == "-" }) else { return false }
        if lexicon.frequency(of: core, language: "ru") >= 5_000 { return true }
        let prefix = lexicon.prefixEvidence(for: core, language: "ru")
        return core.count >= 4 && prefix.maximumFrequency >= 20_000 && prefix.completions > 0
    }

    private func protectedToken(_ word: String) -> Bool {
        guard !word.isEmpty, word.count <= 96 else { return true }
        if word.contains(where: { $0.isNumber || "@_/:\\=+(){}<>#".contains($0) }) { return true }
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return true }
        if letters.count > 1 && letters == letters.uppercased() { return true }
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        let hasLatin = letters.contains(where: Self.isLatin)
        let hasCyrillic = letters.contains(where: Self.isCyrillic)
        if hasLatin && hasCyrillic { return true }
        // A dot followed by letters inside a Latin token is URL/hostname-like. A final
        // dot stays eligible: on QWERTY that physical key is Russian ю (levf. → думаю).
        if hasLatin, let dot = word.firstIndex(of: "."), word.index(after: dot) < word.endIndex,
           word[word.index(after: dot)...].contains(where: \.isLetter) { return true }
        return false
    }

    private func lexicalToken(_ word: String) -> Bool {
        guard word.first?.isLetter == true, word.last?.isLetter == true else { return false }
        return word.allSatisfy({ $0.isLetter || $0 == "-" }) && !word.contains("--")
    }

    private func map(_ word: String, source: String, characterMapping: [Character: Character]?) -> String? {
        let mapping = characterMapping ?? (source == "en" ? KeyMapping.enToRu : KeyMapping.ruToEn)
        var output = ""
        for character in word {
            if let mapped = mapping[character] { output.append(mapped) }
            else {
                // An explicit source/target map must account for every source letter.
                // Never silently substitute QWERTY for another selected English layout.
                if characterMapping != nil && character.isLetter { return nil }
                output.append(character)  // literal hyphens and unmapped punctuation
            }
        }
        return output
    }

    private func stripTrailingPunctuation(_ word: String) -> (core: String, suffix: String) {
        var boundary = word.endIndex
        while boundary > word.startIndex {
            let previous = word.index(before: boundary)
            guard Self.literalPunctuation.contains(word[previous]) else { break }
            boundary = previous
        }
        return (String(word[..<boundary]), String(word[boundary...]))
    }

    private func wordRanges(in string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in string.indices {
            if string[index].isWhitespace {
                if let lower = start { ranges.append(lower..<index); start = nil }
            } else if start == nil { start = index }
        }
        if let start { ranges.append(start..<string.endIndex) }
        return ranges
    }

    private func contextKey(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func isLatin(_ value: Character) -> Bool {
        value.unicodeScalars.allSatisfy { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
    }
    private static func isCyrillic(_ value: Character) -> Bool {
        value.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }
}
