import Carbon
import XCTest
@testable import RuSwitcher

final class CombinedShiftMappingTests: XCTestCase {
    private func contexts() throws -> (CombinedShiftContext, CombinedShiftContext) {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let ru = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        let context = CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(en),
                                           targetLayoutID: LayoutSwitcher.sourceID(ru))
        return (context, context.reversed)
    }

    func testKeyMappingUsesSavedSourceInBothDirectionsWithoutMutatingSystemLayout() throws {
        let current = LayoutSwitcher.currentLayoutID()
        let (enToRu, ruToEn) = try contexts()
        // Physical keys for ghbdtn, which become привет under the Russian source.
        let keys = [5, 4, 11, 2, 17, 45].map { TypedKey(keyCode: UInt16($0), shift: false, caps: false) }
        let forward = try XCTUnwrap(DynamicKeyMapping.convertKeys(keys, context: enToRu))
        XCTAssertEqual(forward.original, "ghbdtn")
        XCTAssertEqual(forward.converted, "привет")
        let backward = try XCTUnwrap(DynamicKeyMapping.convertKeys(keys, context: ruToEn))
        XCTAssertEqual(backward.original, "привет")
        XCTAssertEqual(backward.converted, "ghbdtn")
        XCTAssertEqual(LayoutSwitcher.currentLayoutID(), current)
    }

    func testSelectionMappingUsesSavedSourceInBothDirections() throws {
        let (enToRu, ruToEn) = try contexts()
        XCTAssertEqual(DynamicKeyMapping.convert("ghbdtn", context: enToRu), "привет")
        XCTAssertEqual(DynamicKeyMapping.convert("привет", context: ruToEn), "ghbdtn")
    }

    func testMissingExplicitSourceDoesNotFallBackToActiveLayout() throws {
        let (enToRu, _) = try contexts()
        let invalid = CombinedShiftContext(sourceLayoutID: "removed-input-source", targetLayoutID: enToRu.targetLayoutID)
        let keys = [TypedKey(keyCode: 5, shift: false, caps: false)]
        XCTAssertNil(DynamicKeyMapping.convertKeys(keys, context: invalid))
        XCTAssertEqual(DynamicKeyMapping.convert("ghbdtn", context: invalid), "ghbdtn")
    }

    func testMixedBidirectionalSelectionUsesSameSavedPairInBothOrientations() throws {
        let (enToRu, ruToEn) = try contexts()
        XCTAssertEqual(DynamicKeyMapping.convertBidirectional("ghbdtn привет", context: enToRu), "привет ghbdtn")
        XCTAssertEqual(DynamicKeyMapping.convertBidirectional("ghbdtn привет", context: ruToEn), "привет ghbdtn")
    }

    @MainActor
    func testSmartMixedSelectionKeepsCorrectWordWithSavedSource() throws {
        guard Dict.isAvailable("en"), Dict.isAvailable("ru") else { throw XCTSkip("System EN/RU dictionaries unavailable") }
        let (enToRu, _) = try contexts()
        XCTAssertEqual(SmartConvert.selection("ghbdtn привет", context: enToRu), "привет привет")
        let missing = CombinedShiftContext(sourceLayoutID: "removed-source", targetLayoutID: enToRu.targetLayoutID)
        XCTAssertEqual(SmartConvert.selection("ghbdtn привет", context: missing), "ghbdtn привет")
    }

    func testEmptyKeysCannotBecomeFakeWordEvenWithValidSourcePair() throws {
        let (enToRu, _) = try contexts()
        XCTAssertNil(DynamicKeyMapping.convertKeys([], context: enToRu))
    }

    func testCyrillicSelectionUnderUSFinishesInEnglish() throws {
        let (enToRu, ruToEn) = try contexts()
        let converted = DynamicKeyMapping.convertBidirectional("привет", context: enToRu)
        XCTAssertEqual(converted, "ghbdtn")
        XCTAssertEqual(DynamicKeyMapping.resultContext(for: converted, requested: enToRu), ruToEn)
    }

    func testMixedSelectionUsesDominantResultLanguageAndTieKeepsFirstTarget() throws {
        let (enToRu, ruToEn) = try contexts()
        XCTAssertEqual(DynamicKeyMapping.resultContext(for: "hello привет", requested: ruToEn), enToRu)
        XCTAssertEqual(DynamicKeyMapping.resultContext(for: "привет ghbdtn", requested: enToRu), enToRu)
    }

    func testForwardedCyrillicWordIgnoresLocalUSSourceOrientation() throws {
        let (enToRu, _) = try contexts()
        let keys = Array("привет").map { TypedKey(keyCode: 0, shift: false, caps: false, char: $0) }
        let pair = try XCTUnwrap(DynamicKeyMapping.convertKeys(keys, context: enToRu))
        XCTAssertEqual(pair.original, "привет")
        XCTAssertEqual(pair.converted, "ghbdtn")
    }
}
