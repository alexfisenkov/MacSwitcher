import XCTest
@testable import RuSwitcher

final class ProductionSelectionPolicyTests: XCTestCase {
    @MainActor
    private func russianDirection() throws -> CombinedShiftContext {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let ru = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        return CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(en),
                                    targetLayoutID: LayoutSwitcher.sourceID(ru))
    }

    @MainActor
    func testCorrectNameAloneIsNotFlippedBySmartManualSelection() throws {
        let converter = TextConverter(selectionPreferences: { (false, true) })
        let direction = try russianDirection()

        XCTAssertEqual(converter.selectionConversion("MacSwitcher", context: direction), "MacSwitcher")
    }

    @MainActor
    func testMixedSelectionConvertsErrorAndPreservesCorrectName() throws {
        let converter = TextConverter(selectionPreferences: { (false, true) })
        let direction = try russianDirection()

        XCTAssertEqual(converter.selectionConversion("ghbdtn MacSwitcher", context: direction),
                       "привет MacSwitcher")
        XCTAssertEqual(converter.selectionConversion("MacSwitcher levf. xnj-nj nfrjt", context: direction),
                       "MacSwitcher думаю что-то такое")
    }
}
