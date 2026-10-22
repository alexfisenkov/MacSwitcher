import Foundation

/// Immutable offline frequency index. Prefix queries use binary bounds and a range-maximum
/// tree rather than allocating a dictionary entry for every prefix of 400,000 words.
struct PredictionLexicon: Sendable {
    struct PrefixEvidence: Equatable, Sendable {
        let maximumFrequency: Int
        let completions: Int
        static let empty = PrefixEvidence(maximumFrequency: 0, completions: 0)
    }

    enum LoadError: Error { case missingResource(String), invalidRow(String, Int), emptyLanguage(String) }

    private struct LanguageIndex: Sendable {
        let frequencies: [String: Int]
        let sortedWords: [String]
        let maximumTree: [Int]
        let leafCount: Int

        init(words: [String: Int]) {
            var normalized: [String: Int] = [:]
            normalized.reserveCapacity(words.count)
            for (word, count) in words where !word.isEmpty && count > 0 {
                let key = PredictionLexicon.normalize(word)
                normalized[key] = max(normalized[key] ?? 0, count)
            }
            frequencies = normalized
            sortedWords = normalized.keys.sorted()
            var leaves = 1
            while leaves < sortedWords.count { leaves *= 2 }
            leafCount = leaves
            var tree = [Int](repeating: 0, count: leaves * 2)
            for (index, word) in sortedWords.enumerated() { tree[leaves + index] = normalized[word] ?? 0 }
            if leaves > 1 {
                for node in stride(from: leaves - 1, through: 1, by: -1) {
                    tree[node] = max(tree[node * 2], tree[node * 2 + 1])
                }
            }
            maximumTree = tree
        }

        private func lowerBound(_ word: String) -> Int {
            var lower = 0, upper = sortedWords.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if sortedWords[middle] < word { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }

        func prefixEvidence(_ prefix: String) -> PrefixEvidence {
            guard !prefix.isEmpty else { return .empty }
            var lower = lowerBound(prefix)
            var upper = lowerBound(prefix + "\u{10FFFF}")
            let completions = upper - lower
            guard completions > 0 else { return .empty }
            lower += leafCount; upper += leafCount
            var maximum = 0
            while lower < upper {
                if lower % 2 == 1 { maximum = max(maximum, maximumTree[lower]); lower += 1 }
                if upper % 2 == 1 { upper -= 1; maximum = max(maximum, maximumTree[upper]) }
                lower /= 2; upper /= 2
            }
            return PrefixEvidence(maximumFrequency: maximum, completions: completions)
        }
    }

    private let indexes: [String: LanguageIndex]
    private let fullLexicon: FullFrequencyLexicon
    private let protectedTerms: ProtectedTerms

    init(wordsByLanguage: [String: [String: Int]],
         fullWordsByLanguage: [String: [String: Int]] = [:],
         protectedTermsByLanguage: [String: Set<String>] = [:],
         fullLexicon: FullFrequencyLexicon? = nil) {
        var grouped: [String: [String: Int]] = [:]
        for (language, words) in wordsByLanguage {
            let code = Self.languageCode(language)
            if var existing = grouped[code] {
                for (word, count) in words { existing[word] = max(existing[word] ?? 0, count) }
                grouped[code] = existing
            } else { grouped[code] = words }
        }
        indexes = grouped.mapValues { LanguageIndex(words: $0) }
        self.fullLexicon = fullLexicon ?? FullFrequencyLexicon(wordsByLanguage: fullWordsByLanguage)
        protectedTerms = ProtectedTerms(termsByLanguage: protectedTermsByLanguage)
    }

    private init(indexes: [String: LanguageIndex], fullLexicon: FullFrequencyLexicon,
                 protectedTerms: ProtectedTerms) {
        self.indexes = indexes
        self.fullLexicon = fullLexicon
        self.protectedTerms = protectedTerms
    }

    init(tsvByLanguage: [String: String]) throws {
        var wordsByLanguage: [String: [String: Int]] = [:]
        for (language, content) in tsvByLanguage {
            var words: [String: Int] = [:]
            for (row, line) in content.split(whereSeparator: \.isNewline).enumerated() {
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count == 2, !columns[0].isEmpty,
                      let count = Int(columns[1]), count > 0 else {
                    throw LoadError.invalidRow(language, row + 1)
                }
                let word = Self.normalize(String(columns[0]))
                words[word] = max(words[word] ?? 0, count)
            }
            guard !words.isEmpty else { throw LoadError.emptyLanguage(language) }
            wordsByLanguage[language] = words
        }
        self.init(wordsByLanguage: wordsByLanguage)
    }

    /// Call once outside the event-tap/main queue. No network or user dictionary is read.
    static func bundled() throws -> PredictionLexicon {
        let bundle = try PredictionResources.bundle()
        var contents: [String: String] = [:]
        for language in ["ru", "en"] {
            guard let url = bundle.url(forResource: language, withExtension: "tsv") else {
                throw LoadError.missingResource(language)
            }
            contents[language] = try String(contentsOf: url, encoding: .utf8)
        }
        var fullURLs: [String: URL] = [:]
        for language in ["ru", "en"] {
            guard let url = bundle.url(forResource: language + "-full", withExtension: "sqlite") else {
                throw LoadError.missingResource(language + "-full")
            }
            fullURLs[language] = url
        }
        guard let termsURL = bundle.url(forResource: "protected-terms", withExtension: "tsv") else {
            throw LoadError.missingResource("protected-terms")
        }
        let triggerLexicon = try PredictionLexicon(tsvByLanguage: contents)
        return try PredictionLexicon(indexes: triggerLexicon.indexes,
                                     fullLexicon: FullFrequencyLexicon(urlsByLanguage: fullURLs),
                                     protectedTerms: ProtectedTerms(tsv: String(contentsOf: termsURL, encoding: .utf8)))
    }

    /// Counts are separate: full corpus includes trigger entries, so do not sum them.
    var wordCounts: [String: Int] { indexes.mapValues { $0.frequencies.count } }
    var fullWordCounts: [String: Int] { fullLexicon.wordCounts }
    var protectedTermCounts: [String: Int] { protectedTerms.wordCounts }

    /// nil is an unavailable exact database read; zero is a known missing word.
    func fullFrequency(of word: String, language: String) -> Int? {
        fullLexicon.frequency(of: word, language: language)
    }

    func isProtectedTerm(_ word: String, language: String) -> Bool {
        protectedTerms.contains(word, language: language) || isPersonalWord(word, language: language)
    }

    /// Reads a bounded live snapshot; add/remove/import take effect without rebuilding the engine.
    func isPersonalWord(_ word: String, language: String) -> Bool {
        PersonalWordStore.shared.containsWord(word, language: Self.languageCode(language))
    }

    func frequency(of word: String, language: String) -> Int {
        indexes[Self.languageCode(language)]?.frequencies[Self.normalize(word)] ?? 0
    }

    func prefixEvidence(for prefix: String, language: String) -> PrefixEvidence {
        indexes[Self.languageCode(language)]?.prefixEvidence(Self.normalize(prefix)) ?? .empty
    }

    static func normalize(_ word: String) -> String { word.lowercased().precomposedStringWithCanonicalMapping }
    static func languageCode(_ value: String) -> String { String(value.lowercased().prefix(2)) }
}
