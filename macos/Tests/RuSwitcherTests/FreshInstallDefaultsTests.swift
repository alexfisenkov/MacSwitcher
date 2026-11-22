import XCTest
@testable import RuSwitcher

/// New defaults (automatic correction, strict icon, short menu) reach only installs that
/// had neither answered the launch-at-login prompt nor seen the auto-correction offer.
final class FreshInstallDefaultsTests: XCTestCase {
    private func fixture() throws -> (UserDefaults, URL, () -> Void) {
        let domain = "FreshInstallDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        return (defaults, directory, {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    func testNewInstallStartsWithAutomaticCorrectionStrictIconAndShortMenu() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        XCTAssertTrue(settings.freshInstallProfile)
        XCTAssertTrue(settings.automaticTextEnabled)
        XCTAssertTrue(settings.monochromeIcon)
        XCTAssertTrue(settings.compactMenu)
    }

    func testExistingUserWithAutomaticOffKeepsEverythingAsBefore() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set(true, forKey: "com.ruswitcher.launchAtLoginAsked")
        defaults.set(true, forKey: "com.ruswitcher.autoConvertOffered")
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        XCTAssertFalse(settings.freshInstallProfile)
        XCTAssertFalse(settings.automaticTextEnabled)
        XCTAssertFalse(settings.monochromeIcon)
        XCTAssertFalse(settings.compactMenu)
    }

    func testEitherOnboardingFlagMarksAnExistingInstall() throws {
        for key in ["com.ruswitcher.launchAtLoginAsked", "com.ruswitcher.autoConvertOffered"] {
            let (defaults, directory, cleanup) = try fixture()
            defer { cleanup() }
            defaults.set(true, forKey: key)
            let settings = SettingsManager(defaults: defaults)
            XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
            XCTAssertFalse(settings.freshInstallProfile, key)
            XCTAssertFalse(settings.automaticTextEnabled, key)
            XCTAssertFalse(settings.compactMenu, key)
        }
    }

    func testAlreadyMigratedExistingUserIsNotReclassifiedOnUpgrade() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set(true, forKey: "com.ruswitcher.launchAtLoginAsked")
        XCTAssertTrue(ShiftBehaviorPolicy.activate(defaults: defaults, directory: directory).applied)
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        XCTAssertFalse(settings.automaticTextEnabled)
        XCTAssertFalse(settings.compactMenu)
    }

    func testNewInstallChoicesSurviveLaterLaunches() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        let first = SettingsManager(defaults: defaults)
        XCTAssertTrue(first.activateNativeShift(backupDirectory: directory))
        first.automaticTextEnabled = false
        first.compactMenu = false
        first.monochromeIcon = false
        let next = SettingsManager(defaults: defaults)
        XCTAssertTrue(next.activateNativeShift(backupDirectory: directory))
        XCTAssertTrue(next.freshInstallProfile)
        XCTAssertFalse(next.automaticTextEnabled)
        XCTAssertFalse(next.compactMenu)
        XCTAssertFalse(next.monochromeIcon)
    }

    func testExplicitEarlierChoicesWinOverNewDefaults() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set(false, forKey: "com.ruswitcher.autoConvert")
        defaults.set(false, forKey: "com.ruswitcher.monochromeIcon")
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        XCTAssertFalse(settings.automaticTextEnabled)
        XCTAssertFalse(settings.monochromeIcon)
    }
}
