import XCTest
@testable import RuSwitcher

final class PredictionEngineTests: XCTestCase {
    private func fixture() -> PredictionLexicon {
        PredictionLexicon(wordsByLanguage: [
            "ru": ["привет": 1_000_000, "приветствие": 80_000, "привычка": 60_000,
                   "думаю": 800_000, "думать": 700_000, "что-то": 600_000,
                   "кажется": 900_000, "нет": 2_000_000, "могу": 900_000,
                   "пожалуйста": 400_000, "а": 8_000_000, "и": 10_000_000,
                   "нажми": 50_000, "это": 5_000_000, "не": 5_000_000],
            "en": ["hello": 900_000, "help": 500_000, "helmet": 50_000,
                   "the": 8_000_000, "press": 500_000, "cat": 200_000,
                   "rareword": 1, "f": 20_000]
        ])
    }

    private func engine() -> PredictionEngine { PredictionEngine(lexicon: fixture()) }

    func testCorrectsBeforeSpaceForStrongCompletedWord() throws {
        let result = try XCTUnwrap(engine().evaluate(suffix: "ghbdtn", sourceLanguage: "en"))
        XCTAssertEqual(result.originalSuffix, "ghbdtn")
        XCTAssertEqual(result.replacementSuffix, "привет")
        XCTAssertEqual(result.targetLanguage, "ru")
    }

    func testStrongTargetPrefixCanSwitchBeforeWordCompleted() throws {
        let result = try XCTUnwrap(engine().evaluate(suffix: "ghbd", sourceLanguage: "en"))
        XCTAssertEqual(result.replacementSuffix, "прив")
        XCTAssertNil(engine().evaluate(suffix: "ghb", sourceLanguage: "en"))
    }

    func testExplicitNonQWERTYMappingDeterminesActualReplacement() throws {
        let rendered = "hpinuv"
        let custom: [Character: Character] = ["h": "п", "p": "р", "i": "и", "n": "в", "u": "е", "v": "т"]
        XCTAssertNil(engine().evaluate(suffix: rendered, sourceLanguage: "en"))
        let proposal = try XCTUnwrap(engine().evaluate(suffix: rendered, sourceLanguage: "en", characterMapping: custom))
        XCTAssertEqual(proposal.originalSuffix, rendered)
        XCTAssertEqual(proposal.replacementSuffix, "привет")
        XCTAssertEqual(engine().evaluate(suffix: rendered + "! ", sourceLanguage: "en", atBoundary: true,
                                         characterMapping: custom)?.replacementSuffix, "привет! ")
    }

    func testExplicitIncompleteOrEmptyMappingFailsClosedIncludingOverrides() {
        let partial: [Character: Character] = ["h": "п", "p": "р", "i": "и", "n": "в", "u": "е"]
        XCTAssertNil(engine().evaluate(suffix: "hpinuv", sourceLanguage: "en", characterMapping: partial))
        XCTAssertNil(engine().evaluate(suffix: "hpinuv", sourceLanguage: "en", atBoundary: true,
                                       alwaysConvertWords: ["привеv"], characterMapping: partial))
        XCTAssertNil(engine().evaluate(suffix: "ghbdtn", sourceLanguage: "en", characterMapping: [:]))
        XCTAssertNil(engine().evaluate(suffix: "f ", sourceLanguage: "en", atBoundary: true,
                                       alwaysConvertWords: ["а"], characterMapping: ["f": "и"]))
    }

    func testExplicitLayoutMappingMustConfirmDeferredFMeansRussianA() {
        XCTAssertNil(engine().evaluate(suffix: "f привет", sourceLanguage: "en", characterMapping: ["f": "и"]))
        XCTAssertNil(engine().evaluate(suffix: "f привет", sourceLanguage: "ru", characterMapping: ["а": "x"]))
        XCTAssertEqual(engine().evaluate(suffix: "f привет", sourceLanguage: "en", characterMapping: ["f": "а"])?.replacementSuffix,
                       "а привет")
        XCTAssertEqual(engine().evaluate(suffix: "f привет", sourceLanguage: "ru", characterMapping: ["а": "f"])?.replacementSuffix,
                       "а привет")
    }

    func testEnglishDirectionAndTitleCase() throws {
        XCTAssertEqual(engine().evaluate(suffix: "руддщ", sourceLanguage: "ru")?.replacementSuffix, "hello")
        XCTAssertEqual(engine().evaluate(suffix: "Ghbdtn", sourceLanguage: "en-US")?.replacementSuffix, "Привет")
    }

    func testPunctuationKeyAtWordEndRemainsRussianLetter() throws {
        let proposal = try XCTUnwrap(engine().evaluate(suffix: "levf.", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(proposal.replacementSuffix, "думаю")
    }

    func testHyphenatedWordAndTrailingLiteralWhitespace() throws {
        let proposal = try XCTUnwrap(engine().evaluate(suffix: "xnj-nj  ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(proposal.originalSuffix, "xnj-nj  ")
        XCTAssertEqual(proposal.replacementSuffix, "что-то  ")
    }

    func testCorrectsCurrentWordWithoutChangingOtherTokens() {
        XCTAssertEqual(engine().evaluate(suffix: "hello ghbdtn ", sourceLanguage: "en", atBoundary: true)?.replacementSuffix,
                       "hello привет ")
    }

    func testDefersSingleLetterUntilFollowingRussianWord() throws {
        XCTAssertNil(engine().evaluate(suffix: "f", sourceLanguage: "en"))
        XCTAssertNil(engine().evaluate(suffix: "f ", sourceLanguage: "en", atBoundary: true))
        let proposal = try XCTUnwrap(engine().evaluate(suffix: "f привет", sourceLanguage: "ru"))
        XCTAssertEqual(proposal.replacementSuffix, "а привет")
        XCTAssertEqual(proposal.reason, .contextWord)
        XCTAssertEqual(proposal.targetLanguage, "ru")
    }

    func testDeferredLetterAndFollowingWrongLayoutWordCorrectTogether() throws {
        let proposal = try XCTUnwrap(engine().evaluate(suffix: "f  ghbdtn ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(proposal.originalSuffix, "f  ghbdtn ")
        XCTAssertEqual(proposal.replacementSuffix, "а  привет ")
    }

    func testUnknownOrShortFollowingWordDoesNotResolveLetter() {
        for suffix in ["f я", "f не", "f xyzzy", "f hello", "f ghb"] {
            XCTAssertNil(engine().evaluate(suffix: suffix, sourceLanguage: "en"), suffix)
        }
    }

    func testTechnicalPrecedingContextProtectsLetter() {
        for cue in ["press", "нажми", "нажмите", "клавиша", "клавишу", "буква", "символ"] {
            XCTAssertNil(engine().evaluate(suffix: "f привет", sourceLanguage: "ru", precedingWords: [cue]), cue)
            XCTAssertNil(engine().evaluate(suffix: cue + " f привет", sourceLanguage: "ru"), cue)
        }
    }

    func testTechnicalCueOnlyProtectsLetterNotWrongNextWord() {
        XCTAssertEqual(engine().evaluate(suffix: "f ghbdtn", sourceLanguage: "en", precedingWords: ["press"])?.replacementSuffix,
                       "f привет")
    }

    func testUppercaseOrQuotedSymbolDoesNotResolveAsConjunction() {
        for prefix in ["F", "'f'", "\"f\"", "f(x)", "Ctrl+f"] {
            XCTAssertNil(engine().evaluate(suffix: prefix + " привет", sourceLanguage: "ru"), prefix)
        }
    }

    func testProtectsKnownEnglishIncludingRareDictionaryEntry() {
        for word in ["hello", "help", "rareword", "cat"] {
            XCTAssertNil(engine().evaluate(suffix: word, sourceLanguage: "en", atBoundary: true), word)
        }
        let collision = PredictionLexicon(wordsByLanguage: ["en": ["ghbdtn": 1], "ru": ["привет": 900_000]])
        XCTAssertNil(PredictionEngine(lexicon: collision).evaluate(suffix: "ghbdtn", sourceLanguage: "en", atBoundary: true))
    }

    func testContextReplacementPreservesEarlierUnicodeAndLiteralWhitespace() throws {
        let result = try XCTUnwrap(engine().evaluate(suffix: "🙂 f  ghbdtn  ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(result.replacementSuffix, "🙂 а  привет  ")
    }

    func testLanguageAliasesMergeInsteadOfCrashing() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["en": ["hello": 20], "en-US": ["world": 30]])
        XCTAssertEqual(lexicon.frequency(of: "hello", language: "en"), 20)
        XCTAssertEqual(lexicon.frequency(of: "world", language: "en"), 30)
    }

    func testOnlyLettersFromConfiguredScriptsCanBecomeCandidates() {
        XCTAssertNil(engine().evaluate(suffix: "♥♥♥♥", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine().evaluate(suffix: String(repeating: "g", count: 513), sourceLanguage: "en"))
    }

    func testOwnerTargetOverrideWorksOnlyAtBoundary() {
        XCTAssertNil(engine().evaluate(suffix: "f", sourceLanguage: "en", alwaysConvertWords: ["а"]))
        XCTAssertEqual(engine().evaluate(suffix: "f ", sourceLanguage: "en", atBoundary: true,
                                         alwaysConvertWords: ["а"])?.replacementSuffix, "а ")
        let collision = PredictionLexicon(wordsByLanguage: ["en": ["ghbdtn": 10], "ru": [:]])
        XCTAssertEqual(PredictionEngine(lexicon: collision).evaluate(suffix: "ghbdtn", sourceLanguage: "en",
            atBoundary: true, alwaysConvertWords: ["привет"])?.replacementSuffix, "привет")
    }

    func testProtectsTechnicalTokens() {
        for word in ["API", "GPT", "AI", "HTTP", "MacSwitcher", "iPhone", "fooBar", "f(x)",
                     "fisenkov.ru", "foo.com", "user@example.com", "https://example.org", "/tmp/ghbdtn",
                     "C:\\Temp\\ghbdtn", "ghbdtn_foo", "ghbdtn123", "ghбdtn"] {
            XCTAssertNil(engine().evaluate(suffix: word, sourceLanguage: "en", atBoundary: true), word)
        }
    }

    func testProtectsUnknownSourceAndCrossLineContext() {
        XCTAssertNil(engine().evaluate(suffix: "ghbdtn", sourceLanguage: "de"))
        XCTAssertNil(engine().evaluate(suffix: "f\nпривет", sourceLanguage: "ru"))
    }

    func testEnglishPrefixWinsEvenWhenTargetPrefixStrong() {
        let ambiguous = PredictionLexicon(wordsByLanguage: ["en": ["ghbdmore": 500_000], "ru": ["привет": 1_000_000]])
        XCTAssertNil(PredictionEngine(lexicon: ambiguous).evaluate(suffix: "ghbd", sourceLanguage: "en"))
    }

    func testLexiconCaseNormalizationAndPrefixFrequency() {
        let lexicon = fixture()
        XCTAssertEqual(lexicon.frequency(of: "ПРИВЕТ", language: "ru-RU"), 1_000_000)
        let prefix = lexicon.prefixEvidence(for: "при", language: "ru")
        XCTAssertEqual(prefix.maximumFrequency, 1_000_000)
        XCTAssertEqual(prefix.completions, 3)
        XCTAssertEqual(lexicon.prefixEvidence(for: "missing", language: "en").completions, 0)
    }

    func testTSVParserRejectsInvalidCountsAndCombinesDuplicates() throws {
        let lexicon = try PredictionLexicon(tsvByLanguage: ["en": "hello\t20\nHELLO\t40\n\n", "ru": "привет\t70\n"])
        XCTAssertEqual(lexicon.frequency(of: "hello", language: "en"), 40)
        XCTAssertThrowsError(try PredictionLexicon(tsvByLanguage: ["en": "hello\tnan"]))
        XCTAssertThrowsError(try PredictionLexicon(tsvByLanguage: ["en": "hello\t-1"]))
    }

    func testBundledDictionariesActuallyLoadUserRegressions() throws {
        let lexicon = try PredictionLexicon.bundled()
        XCTAssertGreaterThanOrEqual(lexicon.wordCounts["ru"] ?? 0, 100_000)
        XCTAssertGreaterThanOrEqual(lexicon.wordCounts["en"] ?? 0, 100_000)
        XCTAssertGreaterThan(lexicon.frequency(of: "привет", language: "ru"), 0)
        XCTAssertGreaterThan(lexicon.frequency(of: "что-то", language: "ru"), 0)
        let realEngine = PredictionEngine(lexicon: lexicon)
        XCTAssertEqual(realEngine.evaluate(suffix: "ghbd", sourceLanguage: "en")?.replacementSuffix, "прив")
        XCTAssertEqual(realEngine.evaluate(suffix: "ghbdtn", sourceLanguage: "en")?.replacementSuffix, "привет")
        XCTAssertEqual(realEngine.evaluate(suffix: "levf.", sourceLanguage: "en", atBoundary: true)?.replacementSuffix, "думаю")
        XCTAssertEqual(realEngine.evaluate(suffix: "xnj-nj", sourceLanguage: "en", atBoundary: true)?.replacementSuffix, "что-то")
    }
}
