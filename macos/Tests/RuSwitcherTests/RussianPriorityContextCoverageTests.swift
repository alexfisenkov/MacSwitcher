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
            XCTAssertNil(engine.appliedProposal(suffix: wrong + " ", sourceLanguage: "en",
                                         atBoundary: true, russianPriority: false), wrong)
            XCTAssertEqual(engine.appliedProposal(suffix: wrong + " ", sourceLanguage: "en",
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
            XCTAssertNil(engine.appliedProposal(suffix: input + " ", sourceLanguage: "en",
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
            XCTAssertNil(engine.appliedProposal(suffix: wrong + " ", sourceLanguage: "en",
                                         atBoundary: true, russianPriority: true), wrong)
            XCTAssertEqual(engine.appliedProposal(suffix: wrong + " ghbdtn ", sourceLanguage: "en",
                                           atBoundary: true, russianPriority: true)?.replacementSuffix,
                           expected + " привет ", wrong)
            XCTAssertEqual(engine.appliedProposal(suffix: wrong + " ghbdtn ", sourceLanguage: "en",
                                           atBoundary: true, russianPriority: false)?.replacementSuffix,
                           wrong + " привет ", wrong)
        }
        XCTAssertEqual(engine.appliedProposal(suffix: "ns ljvf ", sourceLanguage: "en",
                                       atBoundary: true, russianPriority: true)?.replacementSuffix,
                       "ты дома ")
        XCTAssertEqual(engine.appliedProposal(suffix: "vs hf,jnftv ", sourceLanguage: "en",
                                       atBoundary: true, russianPriority: true)?.replacementSuffix,
                       "мы работаем ")
    }

    func testContextRepairRejectsLiteralRussianEnglishAndMappingMismatch() throws {
        let engine = try engine()
        XCTAssertNil(engine.appliedProposal(suffix: "vs привет ", sourceLanguage: "en",
                                     atBoundary: true, russianPriority: true))
        for word in ["vs", "here", "keyboard", "MacSwitcher"] {
            XCTAssertNil(engine.appliedProposal(suffix: word + " ", sourceLanguage: "en",
                                         atBoundary: true, russianPriority: true), word)
        }
        for context in ["press", "script", "hello"] {
            XCTAssertEqual(engine.appliedProposal(suffix: context + " vs ghbdtn ", sourceLanguage: "en",
                                           atBoundary: true, russianPriority: true)?.replacementSuffix,
                           context + " vs привет ", context)
        }
        XCTAssertEqual(engine.appliedProposal(suffix: "MacSwitcher vs ghbdtn ", sourceLanguage: "en",
            atBoundary: true, russianPriority: true)?.replacementSuffix, "MacSwitcher мы привет ")
        var mismatched = KeyMapping.enToRu
        mismatched["v"] = "н"
        XCTAssertEqual(engine.appliedProposal(suffix: "vs ghbdtn ", sourceLanguage: "en",
                                       atBoundary: true, characterMapping: mismatched,
                                       russianPriority: true)?.replacementSuffix,
                       "vs привет ")
    }

    func testBundledNamesDoNotSuppressFollowingRussianPriority() throws {
        let engine = try engine()
        for name in ["MacSwitcher", "ChatGPT", "Figma", "iPhone", "Apple"] {
            for (typed, expected) in [("f", "а"), ("ye", "ну"), ("yt", "не"), ("b", "и")] {
                XCTAssertEqual(engine.appliedProposal(suffix: typed, sourceLanguage: "en",
                    precedingWords: [name], russianPriority: true)?.replacementSuffix, expected,
                    "\(name) \(typed) early")
                XCTAssertEqual(engine.appliedProposal(suffix: typed + " ", sourceLanguage: "en",
                    atBoundary: true, precedingWords: [name], russianPriority: true)?.replacementSuffix,
                    expected + " ", "\(name) \(typed) boundary")
                XCTAssertEqual(engine.appliedProposal(suffix: name + ", " + typed, sourceLanguage: "en",
                    russianPriority: true)?.replacementSuffix, name + ", " + expected,
                    "\(name) \(typed) suffix")
            }
            XCTAssertEqual(engine.appliedProposal(suffix: "f yt", sourceLanguage: "en",
                precedingWords: [name], russianPriority: true)?.replacementSuffix, "а не", name)
            XCTAssertNil(engine.appliedProposal(suffix: name + " ", sourceLanguage: "en",
                atBoundary: true, russianPriority: true), "name itself must stay protected")
        }
    }

    func testRussianContextResetsEarlierEnglishAndNeedsTwoOrdinaryEnglishWordsToReturn() throws {
        let engine = try engine()
        let accepted = [["hello", "привет"], ["hello", "привет", "world"],
            ["привет", "MacSwitcher"], ["MacSwitcher", "привет"]]
        for context in accepted {
            XCTAssertEqual(engine.appliedProposal(suffix: "f", sourceLanguage: "en",
                precedingWords: context, russianPriority: true)?.replacementSuffix, "а", context.joined(separator: " "))
        }
        for context in [["hello"], ["press"], ["привет", "hello", "world"], ["iWidget"]] {
            XCTAssertNil(engine.appliedProposal(suffix: "f", sourceLanguage: "en",
                precedingWords: context, russianPriority: true), context.joined(separator: " "))
        }
    }

    func testLowercaseFrequentHomographsRemainEnglishEvidence() throws {
        let engine = try engine()
        for word in ["long", "together", "red", "line", "apple"] {
            XCTAssertNil(engine.appliedProposal(suffix: "f", sourceLanguage: "en",
                precedingWords: [word], russianPriority: true), word)
        }
        XCTAssertEqual(engine.appliedProposal(suffix: "f", sourceLanguage: "en",
            precedingWords: ["использую", "apple"], russianPriority: true)?.replacementSuffix,
            "а")
        XCTAssertEqual(engine.appliedProposal(suffix: "f", sourceLanguage: "en",
            precedingWords: ["Apple"], russianPriority: true)?.replacementSuffix, "а")
    }

    func testProtectedSourceTermBlocksContextRepair() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["ru": ["привет": 177_992]],
            protectedTermsByLanguage: ["en": ["ns"]])
        let engine = PredictionEngine(lexicon: lexicon)
        XCTAssertEqual(engine.appliedProposal(suffix: "ns ghbdtn ", sourceLanguage: "en",
                                       atBoundary: true, russianPriority: true)?.replacementSuffix,
                       "ns привет ")
    }
}
