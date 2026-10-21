import XCTest
import SQLite3
@testable import RuSwitcher

final class ExpandedLexiconTests: XCTestCase {
    private static let bundledResult = Result { try PredictionLexicon.bundled() }
    private func bundled() throws -> PredictionLexicon { try Self.bundledResult.get() }

    func testExactKnownBrandCorrectsWrongLayoutWithoutChangingCase() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        XCTAssertEqual(engine.evaluate(suffix: "срфепзе ", sourceLanguage: "ru", atBoundary: true)?.replacementSuffix,
                       "chatgpt ")
        XCTAssertEqual(engine.evaluate(suffix: "СрфеПЗЕ", sourceLanguage: "ru")?.replacementSuffix,
                       "ChatGPT")
        XCTAssertEqual(engine.evaluate(suffix: "СрфеПЗЕ!  ", sourceLanguage: "ru", atBoundary: true)?.replacementSuffix,
                       "ChatGPT!  ")
    }

    func testRequiredPublicBrandsCorrectExactlyFromWrongLayout() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        let terms = ["OpenAI", "ChatGPT", "Claude", "Codex", "MacSwitcher", "MacDictate", "Gemini",
                     "Anthropic", "DeepSeek", "Telegram", "WhatsApp", "GitHub", "GetCourse", "Syntx",
                     "HeyGen", "Midjourney", "Runway", "Higgsfield", "Microsoft", "Apple", "Google", "Yandex"]
        for term in terms {
            let wrong = String(term.map { KeyMapping.enToRu[$0] ?? $0 })
            XCTAssertEqual(engine.evaluate(suffix: wrong + " ", sourceLanguage: "ru", atBoundary: true)?.replacementSuffix,
                           term + " ", term)
        }
    }

    func testBundledFullCountsAreInclusiveAndRareTailIsExactlyQueryable() throws {
        let lexicon = try bundled()
        XCTAssertEqual(lexicon.wordCounts, ["ru": 200_000, "en": 200_000])
        XCTAssertEqual(lexicon.fullWordCounts, ["ru": 1_178_533, "en": 1_387_382])
        XCTAssertEqual(lexicon.fullFrequency(of: "RFR", language: "en-US"), 4)
        XCTAssertEqual(lexicon.frequency(of: "rfr", language: "en"), 0)
        XCTAssertEqual(lexicon.fullFrequency(of: "electroencephalographically", language: "en"), 1)
        XCTAssertEqual(lexicon.fullFrequency(of: "сверхпроводимость", language: "ru"), 2)
        XCTAssertEqual(lexicon.fullFrequency(of: "not-a-real-synthetic-corpus-word", language: "en"), 0)
        XCTAssertGreaterThan(lexicon.protectedTermCounts["ru"] ?? 0, 500)
        XCTAssertGreaterThan(lexicon.protectedTermCounts["en"] ?? 0, 500)
    }

    func testFullTailIsNotAddedToPredictivePrefixIndex() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["en": ["hello": 50_000]],
            fullWordsByLanguage: ["en": ["hello": 50_000, "syntheticrareword": 2]])
        XCTAssertEqual(lexicon.fullFrequency(of: "syntheticrareword", language: "en"), 2)
        XCTAssertEqual(lexicon.frequency(of: "syntheticrareword", language: "en"), 0)
        XCTAssertEqual(lexicon.prefixEvidence(for: "synthetic", language: "en"), .empty)
    }

    func testRareSourceCollisionNeedsVeryStrongExactTargetAndBoundaryForShortWords() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["ru": ["как": 8_000_000, "привет": 90_000]],
            fullWordsByLanguage: ["en": ["rfr": 4, "ghbdtn": 10]])
        let engine = PredictionEngine(lexicon: lexicon)
        XCTAssertEqual(engine.evaluate(suffix: "rfr ", sourceLanguage: "en", atBoundary: true)?.replacementSuffix, "как ")
        XCTAssertNil(engine.evaluate(suffix: "rfr", sourceLanguage: "en"))
        XCTAssertNil(engine.evaluate(suffix: "ghbdtn ", sourceLanguage: "en", atBoundary: true))
        let strong = PredictionLexicon(wordsByLanguage: ["ru": ["привет": 1_000_000]],
            fullWordsByLanguage: ["en": ["ghbdtn": 10]])
        XCTAssertEqual(PredictionEngine(lexicon: strong).evaluate(suffix: "ghbdtn", sourceLanguage: "en")?.replacementSuffix, "привет")
    }

    func testFullTailNeverConvertsOnTargetPrefixOrUnweightedBrandAlone() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["ru": ["приветствие": 9_000_000]],
            fullWordsByLanguage: ["en": ["ghbdtn": 2], "ru": ["срфепзе": 1]],
            protectedTermsByLanguage: ["en": ["ChatGPT"]])
        let engine = PredictionEngine(lexicon: lexicon)
        XCTAssertNil(engine.evaluate(suffix: "ghbdtn", sourceLanguage: "en"))
        XCTAssertNil(engine.evaluate(suffix: "срфепзе ", sourceLanguage: "ru", atBoundary: true))
    }

    func testFrequentSourceWordsStillWinOverStrongerTarget() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["en": ["rfr": 60], "ru": ["как": 80_000_000]],
            fullWordsByLanguage: ["en": ["rfr": 60]])
        XCTAssertNil(PredictionEngine(lexicon: lexicon).evaluate(suffix: "rfr ", sourceLanguage: "en", atBoundary: true))
    }

    func testCuratedIndexProtectsNamesAndOnlyMatchesCompleteTerms() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["ru": ["руддщ": 1_000_000]],
            protectedTermsByLanguage: ["en": ["Hello", "ChatGPT"], "ru": ["Сергей"]])
        let engine = PredictionEngine(lexicon: lexicon)
        XCTAssertTrue(lexicon.isProtectedTerm("hElLo", language: "en-GB"))
        XCTAssertTrue(lexicon.isProtectedTerm("СЕРГЕЙ", language: "ru"))
        XCTAssertFalse(lexicon.isProtectedTerm("Chat", language: "en"))
        XCTAssertNil(engine.evaluate(suffix: "hello ", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine.evaluate(suffix: "срфе", sourceLanguage: "ru"))
        XCTAssertEqual(engine.evaluate(suffix: "срфепзе", sourceLanguage: "ru")?.replacementSuffix, "chatgpt")
    }

    func testTechnicalAndMixedScriptProtectionStillAppliesToKnownTargets() {
        let engine = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: [:],
            protectedTermsByLanguage: ["en": ["ChatGPT"]]))
        for source in ["срфепзе123", "срфепзе_", "срфеgзе", "https://срфепзе", "@срфепзе", "срфепзе()", "fooBar"] {
            XCTAssertNil(engine.evaluate(suffix: source, sourceLanguage: "ru", atBoundary: true), source)
        }
        XCTAssertNil(engine.evaluate(suffix: "СрфеПЗЕ", sourceLanguage: "ru", characterMapping: [:]))
    }

    func testBundledPositiveRegressionCorpus() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        let cases: [(String, String, String)] = [
            ("rfr ", "en", "как "), ("ghbdtn ", "en", "привет "),
            ("Ghbdtn! ", "en", "Привет! "), ("levf. ", "en", "думаю "),
            ("xnj-nj  ", "en", "что-то  "), ("руддщ ", "ru", "hello "),
            ("срфепзе ", "ru", "chatgpt "), ("СрфеПЗЕ ", "ru", "ChatGPT "),
        ]
        for (input, language, output) in cases {
            XCTAssertEqual(engine.evaluate(suffix: input, sourceLanguage: language, atBoundary: true)?.replacementSuffix, output, input)
        }
    }

    func testBundledNegativeRegressionCorpus() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        let english = ["hello", "help", "the", "press", "keyboard", "antidisestablishmentarianism",
                       "electroencephalographically", "sesquipedalian", "zymurgy", "ChatGPT", "chatgpt",
                       "OpenAI", "openai", "Claude", "Codex", "MacSwitcher", "MacDictate", "Gemini",
                       "Anthropic", "DeepSeek", "Telegram", "WhatsApp", "GitHub", "GetCourse", "Syntx",
                       "HeyGen", "Midjourney", "Runway", "Higgsfield", "Microsoft", "Apple", "Google", "Yandex",
                       "Alexander", "Sergey", "John", "HTTP", "API", "GPT", "AI", "fooBar", "foo@example.org"]
        let russian = ["привет", "как", "думаю", "что-то", "сверхпроводимость", "Сергей", "Александр",
                       "Фёдор", "Телеграм", "Яндекс", "ЧатГПТ", "Клод", "Миджорни", "ОпенАИ"]
        for (language, words) in [("en", english), ("ru", russian)] {
            for word in words {
                XCTAssertNil(engine.evaluate(suffix: word + " ", sourceLanguage: language, atBoundary: true), word)
                XCTAssertNil(engine.evaluate(suffix: word, sourceLanguage: language), word)
            }
        }
    }

    func testExactLookupLatencyIsMeasuredWithoutCreatingFullStringIndex() throws {
        let lexicon = try bundled()
        let words = ["hello", "electroencephalographically", "rfr", "synthetic-missing-word"]
        var nanoseconds: [UInt64] = []
        nanoseconds.reserveCapacity(10_000)
        var checksum = 0
        for index in 0..<10_000 {
            let before = DispatchTime.now().uptimeNanoseconds
            checksum += try XCTUnwrap(lexicon.fullFrequency(of: words[index % words.count], language: "en"))
            nanoseconds.append(DispatchTime.now().uptimeNanoseconds - before)
        }
        nanoseconds.sort()
        XCTAssertGreaterThan(checksum, 0)
        print("FULL_LEXICON_LOOKUP samples=10000 p50_us=\(Double(nanoseconds[5_000]) / 1_000) p95_us=\(Double(nanoseconds[9_500]) / 1_000)")
    }

    func testInvalidSQLiteResourceCannotLoadOrCreateDatabase() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missing = directory.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try FullFrequencyLexicon(urlsByLanguage: ["en": missing]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
    private func corruptPublicFixtureDatabase(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("corrupt.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { throw NSError(domain: "Fixture", code: 1) }
        let sql = """
        PRAGMA page_size=4096;
        PRAGMA user_version=1;
        CREATE TABLE frequencies(word TEXT PRIMARY KEY, frequency INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        INSERT INTO frequencies VALUES ('ghbdtn', 4);
        INSERT INTO metadata VALUES ('entries', '1'), ('language', 'en');
        """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        XCTAssertEqual(result, SQLITE_OK)
        var bytes = try Data(contentsOf: url)
        // Corrupt the real frequencies b-tree page, preserving schema and metadata.
        bytes[4096] = 0xFF
        try bytes.write(to: url)
        return url
    }

    func testCorruptFullDatabaseReadIsUnavailableRatherThanAbsent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try corruptPublicFixtureDatabase(in: directory)
        let lexicon = try FullFrequencyLexicon(urlsByLanguage: ["en": url])
        XCTAssertNil(lexicon.frequency(of: "ghbdtn", language: "en"))
        XCTAssertNil(lexicon.frequency(of: "hello", language: "en"))
        let engine = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: ["ru": ["привет": 900_000]],
                                                                 fullLexicon: lexicon))
        XCTAssertNil(engine.evaluate(suffix: "ghbdtn ", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine.evaluate(suffix: "f привет", sourceLanguage: "en"))
        XCTAssertEqual(FullFrequencyLexicon().frequency(of: "ghbdtn", language: "en"), 0)
    }

    func testAllCapsAcronymsRemainProtectedEvenWithKnownTargetTerm() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        for (word, language) in [("ПЗЕ", "ru"), ("ФЗШ", "ru"), ("РЕЕЗ", "ru"), ("GHBDTN", "en")] {
            XCTAssertNil(engine.evaluate(suffix: word, sourceLanguage: language, atBoundary: true), word)
        }
    }

    func testExplicitBoundaryOwnerForceMayOverrideAllCapsProtection() {
        let engine = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: ["ru": ["привет": 900_000]]))
        XCTAssertEqual(engine.evaluate(suffix: "GHBDTN ", sourceLanguage: "en", atBoundary: true,
                                       alwaysConvertWords: ["привет"])?.replacementSuffix, "ПРИВЕТ ")
        XCTAssertNil(engine.evaluate(suffix: "GHBDTN", sourceLanguage: "en", alwaysConvertWords: ["привет"]))
    }

    func testInteriorDotRequiresExactRussianEvidenceAndNoDomainContext() {
        let lexicon = PredictionLexicon(wordsByLanguage: ["ru": ["люди": 90_000, "компьютер": 6_106]],
            protectedTermsByLanguage: ["ru": ["компьютер"]])
        let engine = PredictionEngine(lexicon: lexicon)
        XCTAssertNil(engine.evaluate(suffix: "k.lb ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(engine.evaluate(suffix: "k.lb ", sourceLanguage: "en", atBoundary: true,
                                       precedingWords: ["эти"])?.replacementSuffix, "люди ")
        XCTAssertEqual(engine.evaluate(suffix: "rjvgm.nth ", sourceLanguage: "en", atBoundary: true)?.replacementSuffix, "компьютер ")
        for cue in ["сайт", "домен", "domain", "website", "url", "link"] {
            XCTAssertNil(engine.evaluate(suffix: "k.lb ", sourceLanguage: "en", atBoundary: true, precedingWords: [cue]), cue)
            XCTAssertNil(engine.evaluate(suffix: cue + " k.lb ", sourceLanguage: "en", atBoundary: true), cue)
        }
        for token in ["foo.com", "google.com", "github.com", "example.org", "x.com", "t.co", "ya.ru", "vk.com",
                      "user@k.lb", "https://k.lb", "http://rjvgm.nth", "www.k.lb", "k.lb/path"] {
            XCTAssertNil(engine.evaluate(suffix: token, sourceLanguage: "en", atBoundary: true), token)
        }
        let recognized = PredictionLexicon(wordsByLanguage: ["ru": ["люди": 90_000], "en": ["k.lb": 400]])
        XCTAssertNil(PredictionEngine(lexicon: recognized).evaluate(suffix: "k.lb ", sourceLanguage: "en", atBoundary: true))
    }

    func testHostnameShapeAbstainsWithoutNarrowPeopleCollocation() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        for suffix in ["k.lb", "k.lb ", "Открой k.lb ", "go to k.lb ", "c.lf ", "Открой c.lf "] {
            XCTAssertNil(engine.evaluate(suffix: suffix, sourceLanguage: "en", atBoundary: true), suffix)
        }
        for modifier in ["эти", "все", "наши", "другие", "многие", "некоторые", "добрые", "хорошие", "новые", "молодые"] {
            XCTAssertEqual(engine.evaluate(suffix: "k.lb ", sourceLanguage: "en", atBoundary: true,
                                           precedingWords: [modifier])?.replacementSuffix, "люди ", modifier)
        }
        XCTAssertEqual(engine.evaluate(suffix: "эти k.lb ", sourceLanguage: "en", atBoundary: true)?.replacementSuffix, "эти люди ")
        XCTAssertNil(engine.evaluate(suffix: "domain эти k.lb ", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine.evaluate(suffix: "сайт наши k.lb ", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine.evaluate(suffix: "эти c.lf ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(engine.evaluate(suffix: "rjvgm.nth ", sourceLanguage: "en", atBoundary: true)?.replacementSuffix, "компьютер ")
    }

    func testCommonHostnameSuffixProtectionIsIndependentOfTargetFrequency() {
        // Synthetic confidence fixtures isolate the suffix rule from whether a
        // particular public subtitle corpus happens to contain a mapped spelling.
        let engine = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: ["ru": [
            "люсщь": 900_000, "лющкп": 900_000, "лютуе": 900_000, "лювум": 900_000
        ]]))
        for token in ["k.com", "k.org", "k.net", "k.dev"] {
            XCTAssertNil(engine.evaluate(suffix: token, sourceLanguage: "en", atBoundary: true), token)
        }
    }

}
