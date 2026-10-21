import XCTest
@testable import RuSwitcher

final class CombinedShiftSettingsTests: XCTestCase {
    func testAutoConvertChoiceCannotBypassCandidateRolloutGate() throws {
        let domain = "RuSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let candidate = SettingsManager(defaults: defaults, nativeRolloutAccepted: false)
        candidate.autoConvert = true
        XCTAssertTrue(candidate.autoConvert)
        XCTAssertFalse(candidate.nativeAutoEnabled)
        candidate.autoConvert = false
        candidate.autoConvert = true
        XCTAssertFalse(candidate.nativeAutoEnabled)
        let accepted = SettingsManager(defaults: defaults, nativeRolloutAccepted: true)
        accepted.autoConvert = true
        XCTAssertTrue(accepted.nativeAutoEnabled)
        // A controlled owner rollout remains explicit for the pilot.
        candidate.nativeAutoEnabled = false
        XCTAssertFalse(candidate.nativeAutoEnabled)
    }
    func testAutomaticCorrectionWaitsForChoiceAndPreservesExplicitOptOut() throws {
        let domain = "RuSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsManager(defaults: defaults)
        XCTAssertFalse(settings.autoConvert)
        settings.autoConvert = true
        XCTAssertTrue(SettingsManager(defaults: defaults).autoConvert)
        settings.autoConvert = false
        XCTAssertFalse(SettingsManager(defaults: defaults).autoConvert)
    }
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
