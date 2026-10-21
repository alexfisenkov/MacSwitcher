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
        return try run(engine: engine, cases: corpus.cases, goldRevision: corpus.goldRevision ?? 1)
    }

    static func run(engine: PredictionEngine, cases: [Case], goldRevision: Int = 1) throws -> Report {
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
                                         atBoundary: item.atBoundary, precedingWords: item.precedingWords)?.replacementSuffix
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
                      p50Microseconds: percentile(0.50), p95Microseconds: percentile(0.95), failureCaseIDs: failures)
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
