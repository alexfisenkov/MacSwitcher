import Foundation

/// Letter-trigram language model built from our own word-frequency lists
/// (script/build_trigrams.py). It only answers "how word-like is this spelling
/// in this language"; it never proposes a word by itself.
struct TrigramModel: Sendable {
    enum LoadError: Error { case invalidRow(Int), empty }

    static let start: Character = "^"
    static let end: Character = "$"

    private let counts: [String: Int]
    private let contexts: [String: Int]
    private let alphabetSize: Double

    /// Same weighting as script/build_trigrams.py: frequent words count more, but
    /// only logarithmically, so the model reflects spelling rather than a few words.
    static func weight(forFrequency frequency: Int) -> Int {
        frequency <= 1 ? 1 : Int(log2(Double(frequency))) + 1
    }

    static func trigrams(of word: String) -> [String] {
        let letters = [start, start] + Array(PredictionLexicon.normalize(word)) + [end]
        guard letters.count >= 3 else { return [] }
        return (0...(letters.count - 3)).map { String(letters[$0..<($0 + 3)]) }
    }

    init(counts: [String: Int]) {
        self.counts = counts
        var contexts: [String: Int] = [:]
        var alphabet = Set<Character>()
        for (trigram, count) in counts {
            contexts[String(trigram.prefix(2)), default: 0] += count
            if let last = trigram.last { alphabet.insert(last) }
        }
        self.contexts = contexts
        alphabetSize = Double(max(1, alphabet.count))
    }

    init(words: [String: Int]) {
        var counts: [String: Int] = [:]
        for (word, frequency) in words where frequency > 0 {
            let weight = Self.weight(forFrequency: frequency)
            for trigram in Self.trigrams(of: word) { counts[trigram, default: 0] += weight }
        }
        self.init(counts: counts)
    }

    /// `trigram<TAB>count` rows, as written by script/build_trigrams.py.
    init(tsv: String) throws {
        var counts: [String: Int] = [:]
        for (row, line) in tsv.split(whereSeparator: \.isNewline).enumerated() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 2, columns[0].count == 3, let count = Int(columns[1]), count > 0 else {
                throw LoadError.invalidRow(row + 1)
            }
            counts[String(columns[0])] = count
        }
        guard !counts.isEmpty else { throw LoadError.empty }
        self.init(counts: counts)
    }

    var trigramCount: Int { counts.count }

    /// Mean natural-log probability of each letter given the two before it
    /// (add-half smoothing). Higher is more word-like; unseen trigrams are penalised.
    func score(_ word: String) -> Double? {
        let trigrams = Self.trigrams(of: word)
        guard !trigrams.isEmpty, !counts.isEmpty else { return nil }
        var total = 0.0
        for trigram in trigrams {
            let observed = Double(counts[trigram] ?? 0) + 0.5
            let context = Double(contexts[String(trigram.prefix(2))] ?? 0) + 0.5 * alphabetSize
            total += log(observed / context)
        }
        return total / Double(trigrams.count)
    }
}
