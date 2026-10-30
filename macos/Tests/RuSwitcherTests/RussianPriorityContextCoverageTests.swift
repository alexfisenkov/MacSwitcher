import XCTest
@testable import RuSwitcher

final class RussianPriorityContextCoverageTests: XCTestCase {
    private static let bundledResult = Result { try PredictionLexicon.bundled() }

    private func engine() throws -> PredictionEngine {
        PredictionEngine(lexicon: try Self.bundledResult.get())
    }

    func testAdjacentPhysicalPunctuationCanCompleteStrongRussianWordOnlyWithPriority() throws {
        let engine = try engine()
        let examples = [
            "k.,bn": "любит", "k.,bim": "любишь", "k.,db": "любви",
            "k.,jq": "любой", "k.,jv": "любом"
        ]
        for (wrong, expected) in examples {
            XCTAssertNil(engine.evaluate(suffix: wrong + " ", sourceLanguage: "en",
                                         atBoundary: true, russianPriority: false), wrong)
            XCTAssertEqual(engine.evaluate(suffix: wrong + " ", sourceLanguage: "en",
                                           atBoundary: true, russianPriority: true)?.replacementSuffix,
                           expected + " ", wrong)
        }
    }

    func testPunctuationExceptionPreservesTechnicalShapesAndEnglishContext() throws {
        let engine = try engine()
        let negatives = [
            "k.lb", "c.lf", "foo.com", "www.example.org", "cj,bhf.cm", ",j.cm",
            "f,cjk.nyj", "user@k.,bn", "https://k.,bn", "/tmp/k.,bn", "k.,bn123",
            "press k.,bn", "script k.,bn", "hello k.,bn", "domain k.,bn",
            "url k.,bn", "foo,k.lb"
        ]
        for input in negatives {
            XCTAssertNil(engine.evaluate(suffix: input + " ", sourceLanguage: "en",
                                         atBoundary: true, russianPriority: true), input)
        }
    }

    func testContextualWordsNeedCorrectedFollowingRussianEvidence() throws {
        let engine = try engine()
        let examples = [
            "ns": "ты", "jy": "он", "vs": "мы", "ds": "вы", "dct": "все",
            "dfc": "вас", "jn": "от", "yfi": "наш", "vbh": "мир", "yb": "ни", "fuf": "ага"
        ]
        for (wrong, expected) in examples {
            XCTAssertNil(engine.evaluate(suffix: wrong + " ", sourceLanguage: "en",
                                         atBoundary: true, russianPriority: true), wrong)
            XCTAssertEqual(engine.evaluate(suffix: wrong + " ghbdtn ", sourceLanguage: "en",
                                           atBoundary: true, russianPriority: true)?.replacementSuffix,
                           expected + " привет ", wrong)
            XCTAssertEqual(engine.evaluate(suffix: wrong + " ghbdtn ", sourceLanguage: "en",
                                           atBoundary: true, russianPriority: false)?.replacementSuffix,
                           wrong + " привет ", wrong)
        }
        XCTAssertEqual(engine.evaluate(suffix: "ns ljvf ", sourceLanguage: "en",
                                       atBoundary: true, russianPriority: true)?.replacementSuffix,
                       "ты дома ")
        XCTAssertEqual(engine.evaluate(suffix: "vs hf,jnftv ", sourceLanguage: "en",
                                       atBoundary: true, russianPriority: true)?.replacementSuffix,
                       "мы работаем ")
    }

    func testContextRepairRejectsLiteralRussianEnglishAndMappingMismatch() throws {
        let engine = try engine()
        XCTAssertNil(engine.evaluate(suffix: "vs привет ", sourceLanguage: "en",
                                     atBoundary: true, russianPriority: true))
        for word in ["vs", "here", "keyboard", "MacSwitcher"] {
            XCTAssertNil(engine.evaluate(suffix: word + " ", sourceLanguage: "en",
                                         atBoundary: true, russianPriority: true), word)
        }
        for context in ["press", "script", "hello", "MacSwitcher"] {
            XCTAssertEqual(engine.evaluate(suffix: context + " vs ghbdtn ", sourceLanguage: "en",
                                           atBoundary: true, russianPriority: true)?.replacementSuffix,
                           context + " vs привет ", context)
        }
        var mismatched = KeyMapping.enToRu
        mismatched["v"] = "н"
        XCTAssertEqual(engine.evaluate(suffix: "vs ghbdtn ", sourceLanguage: "en",
                                       atBoundary: true, characterMapping: mismatched,
                                       russianPriority: true)?.replacementSuffix,
                       "vs привет ")
    }

    func testProtectedSourceTermBlocksContextRepair() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["ru": ["привет": 177_992]],
            protectedTermsByLanguage: ["en": ["ns"]])
        let engine = PredictionEngine(lexicon: lexicon)
        XCTAssertEqual(engine.evaluate(suffix: "ns ghbdtn ", sourceLanguage: "en",
                                       atBoundary: true, russianPriority: true)?.replacementSuffix,
                       "ns привет ")
    }
}
