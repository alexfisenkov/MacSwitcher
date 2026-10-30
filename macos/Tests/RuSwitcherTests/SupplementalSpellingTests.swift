import XCTest
import SQLite3
@testable import RuSwitcher

final class SupplementalSpellingTests: XCTestCase {
    private static let bundledResult = Result { () throws -> PredictionLexicon in
        let started = DispatchTime.now().uptimeNanoseconds
        let lexicon = try PredictionLexicon.bundled()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        print("SPELLING_BUNDLED_LOAD elapsed_ms=\(Double(elapsed) / 1_000_000)")
        return lexicon
    }

    private func bundled() async throws -> PredictionLexicon {
        try await Task.detached(priority: .utility) {
            try SupplementalSpellingTests.bundledResult.get()
        }.value
    }

    private func engine(sourceWords: Set<String> = [], targetWords: Set<String> = [],
                        fullSource: [String: Int] = [:]) -> PredictionEngine {
        PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: [:],
            fullWordsByLanguage: ["en": fullSource],
            spellingWordsByLanguage: ["en": sourceWords, "ru": targetWords]))
    }

    func testRussianInflectionAndEnglishPluralCorrectOnlyAtWordBoundary() {
        let russian = engine(targetWords: ["промптами"])
        XCTAssertEqual(russian.evaluate(suffix: "ghjvgnfvb ", sourceLanguage: "en", atBoundary: true)?.replacementSuffix,
                       "промптами ")
        XCTAssertNil(russian.evaluate(suffix: "ghjvgnfvb", sourceLanguage: "en"))
        XCTAssertNil(russian.evaluate(suffix: "ghjvgn", sourceLanguage: "en", atBoundary: true))

        let english = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: [:],
            spellingWordsByLanguage: ["en": ["prompts"]]))
        let wrong = String("prompts".map { KeyMapping.enToRu[$0] ?? $0 })
        XCTAssertEqual(english.evaluate(suffix: wrong + " ", sourceLanguage: "ru", atBoundary: true)?.replacementSuffix,
                       "prompts ")
        XCTAssertNil(english.evaluate(suffix: wrong, sourceLanguage: "ru"))
    }

    func testValidSourceSpellingAndCrossLanguageCollisionAreProtected() {
        let protected = engine(sourceWords: ["ghjvgnfvb"], targetWords: ["промптами"])
        XCTAssertNil(protected.evaluate(suffix: "ghjvgnfvb ", sourceLanguage: "en", atBoundary: true))
        let crossLanguage = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: [:],
            spellingWordsByLanguage: ["en": ["hello"], "ru": ["hello"]]))
        XCTAssertNil(crossLanguage.evaluate(suffix: "hello ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(protected.lexicon.frequency(of: "промптами", language: "ru"), 0)
        XCTAssertEqual(protected.lexicon.prefixEvidence(for: "пром", language: "ru"), .empty)
    }

    func testUnweightedTargetCannotDefeatRareSourceOrStructuredProtection() {
        let rare = engine(targetWords: ["промптами"], fullSource: ["ghjvgnfvb": 1])
        XCTAssertNil(rare.evaluate(suffix: "ghjvgnfvb ", sourceLanguage: "en", atBoundary: true))
        let plain = engine(targetWords: ["промптами"])
        for token in ["ghjvgnfvb123", "ghjvgnfvb_", "https://ghjvgnfvb", "@ghjvgnfvb",
                      "GHJVGNFVB", "ghjVgnfvb", "ghjvgnfvb/path"] {
            XCTAssertNil(plain.evaluate(suffix: token + " ", sourceLanguage: "en", atBoundary: true), token)
        }
    }

    func testPunctuationAlternativesMustHaveOneExactSpelling() {
        let sole = engine(targetWords: ["думаю"])
        XCTAssertEqual(sole.evaluate(suffix: "levf. ", sourceLanguage: "en", atBoundary: true)?.replacementSuffix,
                       "думаю ")
        let ambiguous = engine(targetWords: ["дума", "думаю"])
        XCTAssertNil(ambiguous.evaluate(suffix: "levf. ", sourceLanguage: "en", atBoundary: true))
    }

    func testBundledModernFormsCorrectAtBoundaryAndPreserveValidSources() async throws {
        let lexicon = try await bundled()
        XCTAssertEqual(lexicon.spellingWordCounts, ["ru": 3_064_053, "en": 171_040])
        let engine = PredictionEngine(lexicon: lexicon)
        let cases: [(wrong: String, source: String, correct: String, target: String)] = [
            ("hfcrkflrb", "en", "раскладки", "ru"),
            ("ghjvgnfvb", "en", "промптами", "ru"),
            ("вщщьыскщддштп", "ru", "doomscrolling", "en"),
            ("ещлутшяфешщт", "ru", "tokenization", "en"),
            ("сщвуифыу", "ru", "codebase", "en")
        ]
        for item in cases {
            XCTAssertEqual(lexicon.frequency(of: item.wrong, language: item.source), 0, item.correct)
            XCTAssertEqual(lexicon.fullFrequency(of: item.wrong, language: item.source), 0, item.correct)
            XCTAssertEqual(lexicon.hasSupplementalSpelling(item.wrong, language: item.source), false, item.correct)
            XCTAssertEqual(lexicon.hasSupplementalSpelling(item.correct, language: item.target), true, item.correct)
            XCTAssertEqual(engine.evaluate(suffix: item.wrong + " ", sourceLanguage: item.source,
                                       atBoundary: true)?.replacementSuffix, item.correct + " ", item.correct)
            XCTAssertNil(engine.evaluate(suffix: item.wrong, sourceLanguage: item.source), item.correct)
            XCTAssertNil(engine.evaluate(suffix: item.correct + " ", sourceLanguage: item.target,
                                     atBoundary: true), item.correct)
        }
    }

    func testBundledExactLookupLatencyIsMeasured() async throws {
        let lexicon = try await bundled()
        let words = ["промптами", "раскладки", "doomscrolling", "syntheticmissingword"]
        let languages = ["ru", "ru", "en", "en"]
        var samples: [UInt64] = []
        samples.reserveCapacity(10_000)
        var hits = 0
        for index in 0..<10_000 {
            let before = DispatchTime.now().uptimeNanoseconds
            let answer = lexicon.hasSupplementalSpelling(words[index % 4], language: languages[index % 4])
            samples.append(DispatchTime.now().uptimeNanoseconds - before)
            if try XCTUnwrap(answer) {
                hits += 1
            }
        }
        samples.sort()
        XCTAssertGreaterThan(hits, 0)
        print("SPELLING_EXACT_LOOKUP samples=10000 p50_us=\(Double(samples[5_000]) / 1_000) p95_us=\(Double(samples[9_500]) / 1_000)")
    }

    private func makeDatabase(in directory: URL, name: String, language: String,
                              word: String = "промптами", entries: String = "1",
                              version: Int = 1, includeTable: Bool = true,
                              includeWord: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SpellingFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        let table = includeTable
            ? "CREATE TABLE spellings(word TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID;"
                + (includeWord ? " INSERT INTO spellings VALUES ('\(word)');" : "")
            : ""
        let sql = """
        PRAGMA page_size=4096;
        PRAGMA user_version=\(version);
        \(table)
        CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        INSERT INTO metadata VALUES ('entries', '\(entries)'), ('language', '\(language)');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SpellingFixture", code: 2)
        }
        return url
    }

    func testSQLiteExactReadNormalizationMetadataAndMissingResource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeDatabase(in: directory, name: "ru.sqlite", language: "ru")
        let lexicon = try SupplementalSpellingLexicon(urlsByLanguage: ["ru-RU": url])
        XCTAssertEqual(lexicon.wordCounts, ["ru": 1])
        XCTAssertEqual(lexicon.contains("ПРОМПТАМИ", language: "ru-RU"), true)
        XCTAssertEqual(lexicon.contains("несуществующее", language: "ru"), false)
        XCTAssertEqual(lexicon.contains("prompts", language: "en"), false)

        let missing = directory.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try SupplementalSpellingLexicon(urlsByLanguage: ["en": missing]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let wrongLanguage = try makeDatabase(in: directory, name: "wrong.sqlite", language: "en")
        XCTAssertThrowsError(try SupplementalSpellingLexicon(urlsByLanguage: ["ru": wrongLanguage]))
        let wrongVersion = try makeDatabase(in: directory, name: "version.sqlite", language: "ru", version: 2)
        XCTAssertThrowsError(try SupplementalSpellingLexicon(urlsByLanguage: ["ru": wrongVersion]))
        let empty = try makeDatabase(in: directory, name: "empty.sqlite", language: "ru", entries: "0")
        XCTAssertThrowsError(try SupplementalSpellingLexicon(urlsByLanguage: ["ru": empty]))
        let overstated = try makeDatabase(in: directory, name: "partial.sqlite", language: "ru", entries: "2")
        XCTAssertThrowsError(try SupplementalSpellingLexicon(urlsByLanguage: ["ru": overstated]))
        let missingRows = try makeDatabase(in: directory, name: "missing-rows.sqlite", language: "ru", includeWord: false)
        XCTAssertThrowsError(try SupplementalSpellingLexicon(urlsByLanguage: ["ru": missingRows]))
        let noTable = try makeDatabase(in: directory, name: "no-table.sqlite", language: "ru", includeTable: false)
        XCTAssertThrowsError(try SupplementalSpellingLexicon(urlsByLanguage: ["ru": noTable]))
    }

    func testCorruptSourceAndTargetDatabasesRefuseToLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruURL = try makeDatabase(in: directory, name: "ru.sqlite", language: "ru")
        let enURL = try makeDatabase(in: directory, name: "en.sqlite", language: "en", word: "someword")
        for url in [ruURL, enURL] {
            var bytes = try Data(contentsOf: url)
            bytes[4096] = 0xFF // spellings b-tree page; schema and metadata remain readable.
            try bytes.write(to: url)
        }
        XCTAssertThrowsError(try SupplementalSpellingLexicon(urlsByLanguage: ["en": enURL]))
        XCTAssertThrowsError(try SupplementalSpellingLexicon(urlsByLanguage: ["ru": ruURL]))
    }

    @MainActor
    func testManualSelectionEvidenceKeepsNewValidWords() async throws {
        let lexicon = PredictionLexicon(wordsByLanguage: [:],
            spellingWordsByLanguage: ["en": ["newenglishword"], "ru": ["промптами"]])
        let coordinator = PredictionCoordinator(monitor: KeyboardMonitor(),
            converter: TextConverter(), engine: PredictionEngine(lexicon: lexicon))
        let queries = [SmartConvert.WordQuery(word: "newenglishword", language: "en"),
                       SmartConvert.WordQuery(word: "промптами", language: "ru"),
                       SmartConvert.WordQuery(word: "ghjvgnfvb", language: "en")]
        let obtained = await coordinator.nativeSelectionEvidence(for: queries)
        let evidence = try XCTUnwrap(obtained)
        XCTAssertEqual(evidence[queries[0]], true)
        XCTAssertEqual(evidence[queries[1]], true)
        XCTAssertEqual(evidence[queries[2]], false)
    }
}
