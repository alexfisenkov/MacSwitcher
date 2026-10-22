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
    private enum EvaluationRefusal: Error { case unavailableLexicon }
    private static let domainContext: Set<String> = [
        "сайт", "сайта", "сайте", "домен", "домена", "домене", "ссылка", "ссылке", "адрес", "адресу",
        "хост", "хосте", "domain", "url", "website", "site", "host", "hostname", "link", "visit", "browse"
    ]
    private static let peopleModifiers: Set<String> = [
        "эти", "все", "наши", "другие", "многие", "некоторые", "добрые", "хорошие", "новые", "молодые"
    ]
    // Conservative project policy, not an exhaustive IANA registry. All two-letter
    // final labels are protected separately, including country-code-like labels.
    private static let protectedHostnameSuffixes: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "name", "mobi", "online", "site",
        "app", "dev", "tech", "shop", "store", "cloud", "website", "xyz", "pro", "one", "top", "club", "live",
        "news", "world", "design", "space", "blog", "wiki", "video", "social", "email", "work", "agency",
        "digital", "studio", "today", "travel", "support", "solutions", "systems", "network", "company",
        "center", "zone", "link", "click", "tools", "pages", "рф", "xn--p1ai"
    ]
    private static let literalPunctuation: Set<Character> = [",", ".", "!", "?", ";", ":", ")"]

    func evaluate(suffix: String, sourceLanguage: String, atBoundary: Bool = false,
                  precedingWords: [String] = [], alwaysConvertWords: Set<String> = [],
                  characterMapping: [Character: Character]? = nil,
                  russianPriority: Bool = false) -> PredictionProposal? {
        let source = String(sourceLanguage.lowercased().prefix(2))
        guard source == "ru" || source == "en", !suffix.isEmpty, suffix.count <= 512,
              !suffix.contains(where: { $0.isNewline || $0 == "\t" }) else { return nil }
        // Ranges retain the exact original whitespace and rendered characters.
        let words = wordRanges(in: suffix)
        guard let currentRange = words.last else { return nil }
        let current = String(suffix[currentRange])
        let target = source == "en" ? "ru" : "en"
        let domainCues = (precedingWords + words.dropLast().map { String(suffix[$0]) }).suffix(3)
        let hasDomainContext = domainCues.contains { Self.domainContext.contains(contextKey($0)) }
        let hasPeopleCollocation = domainCues.last.map { Self.peopleModifiers.contains(contextKey($0)) } ?? false
        let previousWord = words.count >= 2 ? String(suffix[words[words.count - 2]]) : nil
        let pairedShortWord = previousWord == "f" && ["yt", "to\\", "to`"].contains(current)
        let priorityContext = precedingWords + words.dropLast(pairedShortWord ? 2 : 1)
            .map { String(suffix[$0]) }
        // Only these exact physical-key spellings may cross the backslash guard.
        // Paths, commands and every other token retain the general protection.
        let exactYoWord = source == "en" && (current == "to\\" || current == "to`")
        let priority = russianPriority && (exactYoWord || !protectedToken(current))
            ? RussianPriorityPolicy.replacement(for: current, previous: previousWord,
                sourceLanguage: source, precedingWords: priorityContext,
                atBoundary: atBoundary || suffix.last?.isWhitespace == true,
                mapping: characterMapping, lexicon: lexicon) : nil
        // A rejected backtick spelling must not fall through to the broad
        // dictionary path in code/technical context.
        if russianPriority && exactYoWord && priority == nil { return nil }
        let corrected: String?
        do {
            corrected = try (priority ?? correction(for: current, source: source, target: target,
                atBoundary: atBoundary || suffix.last?.isWhitespace == true,
                alwaysConvertWords: alwaysConvertWords, characterMapping: characterMapping,
                hasDomainContext: hasDomainContext, hasPeopleCollocation: hasPeopleCollocation))
        } catch { return nil }
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
            if previous == "f", !technical, letterMatchesLayout,
               (!russianPriority || !lexicon.isPersonalWord(previous, language: "en")),
               strongRussianContext(resultingWord) {
                let result = String(suffix[..<previousRange.lowerBound]) + "а"
                    + String(suffix[previousRange.upperBound..<currentRange.lowerBound]) + resultingWord
                    + String(suffix[currentRange.upperBound...])
                return PredictionProposal(originalSuffix: suffix, replacementSuffix: result,
                                          targetLanguage: "ru", reason: .contextWord)
            }
            if priority == "не", previous == "f", !technical,
               (!russianPriority || !lexicon.isPersonalWord(previous, language: "en")) {
                let result = String(suffix[..<previousRange.lowerBound]) + "а"
                    + String(suffix[previousRange.upperBound..<currentRange.lowerBound]) + "не"
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
                            alwaysConvertWords: Set<String>, characterMapping: [Character: Character]?,
                            hasDomainContext: Bool, hasPeopleCollocation: Bool) throws -> String? {
        let stripped = stripTrailingPunctuation(word)
        guard let mapped = map(word, source: source, characterMapping: characterMapping) else { return nil }
        let candidates: [(core: String, suffix: String)] = stripped.suffix.isEmpty
            ? [(mapped, "")]
            : [(mapped, ""), (map(stripped.core, source: source, characterMapping: characterMapping) ?? "", stripped.suffix)]
        let forced = atBoundary ? candidates.first {
            lexicalToken($0.core) && alwaysConvertWords.contains($0.core.lowercased())
                && $0.core + $0.suffix != word
        } : nil
        // Mixed-case known brands can be recovered exactly (СрфеПЗЕ → ChatGPT).
        // ALLCAPS acronyms still require a separate explicit owner boundary force.
        let knownTarget = candidates.contains { lexicon.isProtectedTerm($0.core, language: target) }
        let protectedHostname = hasProtectedHostnameShape(stripped.core)
        let exactRussianDotEvidence = source == "en" && !hasDomainContext && candidates.contains {
            lexicalToken($0.core)
                && (!protectedHostname || (hasPeopleCollocation && $0.core.lowercased() == "люди"))
                && (lexicon.frequency(of: $0.core, language: "ru") >= 50_000
                    || lexicon.isProtectedTerm($0.core, language: "ru"))
        }
        guard !protectedToken(word, allowKnownTargetCase: knownTarget || forced != nil,
                              allowAllCaps: forced != nil, allowMappedInteriorDot: exactRussianDotEvidence) else { return nil }
        // Owner exceptions remain bounded target forms and cannot bypass addresses,
        // numbers, mixed scripts, paths or other structural technical protections.
        if let forced { return forced.core + forced.suffix }
        if lexicon.isProtectedTerm(stripped.core, language: source) { return nil }
        guard word.count >= 2 else { return nil }
        // Trigger entries remain strong source evidence. The much noisier full
        // corpus is checked separately and must not freeze typos such as rfr.
        if lexicon.frequency(of: word, language: source) > 0
            || lexicon.frequency(of: stripped.core, language: source) > 0 { return nil }
        if atBoundary, candidates.contains(where: {
            $0.core.count >= 3 && lexicalToken($0.core)
                && lexicon.isPersonalWord($0.core, language: target)
        }) {
            return candidates.first(where: {
                $0.core.count >= 3 && lexicalToken($0.core)
                    && lexicon.isPersonalWord($0.core, language: target)
            }).map { $0.core + $0.suffix }
        }
        guard let fullWordFrequency = lexicon.fullFrequency(of: word, language: source),
              let fullCoreFrequency = stripped.suffix.isEmpty ? fullWordFrequency
                : lexicon.fullFrequency(of: stripped.core, language: source) else {
            throw EvaluationRefusal.unavailableLexicon
        }
        let rareSourceFrequency = max(fullWordFrequency, fullCoreFrequency)
        for candidate in candidates {
            guard lexicalToken(candidate.core), candidate.core.count >= 2 else { continue }
            let sourcePrefix = lexicon.prefixEvidence(for: stripped.core, language: source)
            let frequency = lexicon.frequency(of: candidate.core, language: target)
            if rareSourceFrequency > 0 {
                // Full tails contain names, misspellings, acronyms and subtitle noise.
                // Only a very strong exact target may beat a low-frequency collision;
                // target prefixes or an unweighted curated spelling cannot do so.
                let minimum = atBoundary ? 50_000 : 100_000
                guard rareSourceFrequency <= (atBoundary ? 50 : 10),
                      frequency >= minimum, frequency / rareSourceFrequency >= 10_000 else { continue }
                if !atBoundary && candidate.core.filter(\.isLetter).count < 4 { continue }
            }
            if rareSourceFrequency == 0, lexicon.isProtectedTerm(candidate.core, language: target),
               candidate.core.filter(\.isLetter).count >= (atBoundary ? 3 : 4),
               sourcePrefix.maximumFrequency <= 50 {
                return candidate.core + candidate.suffix
            }
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

    private func protectedToken(_ word: String, allowKnownTargetCase: Bool = false,
                                allowAllCaps: Bool = false, allowMappedInteriorDot: Bool = false) -> Bool {
        guard !word.isEmpty, word.count <= 96 else { return true }
        if word.contains(where: { $0.isNumber || "@_/:\\=+(){}<>#".contains($0) }) { return true }
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return true }
        if !allowAllCaps, letters.count > 1 && letters == letters.uppercased() { return true }
        if !allowKnownTargetCase, word.dropFirst().contains(where: \.isUppercase) { return true }
        let hasLatin = letters.contains(where: Self.isLatin)
        let hasCyrillic = letters.contains(where: Self.isCyrillic)
        if hasLatin && hasCyrillic { return true }
        // Interior dots default to hostname protection. Exact Russian evidence may
        // permit a layout correction; protected suffixes also need a narrow positive
        // collocation, and a domain cue always keeps protection.
        // A final dot remains eligible for Russian ю (levf. → думаю).
        if hasLatin, !allowMappedInteriorDot, let dot = word.firstIndex(of: "."), word.index(after: dot) < word.endIndex,
           word[word.index(after: dot)...].contains(where: \.isLetter) { return true }
        return false
    }

    private func hasProtectedHostnameShape(_ word: String) -> Bool {
        let labels = word.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.first != "-" && label.last != "-"
                && label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        }), let ending = labels.last else { return false }
        return (ending.count == 2 && ending.allSatisfy(\.isLetter))
            || Self.protectedHostnameSuffixes.contains(String(ending))
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
