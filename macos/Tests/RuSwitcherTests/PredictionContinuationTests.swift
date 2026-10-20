import XCTest
@testable import RuSwitcher

final class PredictionContinuationTests: XCTestCase {
    func testEarlyCorrectedPrefixThenPhysicalKeyStillConvertsOnDoubleShift() throws {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let ru = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        let ruToEn = CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(ru), targetLayoutID: LayoutSwitcher.sourceID(en))
        // Auto changed ghbd -> прив, then the physical T key delivered Russian е.
        var keys = "прив".map { TypedKey(keyCode: 0, shift: false, caps: false, char: $0) }
        keys.append(TypedKey(keyCode: 17, shift: false, caps: false))
        let pair = try XCTUnwrap(DynamicKeyMapping.convertKeys(keys, context: ruToEn))
        XCTAssertEqual(pair.original, "приве")
        XCTAssertEqual(pair.converted, "ghbdt")
        XCTAssertEqual(DynamicKeyMapping.lineString(from: keys, sourceLayoutID: ruToEn.sourceLayoutID), "приве")

        var gesture = CombinedShiftGesture()
        gesture.press(.left, at: 10_000_000, context: ruToEn)
        XCTAssertEqual(gesture.release(.left, at: 60_000_000), .switchLayout(ruToEn))
        gesture.press(.right, at: 130_000_000, context: ruToEn.reversed)
        XCTAssertEqual(gesture.release(.right, at: 180_000_000), .convert(ruToEn))
        // The immutable first-tap direction decodes that same mixed buffer, even
        // though the active source has changed on the first solo release.
        XCTAssertEqual(try XCTUnwrap(DynamicKeyMapping.convertKeys(keys, context: ruToEn)).converted, "ghbdt")
    }
}
