import Foundation

/// Words exactly one edit away: a replaced, swapped (neighbours), missing or extra
/// letter. Only the bundled trigger list is consulted, so a guess is always a
/// common word. Idea after Norvig's spelling corrector; no code is copied.
enum PredictionTypoSearch {
    static let alphabets: [String: [Character]] = [
        "ru": Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя"),
        "en": Array("abcdefghijklmnopqrstuvwxyz"),
    ]

    static func edits(of word: String, language: String) -> Set<String> {
        let letters = Array(PredictionLexicon.normalize(word))
        let alphabet = alphabets[PredictionLexicon.languageCode(language)] ?? []
        var result = Set<String>()
        for index in 0...letters.count {
            let head = letters[..<index], tail = letters[index...]
            for letter in alphabet { result.insert(String(head) + String(letter) + String(tail)) }
            guard index < letters.count else { continue }
            result.insert(String(head) + String(tail.dropFirst()))
            for letter in alphabet where letter != letters[index] {
                result.insert(String(head) + String(letter) + String(tail.dropFirst()))
            }
            if index + 1 < letters.count, letters[index] != letters[index + 1] {
                result.insert(String(head) + String(letters[index + 1]) + String(letters[index])
                    + String(tail.dropFirst(2)))
            }
        }
        result.remove(String(letters))
        return result
    }

    /// The one clearly most frequent neighbour, or nil when there is none or two
    /// neighbours are close in frequency (an ambiguous guess is never offered).
    static func uniqueCorrection(of word: String, language: String, lexicon: PredictionLexicon,
                                 minimumFrequency: Int, dominance: Int) -> String? {
        var best: (word: String, frequency: Int)?
        var runnerUp = 0
        for edit in edits(of: word, language: language) {
            let frequency = lexicon.frequency(of: edit, language: language)
            guard frequency > 0 else { continue }
            if let current = best, frequency <= current.frequency {
                runnerUp = max(runnerUp, frequency)
            } else {
                runnerUp = max(runnerUp, best?.frequency ?? 0)
                best = (edit, frequency)
            }
        }
        guard let best, best.frequency >= minimumFrequency,
              runnerUp.multipliedReportingOverflow(by: dominance).partialValue < best.frequency else { return nil }
        return best.word
    }

    /// True when the spelling is one edit from a known word of its own language:
    /// it is then more likely a slip in that language than a wrong layout.
    static func hasNeighbour(_ word: String, language: String, lexicon: PredictionLexicon,
                             minimumFrequency: Int) -> Bool {
        edits(of: word, language: language).contains {
            lexicon.frequency(of: $0, language: language) >= minimumFrequency
        }
    }
}
