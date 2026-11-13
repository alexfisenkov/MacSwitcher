import XCTest
@testable import RuSwitcher

final class ModernColloquialLexiconTests: XCTestCase {
    private static let bundledResult = Result { try PredictionLexicon.bundled() }
    private func bundled() throws -> PredictionLexicon { try Self.bundledResult.get() }

    func testApprovedModernSpellingsCorrectAtWordBoundary() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        let cases: [(wrong: String, source: String, expected: String)] = [
            ("leiybkf", "en", "душнила"),
            ("njrcbxrf", "en", "токсичка"),
            ("ytqhjctnrf", "en", "нейросетка"),
            ("мшиусщвштп", "ru", "vibecoding"),
            ("ылшишвш", "ru", "skibidi"),
        ]
        for item in cases {
            XCTAssertEqual(engine.evaluate(suffix: item.wrong + " ", sourceLanguage: item.source,
                                           atBoundary: true)?.replacementSuffix,
                           item.expected + " ", item.expected)
        }
        XCTAssertEqual(engine.evaluate(suffix: "rhby; ", sourceLanguage: "en", atBoundary: true,
                                       russianPriority: true)?.replacementSuffix, "кринж ")
        XCTAssertEqual(try bundled().hasSupplementalSpelling("кринж", language: "ru"), true)
    }

    func testEveryApprovedWordIsUnweightedAndPresentInTheSupplementalLexicon() throws {
        let lexicon = try bundled()
        let approved: [(String, String)] = [
            ("ru", "вайбовый"), ("ru", "жиза"), ("ru", "кринжово"), ("ru", "рофлить"),
            ("ru", "имба"), ("ru", "душнила"), ("ru", "душнить"), ("ru", "токсичка"),
            ("ru", "хайпануть"), ("ru", "зашкварный"), ("ru", "кринжовый"), ("ru", "мемный"),
            ("ru", "мемасик"), ("ru", "угарнуть"), ("ru", "забустить"), ("ru", "апнуть"),
            ("ru", "пропушить"), ("ru", "задеплоить"), ("ru", "заскринить"), ("ru", "отрефачить"),
            ("ru", "зарефакторить"), ("ru", "крашнуться"), ("ru", "багфикс"), ("ru", "хотфикс"),
            ("ru", "созвончик"), ("ru", "синкнуться"), ("ru", "дейлик"), ("ru", "митапчик"),
            ("ru", "воркшопчик"), ("ru", "фидбэкнуть"), ("ru", "вайбкодинг"), ("ru", "вайбкодер"),
            ("ru", "нейросеточка"), ("ru", "нейросеточный"), ("ru", "промт"), ("ru", "промтить"),
            ("ru", "промтинг"), ("ru", "мультимодалка"), ("ru", "агентность"), ("ru", "ресерчить"),
            ("ru", "кастдевить"), ("ru", "кастдев"), ("ru", "брифовать"), ("ru", "релизнуть"),
            ("ru", "задеплоиться"), ("ru", "смерджить"), ("ru", "ребейзнуть"), ("ru", "заревьюить"),
            ("ru", "коммитнуть"), ("ru", "подмержить"), ("ru", "флейкать"), ("ru", "флейковый"),
            ("ru", "зафейлиться"), ("ru", "заассайнить"), ("ru", "заапрувить"), ("ru", "пофикситься"),
            ("ru", "заебанный"), ("ru", "заебанно"), ("ru", "кринж"), ("ru", "нейросетка"),
            ("en", "vibecoding"), ("en", "skibidi"), ("en", "delulu"), ("en", "yeet"),
            ("en", "brainrot"), ("en", "doomscroll"), ("en", "highkey"), ("en", "ratioed"),
            ("en", "ratioing"), ("en", "noobish"), ("en", "ragebait"), ("en", "doomscroller"),
            ("en", "shitpost"), ("en", "shitposting"), ("en", "shitposter"), ("en", "basedness"),
            ("en", "frfr"), ("en", "idgaf"), ("en", "iykyk"), ("en", "istg"), ("en", "wdym"),
            ("en", "tysm"), ("en", "rizzed"), ("en", "rizzing"), ("en", "brainrotted"),
            ("en", "brainrotting"), ("en", "unhingedly"), ("en", "memelord"), ("en", "sidequest"),
            ("en", "ragebaiter"), ("en", "ragebaiting"), ("en", "parasocial"),
            ("en", "parasociality"), ("en", "doomposting"), ("en", "parasocially"),
        ]
        XCTAssertEqual(approved.count, 95)
        for (language, word) in approved {
            XCTAssertEqual(lexicon.hasSupplementalSpelling(word, language: language), true, "\(language):\(word)")
            XCTAssertEqual(lexicon.frequency(of: word, language: language), 0, "weighted trigger: \(language):\(word)")
            XCTAssertEqual(lexicon.fullFrequency(of: word, language: language), 0, "weighted full lexicon: \(language):\(word)")
        }
    }

    func testNewBrandCorrectsWrongLayoutAndPreservesItsSpelling() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        XCTAssertEqual(engine.evaluate(suffix: "Ефитшту ", sourceLanguage: "ru", atBoundary: true)?.replacementSuffix,
                       "Tabnine ")
        XCTAssertNil(engine.evaluate(suffix: "Tabnine ", sourceLanguage: "en", atBoundary: true))
    }

    func testModernSpellingsDoNotCorrectPrematurePrefixes() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        for (prefix, language) in [("njrc", "en"), ("ytqhj", "en"), ("мшиус", "ru"), ("ылш", "ru"),
                                   ("leiy", "en")] {
            XCTAssertNil(engine.evaluate(suffix: prefix, sourceLanguage: language), prefix)
        }
    }

    func testKnownSlangBrandsAndCommonProfanityRemainAsTyped() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        for (word, language) in [
            ("кринжово", "ru"), ("doomscrolling", "en"), ("ChatGPT", "en"),
            ("shit", "en"), ("fuck", "en"), ("bitch", "en"),
            ("сука", "ru"), ("блядь", "ru"), ("хуй", "ru"),
        ] {
            XCTAssertNil(engine.evaluate(suffix: word + " ", sourceLanguage: language, atBoundary: true), word)
            XCTAssertNil(engine.evaluate(suffix: word, sourceLanguage: language), word)
        }
    }

    func testModernTargetsDoNotOverrideStructuredTokens() throws {
        let engine = PredictionEngine(lexicon: try bundled())
        for (token, language) in [
            ("-njrcbxrf", "en"), ("--njrcbxrf", "en"), ("/tmp/njrcbxrf", "en"),
            ("https://njrcbxrf", "en"), ("https://мшиусщвштп", "ru"),
        ] {
            XCTAssertNil(engine.evaluate(suffix: token + " ", sourceLanguage: language, atBoundary: true), token)
        }
    }
}
