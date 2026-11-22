import XCTest
@testable import RuSwitcher

/// Three outcomes of one engine decision: apply, hint, none (spec stories 8–13).
final class PredictionDecisionTests: XCTestCase {
    private func lexicon(trigrams: [String: TrigramModel] = [:]) -> PredictionLexicon {
        PredictionLexicon(wordsByLanguage: [
            "ru": ["привет": 1_000_000, "думаю": 800_000, "гостиной": 40_000, "что": 3_000_000,
                   "за": 2_000_000, "я": 9_000_000, "мир": 500_000, "кошка": 90_000, "кошку": 60_000],
            "en": ["hello": 900_000, "the": 8_000_000, "usa": 70_000, "world": 400_000]
        ], protectedTermsByLanguage: ["en": ["nasa"]], trigramModels: trigrams)
    }

    private func engine(trigrams: [String: TrigramModel] = [:]) -> PredictionEngine {
        PredictionEngine(lexicon: lexicon(trigrams: trigrams))
    }

    private func boundary(_ suffix: String, _ language: String = "en",
                          engine custom: PredictionEngine? = nil) -> PredictionDecision {
        (custom ?? engine()).evaluate(suffix: suffix, sourceLanguage: language, atBoundary: true)
    }

    func testExactWrongLayoutWordIsStillApplied() {
        let decision = engine().evaluate(suffix: "ghbdtn", sourceLanguage: "en")
        XCTAssertEqual(decision.applied?.replacementSuffix, "привет")
        XCTAssertNil(decision.hinted)
        XCTAssertEqual(engine().evaluate(suffix: "hello", sourceLanguage: "en"), PredictionDecision.none)
    }

    func testOneLetterTypoWithWrongLayoutIsOnlyHinted() {
        // ghbdtv → привем: one substituted letter away from привет.
        let substituted = boundary("ghbdtv ")
        XCTAssertEqual(substituted.hinted?.replacementSuffix, "привет ")
        XCTAssertEqual(substituted.hinted?.reason, .typo)
        XCTAssertNil(substituted.applied)
        // ghbdn → привт: one missing letter.
        XCTAssertEqual(boundary("ghbdn ").hinted?.replacementSuffix, "привет ")
        // lvef. → дмуаю: two neighbours swapped.
        XCTAssertEqual(boundary("lvef. ").hinted?.replacementSuffix, "думаю ")
        // ghbdtnn → приветт: one extra letter; the first capital survives.
        XCTAssertEqual(boundary("Ghbdtnn ").hinted?.replacementSuffix, "Привет ")
    }

    func testTypoNeedsFourLettersAFinishedWordAndOneClearWinner() {
        XCTAssertEqual(boundary("vbg "), PredictionDecision.none, "three letters are never guessed")
        XCTAssertEqual(engine().evaluate(suffix: "ghbdtv", sourceLanguage: "en"), PredictionDecision.none,
                       "an unfinished word may still become another word")
        // rjirf → кошка exactly; rjirb → кошки is one letter from both кошка and кошку.
        XCTAssertEqual(boundary("rjirb "), PredictionDecision.none)
    }

    func testCapsTextIsConvertedAndStaysCapitalised() {
        // Both words of a CAPS phrase typed in the other layout are fixed together.
        let decision = boundary("GHBDTN VBH ")
        XCTAssertEqual(decision.applied?.replacementSuffix, "ПРИВЕТ МИР ")
        XCTAssertEqual(decision.applied?.reason, .capsRestored)
        XCTAssertEqual(boundary("РУДДЩ ЦЩКДВ ", "ru").applied?.replacementSuffix, "HELLO WORLD ")
    }

    func testAcronymsCodeAndLoneCapsStayUntouched() {
        // A lone CAPS word may be an abbreviation (public benchmark: allcaps-protection).
        XCTAssertEqual(boundary("GHBDTN "), PredictionDecision.none)
        XCTAssertEqual(boundary("THE NASA "), PredictionDecision.none, "a protected acronym")
        XCTAssertEqual(boundary("GHBDTN THE "), PredictionDecision.none, "a source word in capitals")
        XCTAssertEqual(boundary("GHBDTN GHBDTN_ID "), PredictionDecision.none, "code")
        XCTAssertEqual(boundary("PF "), PredictionDecision.none, "two capitals alone are an abbreviation")
    }

    func testShortCapsWordsFollowCapitalisedNeighbours() {
        // ЗА ЧТО: the second word is short but follows a capital word.
        XCTAssertEqual(boundary("ЗА XNJ ").applied?.replacementSuffix, "ЗА ЧТО ")
        XCTAssertEqual(boundary("PF XNJ ").applied?.replacementSuffix, "ЗА ЧТО ")
        // В ГОСТИНОЙ: a single capital letter is fixed together with its long neighbour.
        XCTAssertEqual(boundary("D UJCNBYJQ ").applied?.replacementSuffix, "В ГОСТИНОЙ ")
    }

    func testTwoInitialCapitalsAreFixedButCamelCaseIsNot() {
        let decision = boundary("ПРивет ", "ru")
        XCTAssertEqual(decision.applied?.replacementSuffix, "Привет ")
        XCTAssertEqual(decision.applied?.targetLanguage, "ru")
        XCTAssertEqual(decision.applied?.reason, .capsRestored)
        XCTAssertEqual(boundary("GHbdtn ").applied?.replacementSuffix, "Привет ")
        XCTAssertEqual(boundary("myVar "), PredictionDecision.none)
        XCTAssertEqual(boundary("MacSwitcher "), PredictionDecision.none)
        XCTAssertEqual(boundary("ПРи ", "ru"), PredictionDecision.none, "shorter than four letters")
    }

    /// Review F1: accepted mixed-case spellings are not «ПРивет» typos and are never rewritten.
    func testAcceptedMixedCaseSpellingsStayAsTyped() throws {
        let real = PredictionEngine(lexicon: try PredictionLexicon.bundled())
        for (suffix, language) in [("VMware ", "en"), ("ВКонтакте ", "ru"), ("Открой ВКонтакте ", "ru"),
                                   ("OAuth ", "en"), ("JUnit ", "en")] {
            XCTAssertEqual(boundary(suffix, language, engine: real), PredictionDecision.none, suffix)
        }
        XCTAssertEqual(boundary("ПРивет ", "ru", engine: real).applied?.replacementSuffix, "Привет ")
        // A capital letter glued to a likelier word (В + Контакте) is a name, not a held Shift.
        let custom = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: [
            "ru": ["привет": 1_000_000, "вконтакте": 40_000, "контакте": 90_000, "вокруг": 300_000, "округ": 20_000],
            "en": ["hello": 900_000]]))
        XCTAssertEqual(boundary("ВКонтакте ", "ru", engine: custom), PredictionDecision.none)
        XCTAssertEqual(boundary("ВОкруг ", "ru", engine: custom).applied?.replacementSuffix, "Вокруг ")
        XCTAssertEqual(boundary("ПРивет ", "ru", engine: custom).applied?.replacementSuffix, "Привет ")
    }

    func testSingleLetterWordFollowsItsCorrectedNeighbour() {
        let decision = engine().evaluate(suffix: "z ghbdtn", sourceLanguage: "en")
        XCTAssertEqual(decision.applied?.replacementSuffix, "я привет")
        XCTAssertEqual(decision.applied?.reason, .shortWordContext)
        // Without a Russian neighbour the letter is left alone.
        XCTAssertNil(engine().evaluate(suffix: "z hello", sourceLanguage: "en").applied)
    }

    func testUnknownWordMuchLikelierInOtherLayoutIsHinted() {
        let russian = TrigramModel(words: ["привет": 1_000, "приветливый": 100, "ветер": 500, "пример": 300])
        let english = TrigramModel(words: ["hello": 1_000, "help": 500, "world": 800, "ghost": 50])
        let custom = engine(trigrams: ["ru": russian, "en": english])
        // ghbdtnkbdsq → приветливый: in no word list, but every trigram is Russian.
        let decision = boundary("ghbdtnkbdsq ", engine: custom)
        XCTAssertEqual(decision.hinted?.replacementSuffix, "приветливый ")
        XCTAssertEqual(decision.hinted?.reason, .trigram)
        // helloworld is English-like on the source side: nothing.
        XCTAssertEqual(boundary("helloworld ", engine: custom), PredictionDecision.none)
        // Without trigram tables the same unknown word yields nothing.
        XCTAssertEqual(boundary("ghbdtnkbdsq "), PredictionDecision.none)
    }
}
