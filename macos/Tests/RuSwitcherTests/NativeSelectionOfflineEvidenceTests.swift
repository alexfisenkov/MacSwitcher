import XCTest
@testable import RuSwitcher

/// The native RU/EN selection route reuses the prediction corpus and never
/// needs a synchronous AppleSpell lookup while deciding these exact phrases.
final class NativeSelectionOfflineEvidenceTests: XCTestCase {
    @MainActor
    func testBundledEvidenceKeepsNamesAndCorrectsOwnerPhrases() async throws {
        let lexicon = try await Task.detached(priority: .utility) {
            try PredictionLexicon.bundled()
        }.value
        let coordinator = PredictionCoordinator(monitor: KeyboardMonitor(),
            converter: TextConverter(), engine: PredictionEngine(lexicon: lexicon))
        let layouts = LayoutSwitcher.installedLayouts()
        let english = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let russian = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        let context = CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(english),
            targetLayoutID: LayoutSwitcher.sourceID(russian))
        for (original, expected) in [
            ("ghbdtn MacSwitcher", "привет MacSwitcher"),
            ("MacSwitcher levf. xnj-nj nfrjt", "MacSwitcher думаю что-то такое")
        ] {
            let queries = try XCTUnwrap(SmartConvert.requiredNativeWordEvidence(original,
                context: context))
            let obtained = await coordinator.nativeSelectionEvidence(for: queries)
            let evidence = try XCTUnwrap(obtained)
            let result = SmartConvert.selectionWithDirection(original, context: context,
                russianPriority: false, knownWord: { word, language in
                    evidence[SmartConvert.WordQuery(word: word, language: language)]
                })
            XCTAssertTrue(result.available)
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(result.language, "ru")
        }
    }

    @MainActor
    func testUnavailableExactLookupRefusesInsteadOfTreatingItAsAbsent() throws {
        let layouts = LayoutSwitcher.installedLayouts()
        let english = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let russian = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        let context = CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(english),
            targetLayoutID: LayoutSwitcher.sourceID(russian))
        let result = SmartConvert.selectionWithDirection("ghbdtn MacSwitcher",
            context: context, russianPriority: false, knownWord: { _, _ in nil })
        XCTAssertFalse(result.available)
        XCTAssertEqual(result.text, "ghbdtn MacSwitcher")
    }

    @MainActor
    func testProtectedWordLookupUsesInjectedLocalRegistry() async throws {
        let lexicon = PredictionLexicon(wordsByLanguage: ["en": [:], "ru": [:]])
        let coordinator = PredictionCoordinator(monitor: KeyboardMonitor(),
            converter: TextConverter(), engine: PredictionEngine(lexicon: lexicon))
        let query = SmartConvert.WordQuery(word: "ghbdtn", language: "en")
        let obtained = await coordinator.nativeSelectionEvidence(for: [query],
            protectedWord: { _, word, language in word == "ghbdtn" && language == "en" })
        let evidence = try XCTUnwrap(obtained)
        XCTAssertEqual(evidence[query], true)
    }
}
