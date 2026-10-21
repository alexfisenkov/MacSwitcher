import XCTest
@testable import RuSwitcher

final class PredictionBenchmarkTests: XCTestCase {
    func testClassifiesEveryOutcomeWithoutLoggingInput() throws {
        let cases = try PredictionBenchmark.decodeCases(Data("""
        {"schema":1,"cases":[
          {"id":"true-positive","input":"ghbdtn","sourceLanguage":"en","atBoundary":false,"precedingWords":[],"expectedReplacement":"привет"},
          {"id":"false-negative","input":"ghb","sourceLanguage":"en","atBoundary":false,"precedingWords":[],"expectedReplacement":"прив"},
          {"id":"false-positive","input":"ghbdtn","sourceLanguage":"en","atBoundary":false,"precedingWords":[],"expectedReplacement":null},
          {"id":"wrong-replacement","input":"ghbdtn","sourceLanguage":"en","atBoundary":false,"precedingWords":[],"expectedReplacement":"здравствуйте"},
          {"id":"true-negative","input":"hello","sourceLanguage":"en","atBoundary":false,"precedingWords":[],"expectedReplacement":null}
        ]}
        """.utf8))
        let engine = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: ["ru": ["привет": 1_000_000], "en": ["hello": 500_000]]))
        let report = try PredictionBenchmark.run(engine: engine, cases: cases)
        XCTAssertEqual(report.goldRevision, 1)
        XCTAssertEqual(report.total, 5)
        XCTAssertEqual(report.expectedCorrection, 3)
        XCTAssertEqual(report.expectedNoChange, 2)
        XCTAssertEqual(report.truePositive, 1)
        XCTAssertEqual(report.falsePositive, 1)
        XCTAssertEqual(report.falseNegative, 1)
        XCTAssertEqual(report.wrongReplacement, 1)
        XCTAssertEqual(report.failureCaseIDs, ["false-negative", "false-positive", "wrong-replacement"])
        XCTAssertFalse(report.passed)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("ghbdtn"))
        XCTAssertFalse(encoded.contains("здравствуйте"))
    }
    func testRejectsInvalidOrMissingGoldAndDuplicateIDs() throws {
        let valid = """
        {"id":"one","input":"hello","sourceLanguage":"en","atBoundary":false,"precedingWords":[],"expectedReplacement":null}
        """
        XCTAssertNoThrow(try PredictionBenchmark.decodeCases(Data("{\"schema\":1,\"cases\":[\(valid)]}".utf8)))
        for invalid in [
            "{\"schema\":2,\"cases\":[\(valid)]}",
            "{\"schema\":1,\"cases\":[]}",
            "{\"schema\":1,\"cases\":[\(valid),\(valid)]}",
            "{\"schema\":1,\"cases\":[" + valid.replacingOccurrences(of: ",\"expectedReplacement\":null", with: "") + "]}",
            "{\"schema\":1,\"cases\":[" + valid.replacingOccurrences(of: "\"en\"", with: "\"de\"") + "]}",
            "{\"schema\":1,\"cases\":[" + valid.replacingOccurrences(of: "\"one\"", with: "\"unsafe case text\"") + "]}",
        ] {
            XCTAssertThrowsError(try PredictionBenchmark.decodeCases(Data(invalid.utf8)))
        }
    }

    func testBundledPublicCorpusHasNoUnexpectedCorrectionsOrMissedGold() throws {
        let report = try PredictionBenchmark.run(engine: PredictionEngine(lexicon: .bundled()),
                                                 bundle: PredictionResources.bundle())
        XCTAssertEqual(report.goldRevision, 2)
        XCTAssertEqual(report.total, 495)
        XCTAssertEqual(report.expectedCorrection, 176)
        XCTAssertEqual(report.expectedNoChange, 319)
        XCTAssertTrue(report.passed, "Public case failures: \(report.failureCaseIDs)")
        print("PREDICTION_BENCHMARK " + String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
    }

}
