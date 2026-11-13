import XCTest
@testable import RuSwitcher

final class RussianPriorityPunctuationTests: XCTestCase {
    private func engine(sourceWords: Set<String> = [], targetWords: Set<String> = ["крин", "кринж"],
                        fullSource: [String: Int] = [:], sourceFrequency: [String: Int] = [:]) -> PredictionEngine {
        PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: ["en": sourceFrequency],
            fullWordsByLanguage: ["en": fullSource],
            spellingWordsByLanguage: ["en": sourceWords, "ru": targetWords]))
    }

    func testRussianPriorityResolvesExactTerminalSemicolonCollisionAtBoundary() {
        let policy = engine()
        XCTAssertNil(policy.evaluate(suffix: "rhby; ", sourceLanguage: "en", atBoundary: true,
                                     russianPriority: false))
        XCTAssertEqual(policy.evaluate(suffix: "rhby; ", sourceLanguage: "en", atBoundary: true,
                                       russianPriority: true)?.replacementSuffix, "кринж ")
        XCTAssertNil(policy.evaluate(suffix: "rhby;", sourceLanguage: "en", russianPriority: true))
    }

    func testSourceAndTechnicalProtectionStillRefusePriority() {
        let input = "rhby; "
        XCTAssertNil(engine(sourceWords: ["rhby"]).evaluate(suffix: input, sourceLanguage: "en",
            atBoundary: true, russianPriority: true))
        XCTAssertNil(engine(sourceFrequency: ["rhby": 1]).evaluate(suffix: input,
            sourceLanguage: "en", atBoundary: true, russianPriority: true))
        XCTAssertNil(engine(fullSource: ["rhby": 1]).evaluate(suffix: input,
            sourceLanguage: "en", atBoundary: true, russianPriority: true))
        XCTAssertNil(engine().evaluate(suffix: input, sourceLanguage: "en", atBoundary: true,
            precedingWords: ["code"], russianPriority: true))
        for token in ["RHBY;", "rhby;123", "rhby;_", "rhby;/path", "https://rhby;", "@rhby;"] {
            XCTAssertNil(engine().evaluate(suffix: token + " ", sourceLanguage: "en",
                atBoundary: true, russianPriority: true), token)
        }
    }

    func testPriorityDoesNotGeneralizeToOtherPunctuationOrLiteralOnlyMatches() {
        let policy = engine()
        XCTAssertNil(policy.evaluate(suffix: "rhby` ", sourceLanguage: "en", atBoundary: true,
            russianPriority: true))
        XCTAssertNil(policy.evaluate(suffix: "rhby' ", sourceLanguage: "en", atBoundary: true,
            russianPriority: true))
        XCTAssertNil(engine(targetWords: ["крин", "кринжж"]).evaluate(
            suffix: "rhby;; ", sourceLanguage: "en", atBoundary: true, russianPriority: true))
        XCTAssertNil(engine(targetWords: ["крин", "криню"]).evaluate(
            suffix: "rhby. ", sourceLanguage: "en", atBoundary: true, russianPriority: true))
        XCTAssertEqual(engine(targetWords: ["крин"]).evaluate(
            suffix: "rhby; ", sourceLanguage: "en", atBoundary: true,
            russianPriority: true)?.replacementSuffix, "крин; ")
    }

    func testExistingPunctuationDecisionsStayUnchanged() {
        XCTAssertEqual(engine(targetWords: ["привет"]).evaluate(
            suffix: "ghbdtn; ", sourceLanguage: "en", atBoundary: true,
            russianPriority: true)?.replacementSuffix, "привет; ")
        XCTAssertNil(engine(targetWords: ["дума", "думаю"]).evaluate(
            suffix: "levf. ", sourceLanguage: "en", atBoundary: true, russianPriority: true))
        XCTAssertEqual(engine(targetWords: ["думаю"]).evaluate(
            suffix: "levf. ", sourceLanguage: "en", atBoundary: true,
            russianPriority: true)?.replacementSuffix, "думаю ")
    }
}
