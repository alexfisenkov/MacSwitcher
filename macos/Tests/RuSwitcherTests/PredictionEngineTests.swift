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

    func testAdaptiveBoundaryAndPreferredPrefix() {
        let custom = AdaptiveRule(pair: AdaptiveWordPair(ru: "фис", en: "abc"),
            preferred: "ru", confirmations: 2, confirmedAt: Date(), lastOccurrenceID: UUID())
        let candidate = AdaptiveRule(pair: custom.pair, preferred: "ru", confirmations: 1,
            confirmedAt: Date(), lastOccurrenceID: UUID())
        XCTAssertNil(engine().appliedProposal(suffix: "abc", sourceLanguage: "en",
            adaptiveRules: [custom]))
        XCTAssertEqual(engine().appliedProposal(suffix: "abc ", sourceLanguage: "en", atBoundary: true,
            adaptiveRules: [custom])?.replacementSuffix, "фис ")
        XCTAssertEqual(engine().appliedProposal(suffix: "abc ", sourceLanguage: "ru", atBoundary: true,
            adaptiveRules: [custom])?.replacementSuffix, "фис ")
        XCTAssertEqual(engine().appliedProposal(suffix: "abc ", sourceLanguage: "ru", atBoundary: true,
            adaptiveRules: [custom])?.targetLanguage, "ru")
        XCTAssertNil(engine().appliedProposal(suffix: "abc ", sourceLanguage: "en", atBoundary: true,
            adaptiveRules: [candidate]))
        XCTAssertNil(engine().appliedProposal(suffix: "abc ", sourceLanguage: "ru", atBoundary: true,
            adaptiveRules: [candidate]))
        XCTAssertNil(engine().appliedProposal(suffix: "ABC ", sourceLanguage: "ru", atBoundary: true,
            adaptiveRules: [custom]))
        XCTAssertNil(engine().appliedProposal(suffix: "abc/path ", sourceLanguage: "ru", atBoundary: true,
            adaptiveRules: [custom]))
        let protected = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: [:],
            protectedTermsByLanguage: ["en": ["abc"]]))
        XCTAssertNil(protected.appliedProposal(suffix: "abc ", sourceLanguage: "ru", atBoundary: true,
            adaptiveRules: [custom]))
        let reverse = AdaptiveRule(pair: custom.pair, preferred: "en", confirmations: 2,
            confirmedAt: Date(), lastOccurrenceID: UUID())
        XCTAssertEqual(engine().appliedProposal(suffix: "фис ", sourceLanguage: "en", atBoundary: true,
            adaptiveRules: [reverse])?.replacementSuffix, "abc ")
        XCTAssertEqual(engine().appliedProposal(suffix: "фис ", sourceLanguage: "en", atBoundary: true,
            adaptiveRules: [reverse])?.targetLanguage, "en")
        let preferredEnglish = AdaptiveRule(pair: AdaptiveWordPair(ru: "привет", en: "ghbdtn"),
            preferred: "en", confirmations: 2, confirmedAt: Date(), lastOccurrenceID: UUID())
        XCTAssertNil(engine().appliedProposal(suffix: "ghbd", sourceLanguage: "en",
            adaptiveRules: [preferredEnglish]))
        XCTAssertNil(engine().appliedProposal(suffix: "ghbdtn ", sourceLanguage: "en", atBoundary: true,
            adaptiveRules: [preferredEnglish]))
        XCTAssertEqual(engine().appliedProposal(suffix: "ghbdtn ", sourceLanguage: "en", atBoundary: true,
            alwaysConvertWords: ["привет"], adaptiveRules: [preferredEnglish])?.replacementSuffix,
            "привет ")
    }

    func testRussianPriorityImmediatelyCorrectsCommonSingleLetterWords() {
        let examples: [(String, String)] = [
            ("f", "а"), ("b", "и"), ("d", "в"), ("r", "к"),
            ("c", "с"), ("e", "у"), ("j", "о"), ("z", "я")
        ]
        for (typed, expected) in examples {
            let result = engine().appliedProposal(suffix: typed, sourceLanguage: "en",
                                           russianPriority: true)
            XCTAssertEqual(result?.replacementSuffix, expected, typed)
            XCTAssertEqual(result?.targetLanguage, "ru", typed)
        }
        XCTAssertNil(engine().appliedProposal(suffix: "f", sourceLanguage: "en",
                                       russianPriority: false))
    }

    func testRussianPriorityCorrectsNeutralShortPhraseBeforeBoundary() {
        XCTAssertEqual(engine().appliedProposal(suffix: "f yt", sourceLanguage: "en",
                                       russianPriority: true)?.replacementSuffix, "а не")
    }

    func testRussianPriorityKeepsUnknownCamelCaseAndEnglishContextProtected() {
        for preceding in ["iWidget", "hello", "press"] {
            XCTAssertNil(engine().appliedProposal(suffix: "f", sourceLanguage: "en",
                                           precedingWords: [preceding], russianPriority: true), preceding)
        }
    }

    func testFixtureNeutralEntityDoesNotWeakenWordAndAbbreviationProtection() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["ru": ["а": 8_000_000],
            "en": ["hello": 900_000]], protectedTermsByLanguage: ["en": ["token", "api"]],
            neutralContextEntitiesByLanguage: ["en": ["iPhone"]])
        let engine = PredictionEngine(lexicon: lexicon)
        XCTAssertEqual(engine.appliedProposal(suffix: "f", sourceLanguage: "en",
            precedingWords: ["iPhone"], russianPriority: true)?.replacementSuffix, "а")
        for context in ["token", "API", "hello", "press", "iWidget"] {
            XCTAssertNil(engine.appliedProposal(suffix: "f", sourceLanguage: "en",
                precedingWords: [context], russianPriority: true), context)
        }
        XCTAssertNil(engine.appliedProposal(suffix: "iPhone ", sourceLanguage: "en",
            atBoundary: true, russianPriority: true))
    }

    func testCorrectsBeforeSpaceForStrongCompletedWord() throws {
        let result = try XCTUnwrap(engine().appliedProposal(suffix: "ghbdtn", sourceLanguage: "en"))
        XCTAssertEqual(result.originalSuffix, "ghbdtn")
        XCTAssertEqual(result.replacementSuffix, "привет")
        XCTAssertEqual(result.targetLanguage, "ru")
    }

    func testStrongTargetPrefixCanSwitchBeforeWordCompleted() throws {
        let result = try XCTUnwrap(engine().appliedProposal(suffix: "ghbd", sourceLanguage: "en"))
        XCTAssertEqual(result.replacementSuffix, "прив")
        XCTAssertNil(engine().appliedProposal(suffix: "ghb", sourceLanguage: "en"))
    }

    func testExplicitNonQWERTYMappingDeterminesActualReplacement() throws {
        let rendered = "hpinuv"
        let custom: [Character: Character] = ["h": "п", "p": "р", "i": "и", "n": "в", "u": "е", "v": "т"]
        XCTAssertNil(engine().appliedProposal(suffix: rendered, sourceLanguage: "en"))
        let proposal = try XCTUnwrap(engine().appliedProposal(suffix: rendered, sourceLanguage: "en", characterMapping: custom))
        XCTAssertEqual(proposal.originalSuffix, rendered)
        XCTAssertEqual(proposal.replacementSuffix, "привет")
        XCTAssertEqual(engine().appliedProposal(suffix: rendered + "! ", sourceLanguage: "en", atBoundary: true,
                                         characterMapping: custom)?.replacementSuffix, "привет! ")
    }

    func testExplicitIncompleteOrEmptyMappingFailsClosedIncludingOverrides() {
        let partial: [Character: Character] = ["h": "п", "p": "р", "i": "и", "n": "в", "u": "е"]
        XCTAssertNil(engine().appliedProposal(suffix: "hpinuv", sourceLanguage: "en", characterMapping: partial))
        XCTAssertNil(engine().appliedProposal(suffix: "hpinuv", sourceLanguage: "en", atBoundary: true,
                                       alwaysConvertWords: ["привеv"], characterMapping: partial))
        XCTAssertNil(engine().appliedProposal(suffix: "ghbdtn", sourceLanguage: "en", characterMapping: [:]))
        XCTAssertNil(engine().appliedProposal(suffix: "f ", sourceLanguage: "en", atBoundary: true,
                                       alwaysConvertWords: ["а"], characterMapping: ["f": "и"]))
    }

    func testExplicitLayoutMappingMustConfirmDeferredFMeansRussianA() {
        XCTAssertNil(engine().appliedProposal(suffix: "f привет", sourceLanguage: "en", characterMapping: ["f": "и"]))
        XCTAssertNil(engine().appliedProposal(suffix: "f привет", sourceLanguage: "ru", characterMapping: ["а": "x"]))
        XCTAssertEqual(engine().appliedProposal(suffix: "f привет", sourceLanguage: "en", characterMapping: ["f": "а"])?.replacementSuffix,
                       "а привет")
        XCTAssertEqual(engine().appliedProposal(suffix: "f привет", sourceLanguage: "ru", characterMapping: ["а": "f"])?.replacementSuffix,
                       "а привет")
    }

    func testEnglishDirectionAndTitleCase() throws {
        XCTAssertEqual(engine().appliedProposal(suffix: "руддщ", sourceLanguage: "ru")?.replacementSuffix, "hello")
        XCTAssertEqual(engine().appliedProposal(suffix: "Ghbdtn", sourceLanguage: "en-US")?.replacementSuffix, "Привет")
    }

    func testPunctuationKeyAtWordEndRemainsRussianLetter() throws {
        let proposal = try XCTUnwrap(engine().appliedProposal(suffix: "levf.", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(proposal.replacementSuffix, "думаю")
    }

    func testHyphenatedWordAndTrailingLiteralWhitespace() throws {
        let proposal = try XCTUnwrap(engine().appliedProposal(suffix: "xnj-nj  ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(proposal.originalSuffix, "xnj-nj  ")
        XCTAssertEqual(proposal.replacementSuffix, "что-то  ")
    }

    func testCorrectsCurrentWordWithoutChangingOtherTokens() {
        XCTAssertEqual(engine().appliedProposal(suffix: "hello ghbdtn ", sourceLanguage: "en", atBoundary: true)?.replacementSuffix,
                       "hello привет ")
    }

    func testDefersSingleLetterUntilFollowingRussianWord() throws {
        XCTAssertNil(engine().appliedProposal(suffix: "f", sourceLanguage: "en"))
        XCTAssertNil(engine().appliedProposal(suffix: "f ", sourceLanguage: "en", atBoundary: true))
        let proposal = try XCTUnwrap(engine().appliedProposal(suffix: "f привет", sourceLanguage: "ru"))
        XCTAssertEqual(proposal.replacementSuffix, "а привет")
        XCTAssertEqual(proposal.reason, .contextWord)
        XCTAssertEqual(proposal.targetLanguage, "ru")
    }

    func testDeferredLetterAndFollowingWrongLayoutWordCorrectTogether() throws {
        let proposal = try XCTUnwrap(engine().appliedProposal(suffix: "f  ghbdtn ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(proposal.originalSuffix, "f  ghbdtn ")
        XCTAssertEqual(proposal.replacementSuffix, "а  привет ")
    }

    func testUnknownOrShortFollowingWordDoesNotResolveLetter() {
        for suffix in ["f я", "f не", "f xyzzy", "f hello", "f ghb"] {
            XCTAssertNil(engine().appliedProposal(suffix: suffix, sourceLanguage: "en"), suffix)
        }
    }

    func testTechnicalPrecedingContextProtectsLetter() {
        for cue in ["press", "нажми", "нажмите", "клавиша", "клавишу", "буква", "символ"] {
            XCTAssertNil(engine().appliedProposal(suffix: "f привет", sourceLanguage: "ru", precedingWords: [cue]), cue)
            XCTAssertNil(engine().appliedProposal(suffix: cue + " f привет", sourceLanguage: "ru"), cue)
        }
    }

    func testTechnicalCueOnlyProtectsLetterNotWrongNextWord() {
        XCTAssertEqual(engine().appliedProposal(suffix: "f ghbdtn", sourceLanguage: "en", precedingWords: ["press"])?.replacementSuffix,
                       "f привет")
    }

    func testUppercaseOrQuotedSymbolDoesNotResolveAsConjunction() {
        for prefix in ["F", "'f'", "\"f\"", "f(x)", "Ctrl+f"] {
            XCTAssertNil(engine().appliedProposal(suffix: prefix + " привет", sourceLanguage: "ru"), prefix)
        }
    }

    func testProtectsKnownEnglishIncludingRareDictionaryEntry() {
        for word in ["hello", "help", "rareword", "cat"] {
            XCTAssertNil(engine().appliedProposal(suffix: word, sourceLanguage: "en", atBoundary: true), word)
        }
        let collision = PredictionLexicon(wordsByLanguage: ["en": ["ghbdtn": 1], "ru": ["привет": 900_000]])
        XCTAssertNil(PredictionEngine(lexicon: collision).appliedProposal(suffix: "ghbdtn", sourceLanguage: "en", atBoundary: true))
    }

    func testContextReplacementPreservesEarlierUnicodeAndLiteralWhitespace() throws {
        let result = try XCTUnwrap(engine().appliedProposal(suffix: "🙂 f  ghbdtn  ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(result.replacementSuffix, "🙂 а  привет  ")
    }

    func testLanguageAliasesMergeInsteadOfCrashing() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["en": ["hello": 20], "en-US": ["world": 30]])
        XCTAssertEqual(lexicon.frequency(of: "hello", language: "en"), 20)
        XCTAssertEqual(lexicon.frequency(of: "world", language: "en"), 30)
    }

    func testOnlyLettersFromConfiguredScriptsCanBecomeCandidates() {
        XCTAssertNil(engine().appliedProposal(suffix: "♥♥♥♥", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine().appliedProposal(suffix: String(repeating: "g", count: 513), sourceLanguage: "en"))
    }

    func testOwnerTargetOverrideWorksOnlyAtBoundary() {
        XCTAssertNil(engine().appliedProposal(suffix: "f", sourceLanguage: "en", alwaysConvertWords: ["а"]))
        XCTAssertEqual(engine().appliedProposal(suffix: "f ", sourceLanguage: "en", atBoundary: true,
                                         alwaysConvertWords: ["а"])?.replacementSuffix, "а ")
        let collision = PredictionLexicon(wordsByLanguage: ["en": ["ghbdtn": 10], "ru": [:]])
        XCTAssertEqual(PredictionEngine(lexicon: collision).appliedProposal(suffix: "ghbdtn", sourceLanguage: "en",
            atBoundary: true, alwaysConvertWords: ["привет"])?.replacementSuffix, "привет")
    }

    func testProtectsTechnicalTokens() {
        for word in ["API", "GPT", "AI", "HTTP", "MacSwitcher", "iPhone", "fooBar", "f(x)",
                     "fisenkov.ru", "foo.com", "user@example.com", "https://example.org", "/tmp/ghbdtn",
                     "C:\\Temp\\ghbdtn", "ghbdtn_foo", "ghbdtn123", "ghбdtn"] {
            XCTAssertNil(engine().appliedProposal(suffix: word, sourceLanguage: "en", atBoundary: true), word)
        }
    }

    func testProtectsUnknownSourceAndCrossLineContext() {
        XCTAssertNil(engine().appliedProposal(suffix: "ghbdtn", sourceLanguage: "de"))
        XCTAssertNil(engine().appliedProposal(suffix: "f\nпривет", sourceLanguage: "ru"))
    }

    func testEnglishPrefixWinsEvenWhenTargetPrefixStrong() {
        let ambiguous = PredictionLexicon(wordsByLanguage: ["en": ["ghbdmore": 500_000], "ru": ["привет": 1_000_000]])
        XCTAssertNil(PredictionEngine(lexicon: ambiguous).appliedProposal(suffix: "ghbd", sourceLanguage: "en"))
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
        XCTAssertEqual(realEngine.appliedProposal(suffix: "ghbd", sourceLanguage: "en")?.replacementSuffix, "прив")
        XCTAssertEqual(realEngine.appliedProposal(suffix: "ghbdtn", sourceLanguage: "en")?.replacementSuffix, "привет")
        XCTAssertEqual(realEngine.appliedProposal(suffix: "levf.", sourceLanguage: "en", atBoundary: true)?.replacementSuffix, "думаю")
        XCTAssertEqual(realEngine.appliedProposal(suffix: "xnj-nj", sourceLanguage: "en", atBoundary: true)?.replacementSuffix, "что-то")
    }
}
