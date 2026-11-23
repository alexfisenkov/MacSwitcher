import XCTest
@testable import RuSwitcher

final class PredictionQualityTests: XCTestCase {
    /// Corpus is a test resource outside the bundle; locate it next to this file.
    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/quality-corpus.json")
    }

    /// Known tiny lexicon: every expected number below is derived by hand.
    private func tinyEngine() -> PredictionEngine {
        PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: [
            "ru": ["привет": 1_000_000, "мир": 500_000], "en": ["hello": 500_000]]))
    }

    private func phrase(_ id: String, _ category: String, _ typed: String, _ expected: String,
                        layout: String = "en") -> PredictionBenchmark.Quality.Case {
        .init(id: id, category: category, language: "ru",
              tokens: [.init(typed: typed, expected: expected, layout: layout)])
    }

    func testReportCountsEachOutcomePerCategory() {
        let cases = [
            phrase("a", "wrong-layout", "ghbdtn", "привет"),   // fixed correctly
            phrase("b", "wrong-layout", "ghbdtn", "мир"),      // converted, but to another word
            phrase("c", "wrong-layout", "zzzz", "слово"),      // engine knows nothing: missed
            phrase("d", "correct", "hello", "hello"),          // kept
            phrase("e", "correct", "ghbdtn", "ghbdtn"),        // must stay, engine converts: false positive
        ]
        let report = PredictionBenchmark.Quality.run(engine: tinyEngine(), cases: cases, mapping: { _ in nil })
        let wrong = report.categories["wrong-layout"]
        XCTAssertEqual(wrong?.cases, 3)
        XCTAssertEqual(wrong?.truePositive, 1)
        XCTAssertEqual(wrong?.wrongReplacement, 1)
        XCTAssertEqual(wrong?.falseNegative, 1)
        XCTAssertEqual(wrong?.precision ?? -1, 1.0 / 2.0, accuracy: 1e-9)
        XCTAssertEqual(wrong?.recall ?? -1, 1.0 / 3.0, accuracy: 1e-9)
        let correct = report.categories["correct"]
        XCTAssertEqual(correct?.keptWords, 2)
        XCTAssertEqual(correct?.falsePositive, 1)
        XCTAssertEqual(correct?.changedCorrectCases, 1)
        XCTAssertNil(correct?.recall)
    }

    func testCorrectTextFalsePositiveRateCoversPlainAndCapsText() {
        let cases = [phrase("d", "correct", "hello", "hello"), phrase("e", "correct", "ghbdtn", "ghbdtn"),
                     phrase("f", "caps-correct", "HELLO", "HELLO"), phrase("g", "caps-correct", "HELLO", "HELLO")]
        let report = PredictionBenchmark.Quality.run(engine: tinyEngine(), cases: cases, mapping: { _ in nil })
        // Four kept words, one of them ("ghbdtn") wrongly converted.
        XCTAssertEqual(report.correctTextFalsePositiveRate ?? -1, 0.25, accuracy: 1e-9)
    }

    func testTypoWordIsMeasuredApartFromItsContextWords() {
        let item = PredictionBenchmark.Quality.Case(id: "t", category: "typo", language: "ru", tokens: [
            .init(typed: "ghbdtn", expected: "привет", layout: "en", typo: true),
            .init(typed: "vbh", expected: "мир", layout: "en"),
            .init(typed: "zzzz", expected: "слово", layout: "en", typo: true),
        ])
        let report = PredictionBenchmark.Quality.run(engine: tinyEngine(), cases: [item], mapping: { _ in nil })
        XCTAssertEqual(report.categories["typo"]?.cases, 1)
        XCTAssertEqual(report.categories["typo"]?.truePositive, 1)
        XCTAssertEqual(report.categories["typo"]?.falseNegative, 1)
        XCTAssertEqual(report.categories["typo-context"]?.truePositive, 1)
        XCTAssertEqual(report.categories["typo-context"]?.cases, 0)
    }

    func testHintsAreCountedApartFromCorrections() {
        // Hand-derived: ghbdtv (→ привем) is one letter from привет and only hinted, never written.
        let typo = PredictionBenchmark.Quality.Case(id: "h", category: "typo", language: "ru", tokens: [
            .init(typed: "ghbdtv", expected: "привет", layout: "en", typo: true),
            .init(typed: "vbh", expected: "мир", layout: "en"),
        ])
        let report = PredictionBenchmark.Quality.run(engine: tinyEngine(), cases: [typo], mapping: { _ in nil })
        let counts = report.categories["typo"]
        XCTAssertEqual(counts?.truePositive, 0)
        XCTAssertEqual(counts?.falseNegative, 1)
        XCTAssertEqual(counts?.hintRight, 1)
        XCTAssertEqual(counts?.hintWrong, 0)
        XCTAssertEqual(counts?.recallWithHints ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertTrue(PredictionBenchmark.Quality.table(report).contains("hint-ok"))
    }

    func testTableListsPrecisionAndRecallForEveryCategory() {
        let cases = [phrase("a", "wrong-layout", "ghbdtn", "привет"), phrase("d", "correct", "hello", "hello")]
        let report = PredictionBenchmark.Quality.run(engine: tinyEngine(), cases: cases, mapping: { _ in nil })
        let table = PredictionBenchmark.Quality.table(report)
        XCTAssertTrue(table.contains("wrong-layout"))
        XCTAssertTrue(table.contains("correct"))
        XCTAssertTrue(table.contains("100.0%"))
    }

    func testShippedCorpusHasFiveToTenThousandCasesInAllCategories() throws {
        let cases = try PredictionBenchmark.Quality.loadCases(from: Self.corpusURL)
        XCTAssertTrue((5_000...10_000).contains(cases.count), "\(cases.count)")
        XCTAssertEqual(Set(cases.map(\.category)),
                       ["wrong-layout", "typo", "caps", "caps-correct", "mixed", "correct"])
        XCTAssertEqual(Set(cases.map(\.language)), ["ru", "en"])
    }

    func testProductionMappingIsTheDynamicLayoutTable() throws {
        guard let toRussian = PredictionBenchmark.productionMapping(sourceLanguage: "en"),
              let toEnglish = PredictionBenchmark.productionMapping(sourceLanguage: "ru") else {
            throw XCTSkip("RU and EN keyboard layouts are not installed")
        }
        XCTAssertEqual(toRussian["g"], "п")
        XCTAssertEqual(toEnglish["п"], "g")
        let layouts = LayoutSwitcher.installedLayouts()
        let en = layouts.first { LayoutSwitcher.languageCode($0)?.lowercased().hasPrefix("en") == true }
        let ru = layouts.first { LayoutSwitcher.languageCode($0)?.lowercased().hasPrefix("ru") == true }
        if let en, let ru { XCTAssertEqual(toRussian.count, DynamicKeyMapping.buildMap(from: en, to: ru).count) }
    }

    func testBundledBenchmarkRunsWithTheProductionLayoutTable() throws {
        guard PredictionBenchmark.productionMapping(sourceLanguage: "en") != nil else {
            throw XCTSkip("RU and EN keyboard layouts are not installed")
        }
        let report = try PredictionBenchmark.run(engine: PredictionEngine(lexicon: .bundled()),
                                                 bundle: PredictionResources.bundle())
        XCTAssertEqual(report.layoutMapping, "dynamic")
        XCTAssertTrue(report.passed, "Public case failures: \(report.failureCaseIDs)")
    }

    func testBundledEngineQualityReportOnShippedCorpus() throws {
        let cases = try PredictionBenchmark.Quality.loadCases(from: Self.corpusURL)
        let engine = PredictionEngine(lexicon: try .bundled())
        let report = PredictionBenchmark.Quality.run(engine: engine, cases: cases) {
            PredictionBenchmark.productionMapping(sourceLanguage: $0)
        }
        print("QUALITY_REPORT\n" + PredictionBenchmark.Quality.table(report))
        XCTAssertEqual(report.categories.values.map(\.cases).reduce(0, +), cases.count)
        // Brief: at most 0.5% false corrections on correct text. Measured 0 at this baseline.
        XCTAssertLessThanOrEqual(report.correctTextFalsePositiveRate ?? 1, 0.005)
        XCTAssertEqual(report.layoutMapping, PredictionBenchmark.productionMapping(sourceLanguage: "en") == nil
            ? "static" : "dynamic")
    }
}
