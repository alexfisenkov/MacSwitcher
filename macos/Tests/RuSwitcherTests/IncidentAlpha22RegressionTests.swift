import XCTest
@testable import RuSwitcher

/// Reproduces the public RU/EN example with the shipped dictionaries and the
/// same pure policies used before either automatic or manual native editing.
final class IncidentAlpha22RegressionTests: XCTestCase {
    private func englishToRussianContext() throws -> (CombinedShiftContext, [Character: Character]) {
        let layouts = LayoutSwitcher.installedLayouts()
        let english = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let russian = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        let context = CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(english),
            targetLayoutID: LayoutSwitcher.sourceID(russian))
        let mapping = DynamicKeyMapping.buildMap(from: english, to: russian)
        XCTAssertFalse(mapping.isEmpty)
        return (context, mapping)
    }

    func testBundledPredictionHandlesEachWordAtBoundaryWithRussianPriority() throws {
        let (_, mapping) = try englishToRussianContext()
        let engine = PredictionEngine(lexicon: try PredictionLexicon.bundled())
        for (source, expected, preceding) in [
            ("nfr ", "так ", [String]()),
            ("b ", "и ", ["так"]),
            ("j,sxyj ", "обычно ", ["так", "и"])
        ] {
            let proposal = engine.evaluate(suffix: source, sourceLanguage: "en",
                atBoundary: true, precedingWords: preceding, characterMapping: mapping,
                russianPriority: true)
            XCTAssertEqual(proposal?.replacementSuffix, expected, source)
            XCTAssertEqual(proposal?.targetLanguage, "ru", source)
        }
    }

    func testBundledPredictionBeforeBoundaryWithRussianPriority() throws {
        let (_, mapping) = try englishToRussianContext()
        let engine = PredictionEngine(lexicon: try PredictionLexicon.bundled())
        let examples: [(String, String?, [String])] = [
            ("nfr", nil, [String]()),
            ("b", "и", ["так"]),
            ("j,sxyj", "обычно", ["так", "и"])
        ]
        for (source, expected, preceding) in examples {
            let proposal = engine.evaluate(suffix: source, sourceLanguage: "en",
                precedingWords: preceding, characterMapping: mapping, russianPriority: true)
            XCTAssertEqual(proposal?.replacementSuffix, expected, source)
        }
    }

    func testBundledPredictionOnWholePhraseIsOnlyAnExactSuffixProposal() throws {
        let (_, mapping) = try englishToRussianContext()
        let engine = PredictionEngine(lexicon: try PredictionLexicon.bundled())
        let proposal = engine.evaluate(suffix: "nfr b j,sxyj ", sourceLanguage: "en",
            atBoundary: true, characterMapping: mapping, russianPriority: true)
        // Auto editing receives a snapshot for each current word. A full phrase
        // snapshot can change only its current word unless an explicit context
        // rule returns a larger exact suffix.
        XCTAssertEqual(proposal?.replacementSuffix, "nfr b обычно ")
    }

    @MainActor
    func testBundledSmartSelectionAndOwnerConvertByTextPolicy() async throws {
        let (context, _) = try englishToRussianContext()
        let original = "nfr b j,sxyj"
        let coordinator = PredictionCoordinator(monitor: KeyboardMonitor(),
            converter: TextConverter(), engine: PredictionEngine(lexicon: try PredictionLexicon.bundled()))
        let queries = try XCTUnwrap(SmartConvert.requiredNativeWordEvidence(original, context: context))
        let obtained = await coordinator.nativeSelectionEvidence(for: queries)
        let evidence = try XCTUnwrap(obtained)
        let smart = SmartConvert.selectionWithDirection(original, context: context,
            russianPriority: true, knownWord: { word, language in
                evidence[SmartConvert.WordQuery(word: word, language: language)]
            })
        XCTAssertTrue(smart.available)
        // The shipped full lexicon recognizes nfr in English. Smart selection
        // conservatively keeps that word while converting the other tokens.
        XCTAssertEqual(evidence[SmartConvert.WordQuery(word: "nfr", language: "en")], true)
        XCTAssertEqual(smart.text, "nfr и обычно")
        // The owner's convertByText=true route uses this direct mapping rather
        // than the smart-selection policy.
        XCTAssertEqual(DynamicKeyMapping.convertBidirectional(original, context: context),
            "так и обычно")
        let ownerSelectionPolicy = TextConverter(selectionPreferences: { (true, true) })
        XCTAssertEqual(ownerSelectionPolicy.selectionConversion(original, context: context),
            "так и обычно")
    }
}
