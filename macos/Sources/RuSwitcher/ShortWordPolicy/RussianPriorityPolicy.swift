import Foundation

/// The user's opt-in preference resolves a bounded set of common RU speech collisions.
/// It never replaces the general source-language and structural protections.
enum RussianPriorityPolicy {
    private static let technicalCues: Set<String> = [
        "press", "key", "keys", "keyboard", "button", "function", "variable", "symbol",
        "code", "script", "command", "shortcut", "url", "domain", "host"
    ]
    private static let commonRussianWords: Set<String> = [
        "ну", "не", "да", "нет", "но", "же", "бы", "ли", "вот", "уже", "ещё",
        "это", "как", "что", "или", "где", "там", "тут", "без", "для"
    ]

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
        guard commonRussianWords.contains(mapped), current == "ye" || atBoundary else { return nil }
        // Preserve real English prose, commands and named entities. A single
        // ambiguous token remains eligible only in genuinely neutral context.
        for word in precedingWords.suffix(3) {
            let normalized = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if technicalCues.contains(normalized)
                || lexicon.isProtectedTerm(normalized, language: "en")
                || lexicon.frequency(of: normalized, language: "en") >= 5_000 {
                return nil
            }
        }
        if current == "yt", previous == "f" {
            // The pair is considered only at a word boundary, avoiding an early
            // rewrite of a longer English token such as "yet".
            return atBoundary ? "не" : nil
        }
        return mapped
    }
}
