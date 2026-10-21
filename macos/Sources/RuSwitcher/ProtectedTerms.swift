import Foundation

/// Project-curated public brand/name spellings. Membership is exact after NFC and
/// case folding; output always comes from the keyboard map, never canonical casing.
struct ProtectedTerms: Sendable {
    enum LoadError: Error { case invalidRow(Int) }
    private let terms: [String: Set<String>]

    init(termsByLanguage: [String: Set<String>] = [:]) {
        var normalized: [String: Set<String>] = [:]
        for (language, values) in termsByLanguage {
            normalized[PredictionLexicon.languageCode(language), default: []].formUnion(values.map(PredictionLexicon.normalize))
        }
        terms = normalized
    }

    init(tsv: String) throws {
        var parsed: [String: Set<String>] = [:]
        for (index, line) in tsv.split(whereSeparator: \.isNewline).enumerated() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, ["ru", "en"].contains(String(fields[0])), !fields[1].isEmpty,
                  ["brand", "name", "abbreviation", "word", "place"].contains(String(fields[2])) else {
                throw LoadError.invalidRow(index + 1)
            }
            parsed[String(fields[0]), default: []].insert(String(fields[1]))
        }
        self.init(termsByLanguage: parsed)
    }

    var wordCounts: [String: Int] { terms.mapValues(\.count) }

    func contains(_ word: String, language: String) -> Bool {
        terms[PredictionLexicon.languageCode(language)]?.contains(PredictionLexicon.normalize(word)) ?? false
    }
}
