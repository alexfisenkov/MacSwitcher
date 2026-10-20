import XCTest
@testable import RuSwitcher

final class CombinedShiftSettingsTests: XCTestCase {
    func testVendorDefaultDisabledAndMarkedLocalDefaultEnabled() throws {
        let domain = "RuSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertFalse(SettingsManager(defaults: defaults, combinedShiftDefault: false).combinedShiftEnabled)
        XCTAssertTrue(SettingsManager(defaults: defaults, combinedShiftDefault: true).combinedShiftEnabled)
    }

    func testExplicitDisableSurvivesCustomDefaultAndNextSettingsInstance() throws {
        let domain = "RuSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsManager(defaults: defaults, combinedShiftDefault: true)
        settings.combinedShiftEnabled = false
        XCTAssertFalse(settings.combinedShiftEnabled)
        XCTAssertFalse(SettingsManager(defaults: defaults, combinedShiftDefault: true).combinedShiftEnabled)
        settings.combinedShiftEnabled = true
        XCTAssertTrue(SettingsManager(defaults: defaults, combinedShiftDefault: false).combinedShiftEnabled)
    }
}
