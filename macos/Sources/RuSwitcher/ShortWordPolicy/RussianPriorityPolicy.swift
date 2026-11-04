import Foundation

/// The user's opt-in preference resolves a bounded set of common RU speech collisions.
/// It never replaces the general source-language and structural protections.
enum RussianPriorityPolicy {
    private static let technicalCues: Set<String> = [
        "press", "key", "keys", "keyboard", "button", "function", "variable", "symbol",
        "code", "script", "command", "shortcut", "url", "domain", "host",
        "path", "file", "folder", "directory", "нажми", "нажмите", "клавиша",
        "клавишу", "буква", "букву", "символ", "символа", "переменная", "путь", "файл"
    ]
    private static let commonRussianWords: Set<String> = [
        "а", "ну", "не", "да", "нет", "но", "же", "бы", "ли", "вот", "уже", "ещё",
        "это", "как", "что", "или", "где", "там", "тут", "без", "для"
    ]
    private static let immediateSingleLetterWords: Set<String> = ["а", "и", "в", "к", "с", "у", "о", "я"]
    // These may collide with real English abbreviations or source spellings.
    // Resolve only after a following token was itself corrected into strong Russian.
    private static let contextualWords: [String: String] = [
        "ns": "ты", "jy": "он", "vs": "мы", "ds": "вы", "dct": "все",
        "dfc": "вас", "jn": "от", "yfi": "наш", "vbh": "мир", "yb": "ни", "fuf": "ага"
    ]

    private static func isNeutralEntityContext(_ word: String, key: String,
                                               lexicon: PredictionLexicon) -> Bool {
        lexicon.isNeutralContextEntity(key, language: "en")
            && (word.contains(where: \.isUppercase)
                || lexicon.frequency(of: key, language: "en") < 5_000)
    }

    static func protectsEnglishContext(_ words: [String], lexicon: PredictionLexicon) -> Bool {
        let recent = words.suffix(3).map {
            ($0, $0.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        // Technical instructions remain protective regardless of surrounding prose.
        if recent.contains(where: { technicalCues.contains($0.1) }) { return true }
        let lastRussian = recent.lastIndex(where: { _, key in
            !key.isEmpty && key.allSatisfy { character in
                character.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
            }
        })
        var englishWords = 0
        for (index, (word, key)) in recent.enumerated() {
            if let lastRussian, index <= lastRussian { continue }
            if isNeutralEntityContext(word, key: key, lexicon: lexicon) { continue }
            if word.dropFirst().contains(where: \.isUppercase) { return true }
            if lexicon.isProtectedTerm(key, language: "en")
                || lexicon.frequency(of: key, language: "en") >= 5_000 {
                englishWords += 1
            }
        }
        return englishWords >= (lastRussian == nil ? 1 : 2)
    }

    static func contextualReplacement(for previous: String, sourceLanguage: String,
                                      precedingWords: [String], mapping: [Character: Character]?,
                                      lexicon: PredictionLexicon) -> String? {
        guard sourceLanguage == "en", previous == previous.lowercased(),
              let expected = contextualWords[previous],
              !lexicon.isProtectedTerm(previous, language: "en"),
              !protectsEnglishContext(precedingWords, lexicon: lexicon) else { return nil }
        let effective = mapping ?? KeyMapping.enToRu
        let converted = String(previous.compactMap { effective[$0] })
        guard converted.count == previous.count, converted == expected else { return nil }
        return expected
    }

    static func replacement(for current: String, previous: String?, sourceLanguage: String,
                            precedingWords: [String], atBoundary: Bool,
                            mapping: [Character: Character]?, lexicon: PredictionLexicon) -> String? {
        guard sourceLanguage == "en", current == current.lowercased(),
              !lexicon.isPersonalWord(current, language: "en") else { return nil }
        // An explicit map is authoritative. This also refuses non-QWERTY layouts
        // whose physical letters do not produce the intended Russian phrase.
        let effective = mapping ?? KeyMapping.enToRu
        guard effective["y"] == "н", effective["e"] == "у",
              effective["t"] == "е", effective["f"] == "а" else { return nil }
        var mapped = ""
        for letter in current {
            guard let replacement = effective[letter] else { return nil }
            mapped.append(replacement)
        }
        let exactYoWord = (current == "to\\" || current == "to`") && mapped == "ещё"
        let immediateSingleLetter = current.count == 1 && immediateSingleLetterWords.contains(mapped)
        let earlyPairedWord = current == "yt" && previous == "f" && mapped == "не"
        let earlyAfterEntity = current == "yt" && precedingWords.suffix(3).contains {
            isNeutralEntityContext($0,
                key: $0.lowercased().trimmingCharacters(in: .punctuationCharacters),
                lexicon: lexicon)
        }
        guard commonRussianWords.contains(mapped) || immediateSingleLetter,
              current == "ye" || exactYoWord || immediateSingleLetter || earlyPairedWord
                || earlyAfterEntity || atBoundary else { return nil }
        // Preserve real English prose, commands and named entities. A single
        // ambiguous token remains eligible only in genuinely neutral context.
        if protectsEnglishContext(precedingWords, lexicon: lexicon) { return nil }
        if current == "yt", previous == "f" {
            // The preceding f is a separate token. A continuation of one English
            // token such as yet never enters this two-token branch.
            return "не"
        }
        return mapped
    }
}
