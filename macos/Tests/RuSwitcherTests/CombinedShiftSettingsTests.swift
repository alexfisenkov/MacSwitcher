import XCTest
@testable import RuSwitcher

final class CombinedShiftSettingsTests: XCTestCase {
    func testAppExclusionsStartEmptyAndOnlyExplicitAdditionsSurviveUpgrade() throws {
        let domain = "RuSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.deniedApps.isEmpty)
        XCTAssertTrue(AutoSwitchPolicy.defaultDeniedApps.isEmpty)
        XCTAssertFalse(AutoSwitchPolicy.isDeniedApp("com.apple.Terminal", deniedApps: []))
        XCTAssertFalse(AutoSwitchPolicy.isDeniedApp("com.1password.1password", deniedApps: []))
        XCTAssertTrue(AutoSwitchPolicy.isDeniedApp("com.example.Explicit", deniedApps: ["com.example.*"]))
        defaults.set(["com.apple.Terminal"], forKey: "com.ruswitcher.deniedAppsRemoved")
        defaults.set(["com.example.Explicit"], forKey: "com.ruswitcher.deniedAppsAdded")
        XCTAssertEqual(SettingsManager(defaults: defaults).deniedApps, ["com.example.Explicit"])
        settings.deniedApps = ["com.example.Other"]
        XCTAssertEqual(defaults.stringArray(forKey: "com.ruswitcher.deniedAppsAdded"), ["com.example.Other"])
        XCTAssertEqual(SettingsManager(defaults: defaults).deniedApps, ["com.example.Other"])
    }

    func testExplicitAutoChoiceMigratesOnlyWhenNativeKeyIsMissing() throws {
        let domain = "RuSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "com.ruswitcher.autoConvert")
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.nativeAutoEnabled)
        XCTAssertNil(defaults.object(forKey: "com.macswitcher.nativeAutoEnabled"))
        settings.nativeAutoEnabled = false
        XCTAssertFalse(SettingsManager(defaults: defaults).nativeAutoEnabled)
    }
    func testExplicitAutoConvertChoiceEnablesNativePathAndOptOutPersists() throws {
        let domain = "RuSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let candidate = SettingsManager(defaults: defaults, nativeRolloutAccepted: false)
        candidate.autoConvert = true
        XCTAssertTrue(candidate.autoConvert)
        XCTAssertTrue(candidate.nativeAutoEnabled)
        candidate.autoConvert = false
        candidate.autoConvert = true
        XCTAssertTrue(candidate.nativeAutoEnabled)
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
