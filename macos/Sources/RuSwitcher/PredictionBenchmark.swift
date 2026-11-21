import Foundation

/// Reproducible offline evaluation of public synthetic examples. Reports contain
/// aggregate counts and public case IDs, never input strings or user text.
enum PredictionBenchmark {
    enum LoadError: Error { case missingResource, unsupportedSchema, invalidCase(String), emptyCorpus }

    struct Case: Decodable, Sendable {
        let id: String
        let input: String
        let sourceLanguage: String
        let atBoundary: Bool
        let precedingWords: [String]
        let expectedReplacement: String?

        private enum CodingKeys: String, CodingKey {
            case id, input, sourceLanguage, atBoundary, precedingWords, expectedReplacement
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            input = try values.decode(String.self, forKey: .input)
            sourceLanguage = try values.decode(String.self, forKey: .sourceLanguage)
            atBoundary = try values.decode(Bool.self, forKey: .atBoundary)
            precedingWords = try values.decode([String].self, forKey: .precedingWords)
            // A missing gold field must not silently become a negative example.
            guard values.contains(.expectedReplacement) else {
                throw DecodingError.keyNotFound(CodingKeys.expectedReplacement,
                    DecodingError.Context(codingPath: values.codingPath, debugDescription: "Missing benchmark expectation"))
            }
            expectedReplacement = try values.decodeIfPresent(String.self, forKey: .expectedReplacement)
        }
    }

    struct Report: Encodable, Sendable {
        let goldRevision: Int
        let total: Int
        let expectedCorrection: Int
        let expectedNoChange: Int
        let truePositive: Int
        let falsePositive: Int
        let falseNegative: Int
        let wrongReplacement: Int
        let elapsedMilliseconds: Double
        let p50Microseconds: Double
        let p95Microseconds: Double
        let failureCaseIDs: [String]
        /// "dynamic" when the engine got the installed-layout table the coordinator uses, else "static".
        let layoutMapping: String
        var passed: Bool { falsePositive == 0 && falseNegative == 0 && wrongReplacement == 0 }
    }

    private struct Corpus: Decodable { let schema: Int; let goldRevision: Int?; let cases: [Case] }

    static func decodeCases(_ data: Data) throws -> [Case] { try decodeCorpus(data).cases }

    private static func decodeCorpus(_ data: Data) throws -> Corpus {
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.schema == 1, (corpus.goldRevision ?? 1) > 0 else { throw LoadError.unsupportedSchema }
        try validate(corpus.cases)
        return corpus
    }

    static func run(engine: PredictionEngine, bundle: Bundle) throws -> Report {
        guard let url = bundle.url(forResource: "prediction-benchmark", withExtension: "json") else {
            throw LoadError.missingResource
        }
        let corpus = try decodeCorpus(Data(contentsOf: url))
        // Installed-layout table as in PredictionCoordinator. The gold (revision 2) was authored without
        // Russian priority, which the quality report does enable; changing gold is a product decision.
        return try run(engine: engine, cases: corpus.cases, goldRevision: corpus.goldRevision ?? 1,
                       mapping: { productionMapping(sourceLanguage: $0) }, russianPriority: false)
    }

    static func run(engine: PredictionEngine, cases: [Case], goldRevision: Int = 1,
                    mapping: (String) -> [Character: Character]? = { _ in nil },
                    russianPriority: Bool = false) throws -> Report {
        guard goldRevision > 0 else { throw LoadError.unsupportedSchema }
        try validate(cases)
        var expectedCorrection = 0, truePositive = 0, falsePositive = 0
        var falseNegative = 0, wrongReplacement = 0
        var failures: [String] = []
        var durations: [UInt64] = []
        durations.reserveCapacity(cases.count)
        let started = DispatchTime.now().uptimeNanoseconds
        for item in cases {
            let before = DispatchTime.now().uptimeNanoseconds
            let actual = engine.evaluate(suffix: item.input, sourceLanguage: item.sourceLanguage,
                                         atBoundary: item.atBoundary, precedingWords: item.precedingWords,
                                         characterMapping: mapping(item.sourceLanguage),
                                         russianPriority: russianPriority)?.replacementSuffix
            durations.append(DispatchTime.now().uptimeNanoseconds - before)
            if let expected = item.expectedReplacement {
                expectedCorrection += 1
                if let actual {
                    if actual.utf16.elementsEqual(expected.utf16) { truePositive += 1 }
                    else { wrongReplacement += 1; failures.append(item.id) }
                } else { falseNegative += 1; failures.append(item.id) }
            } else if actual != nil { falsePositive += 1; failures.append(item.id) }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        durations.sort()
        func percentile(_ value: Double) -> Double {
            let index = max(0, Int(ceil(Double(durations.count) * value)) - 1)
            return Double(durations[index]) / 1_000
        }
        return Report(goldRevision: goldRevision, total: cases.count, expectedCorrection: expectedCorrection,
                      expectedNoChange: cases.count - expectedCorrection, truePositive: truePositive,
                      falsePositive: falsePositive, falseNegative: falseNegative, wrongReplacement: wrongReplacement,
                      elapsedMilliseconds: Double(elapsed) / 1_000_000,
                      p50Microseconds: percentile(0.50), p95Microseconds: percentile(0.95), failureCaseIDs: failures,
                      layoutMapping: mapping("en") != nil && mapping("ru") != nil ? "dynamic" : "static")
    }

    private static func validate(_ cases: [Case]) throws {
        guard !cases.isEmpty else { throw LoadError.emptyCorpus }
        var ids: Set<String> = []
        for item in cases {
            guard !item.id.isEmpty, item.id.utf8.count <= 80,
                  item.id.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value)
                    || (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
                    || "-_".unicodeScalars.contains($0) }),
                  ids.insert(item.id).inserted, ["ru", "en"].contains(item.sourceLanguage),
                  !item.input.isEmpty, item.input.count <= 512,
                  item.expectedReplacement != item.input else { throw LoadError.invalidCase(item.id) }
        }
    }
}

/// Honest quality measurement on thousands of generated phrases (script/build_quality_corpus.py).
/// Every phrase is typed word by word into the production `PredictionInputBuffer`; the engine is
/// asked once when the word is complete and once at the space, with the production layout table.
extension PredictionBenchmark {
    enum Quality {
        struct Token: Decodable, Sendable {
            let typed: String, expected: String, layout: String
            /// The one word of a "typo" phrase that carries the typo (fourth item in the corpus).
            let typo: Bool
            init(typed: String, expected: String, layout: String, typo: Bool = false) {
                self.typed = typed; self.expected = expected; self.layout = layout; self.typo = typo
            }
            init(from decoder: any Decoder) throws {
                var items = try decoder.unkeyedContainer()
                typed = try items.decode(String.self); expected = try items.decode(String.self)
                layout = try items.decode(String.self)
                typo = !items.isAtEnd
            }
        }
        struct Case: Decodable, Sendable { let id: String, category: String, language: String; let tokens: [Token] }
        /// Word-level outcomes. A "needing" word was typed wrongly; a "kept" word was already right.
        struct Counts: Encodable, Sendable, Equatable {
            var cases = 0, truePositive = 0, wrongReplacement = 0, falseNegative = 0, falsePositive = 0
            var keptWords = 0, changedCorrectCases = 0
            var needingWords: Int { truePositive + wrongReplacement + falseNegative }
            var precision: Double? {
                let changed = truePositive + wrongReplacement + falsePositive
                return changed == 0 ? nil : Double(truePositive) / Double(changed)
            }
            var recall: Double? { needingWords == 0 ? nil : Double(truePositive) / Double(needingWords) }
            var falsePositiveRate: Double? { keptWords == 0 ? nil : Double(falsePositive) / Double(keptWords) }
            mutating func add(_ other: Counts) {
                cases += other.cases; truePositive += other.truePositive; wrongReplacement += other.wrongReplacement
                falseNegative += other.falseNegative; falsePositive += other.falsePositive
                keptWords += other.keptWords; changedCorrectCases += other.changedCorrectCases
            }
        }
        struct Report: Encodable, Sendable {
            let layoutMapping: String
            let categories: [String: Counts]
            /// Share of already-correct words (plain and CAPS) the engine changed; the brief's ceiling is 0.5%.
            var correctTextFalsePositiveRate: Double? {
                var total = Counts()
                for name in ["correct", "caps-correct"] { total.add(categories[name] ?? Counts()) }
                return total.falsePositiveRate
            }
            var overall: Counts { categories.values.reduce(into: Counts()) { $0.add($1) } }
        }
        private struct Corpus: Decodable { let schema: Int; let cases: [Case] }

        static func loadCases(from url: URL) throws -> [Case] {
            let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
            guard corpus.schema == 1, !corpus.cases.isEmpty else { throw LoadError.unsupportedSchema }
            return corpus.cases
        }

        /// Types one phrase and returns the final words plus what happened to each.
        private static func simulate(_ item: Case, engine: PredictionEngine,
                                     mapping: (String) -> [Character: Character]?,
                                     russianPriority: Bool) -> [String] {
            var buffer = PredictionInputBuffer()
            for token in item.tokens {
                var language = token.layout
                func evaluate() {
                    guard let snapshot = buffer.snapshot(sourceLayoutID: "quality", inputRevision: 0, generation: 0),
                          let proposal = engine.evaluate(suffix: snapshot.suffix, sourceLanguage: language,
                              atBoundary: snapshot.atBoundary, precedingWords: snapshot.precedingWords,
                              characterMapping: mapping(language), russianPriority: russianPriority),
                          proposal.originalSuffix == snapshot.suffix,
                          buffer.replaceSuffix(original: proposal.originalSuffix,
                                               replacement: proposal.replacementSuffix) else { return }
                    language = proposal.targetLanguage  // the layout follows the applied correction
                }
                buffer.append(token.typed, processID: 1); evaluate()
                buffer.append(" ", processID: 1); evaluate()
            }
            return buffer.text.split(whereSeparator: \.isWhitespace).map(String.init)
        }

        static func run(engine: PredictionEngine, cases: [Case],
                        mapping: (String) -> [Character: Character]?, russianPriority: Bool = true) -> Report {
            var categories: [String: Counts] = [:]
            for item in cases {
                let final = simulate(item, engine: engine, mapping: mapping, russianPriority: russianPriority)
                let sameShape = final.count == item.tokens.count
                categories[item.category, default: Counts()].cases += 1
                var changedKept = false
                for (index, token) in item.tokens.enumerated() {
                    // A typo phrase is scored on its typo word; its other words are context.
                    let bucket = item.category == "typo" && !token.typo ? "typo-context" : item.category
                    var counts = Counts()
                    let result = sameShape ? final[index] : nil
                    if token.typed == token.expected {
                        counts.keptWords = 1
                        if result != token.typed { counts.falsePositive = 1; changedKept = true }
                    } else if result == token.expected { counts.truePositive = 1
                    } else if result == token.typed { counts.falseNegative = 1
                    } else { counts.wrongReplacement = 1 }
                    categories[bucket, default: Counts()].add(counts)
                }
                if changedKept { categories[item.category, default: Counts()].changedCorrectCases += 1 }
            }
            let dynamic = mapping("en") != nil && mapping("ru") != nil
            return Report(layoutMapping: dynamic ? "dynamic" : "static", categories: categories)
        }

        private static func percent(_ value: Double?) -> String {
            value.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
        }

        /// Fixed-width table: precision = right/changed, recall = right/needing, false = kept words changed.
        static func table(_ report: Report) -> String {
            func row(_ name: String, _ c: Counts) -> String {
                name.padding(toLength: 14, withPad: " ", startingAt: 0)
                    + [String(c.cases), String(c.needingWords), String(c.truePositive), String(c.wrongReplacement),
                       String(c.falseNegative), String(c.falsePositive), percent(c.precision), percent(c.recall),
                       percent(c.falsePositiveRate)]
                        .map { String(repeating: " ", count: max(0, 11 - $0.count)) + $0 }.joined()
            }
            let head = "category".padding(toLength: 14, withPad: " ", startingAt: 0)
                + ["cases", "needing", "right", "wrong", "missed", "false", "precision", "recall", "false/kept"]
                    .map { String(repeating: " ", count: max(0, 11 - $0.count)) + $0 }.joined()
            let lines = report.categories.keys.sorted().map { row($0, report.categories[$0]!) }
            return ([head] + lines + [row("ALL", report.overall), "layout table: \(report.layoutMapping)"])
                .joined(separator: "\n")
        }

        /// CLI entry: `--quality-report [corpus.json]`; exit 0, or 2 when the corpus/lexicon cannot load.
        static func runCommandLine(arguments: [String]) -> Int32 {
            guard let flag = arguments.firstIndex(of: "--quality-report") else { return -1 }
            let next = arguments.index(after: flag)
            let path = next < arguments.endIndex && !arguments[next].hasPrefix("--")
                ? arguments[next] : "macos/Tests/RuSwitcherTests/Resources/quality-corpus.json"
            do {
                let cases = try loadCases(from: URL(fileURLWithPath: path))
                let engine = PredictionEngine(lexicon: try PredictionLexicon.bundled())
                let report = run(engine: engine, cases: cases) { productionMapping(sourceLanguage: $0) }
                print(table(report))
                print("correct-text false corrections: \(percent(report.correctTextFalsePositiveRate)) (ceiling 0.5%)")
                return 0
            } catch {
                fputs("Quality corpus or lexicon could not be loaded\n", stderr)
                return 2
            }
        }
    }

    /// The same table the coordinator passes to the engine: dynamic, from the installed RU and EN layouts.
    static func productionMapping(sourceLanguage: String) -> [Character: Character]? {
        let layouts = LayoutSwitcher.installedLayouts()
        let language = String(sourceLanguage.lowercased().prefix(2))
        for source in layouts where LayoutSwitcher.languageCode(source)?.lowercased().hasPrefix(language) == true {
            guard let pair = LayoutSwitcher.combinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(source)),
                  let opposite = layouts.first(where: { LayoutSwitcher.sourceID($0) == pair.targetLayoutID }),
                  let oppositeLanguage = LayoutSwitcher.languageCode(opposite),
                  Set([language, String(oppositeLanguage.lowercased().prefix(2))]) == ["ru", "en"] else { continue }
            let map = DynamicKeyMapping.buildMap(from: source, to: opposite)
            if !map.isEmpty { return map }
        }
        return nil
    }
}
