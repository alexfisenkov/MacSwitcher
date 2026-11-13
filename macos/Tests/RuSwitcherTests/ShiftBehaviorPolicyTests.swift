import XCTest
@testable import RuSwitcher

final class ShiftBehaviorPolicyTests: XCTestCase {
    private func fixture() throws -> (UserDefaults, URL, () -> Void) {
        let domain = "ShiftBehaviorPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        return (defaults, directory, {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    func testVerifiedMigrationPreservesRawValuesAndSeparatesEffectiveGates() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set(false, forKey: "com.ruswitcher.autoSwitch")
        defaults.set(false, forKey: "com.ruswitcher.combinedShiftEnabled")
        defaults.set(true, forKey: "com.ruswitcher.autoConvert")
        defaults.set(true, forKey: "com.ruswitcher.perAppLayout")
        defaults.set("capsLock", forKey: "com.ruswitcher.triggerKey")
        defaults.set("source.en", forKey: "com.ruswitcher.layout1ID")
        defaults.set("source.ru", forKey: "com.ruswitcher.layout2ID")
        defaults.set(200, forKey: "com.macswitcher.doubleShiftIntervalMilliseconds")
        defaults.set(false, forKey: "com.macswitcher.nativeAutoEnabled")
        defaults.set(true, forKey: "com.macswitcher.shellBridgeEnabled")
        let settings = SettingsManager(defaults: defaults)
        XCTAssertFalse(settings.manualShiftEnabled)
        XCTAssertFalse(settings.automaticTextEnabled)
        XCTAssertFalse(settings.perAppBackgroundEnabled)
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        XCTAssertTrue(settings.manualShiftEnabled)
        XCTAssertFalse(settings.automaticTextEnabled)
        XCTAssertFalse(settings.perAppBackgroundEnabled)
        XCTAssertFalse(settings.legacyGestureBindingsEnabled)
        XCTAssertEqual(settings.layout1ID, "source.en")
        XCTAssertEqual(settings.layout2ID, "source.ru")
        XCTAssertEqual(settings.doubleShiftIntervalMilliseconds, 200)
        XCTAssertFalse(settings.nativeAutoEnabled)
        XCTAssertTrue(settings.shellBridgeEnabled)
        XCTAssertEqual(defaults.string(forKey: "com.ruswitcher.triggerKey"), "capsLock")
        XCTAssertFalse(defaults.bool(forKey: "com.ruswitcher.autoSwitch"))
        settings.automaticTextEnabled = true
        XCTAssertTrue(settings.automaticTextEnabled)
        XCTAssertTrue(settings.nativeAutoEnabled)
        XCTAssertFalse(settings.perAppBackgroundEnabled)
        XCTAssertTrue(settings.manualShiftEnabled)
        settings.automaticTextEnabled = false
        XCTAssertTrue(settings.manualShiftEnabled)
    }

    func testBackupFailureLeavesLegacyBehaviorAndDoesNotWriteMarker() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set(false, forKey: "com.ruswitcher.autoSwitch")
        defaults.set("option", forKey: "com.ruswitcher.triggerKey")
        try Data("not a directory".utf8).write(to: directory)
        let settings = SettingsManager(defaults: defaults)
        XCTAssertFalse(settings.activateNativeShift(backupDirectory: directory))
        XCTAssertFalse(settings.manualShiftEnabled)
        XCTAssertTrue(settings.legacyGestureBindingsEnabled)
        XCTAssertNil(defaults.object(forKey: "com.macswitcher.nativeShiftMigrationVersion"))
    }

    func testBackupIsIdempotentAndRetainsAbsentAndWrongTypeKeys() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set(42, forKey: "com.ruswitcher.triggerRightOnly")
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        let backup = try Data(contentsOf: ShiftBehaviorPolicy.backupURL(in: directory))
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        XCTAssertEqual(backup, try Data(contentsOf: ShiftBehaviorPolicy.backupURL(in: directory)))
        let entries = try ShiftBehaviorPolicy.backupEntries(at: ShiftBehaviorPolicy.backupURL(in: directory))
        XCTAssertEqual(entries["com.ruswitcher.triggerRightOnly"]?.type, "integer")
        XCTAssertEqual(entries["com.ruswitcher.caseHotkey"]?.type, "absent")
    }

    func testMigratedTriggerUsesBothShiftSidesAndDisablesLegacyAlternatives() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set("capsLock", forKey: "com.ruswitcher.triggerKey")
        defaults.set(true, forKey: "com.ruswitcher.triggerRightOnly")
        defaults.set("option", forKey: "com.ruswitcher.switchHotkey")
        defaults.set("command", forKey: "com.ruswitcher.caseHotkey")
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(TriggerConfig.current(settings: settings).isCapsLock)
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        let trigger = TriggerConfig.current(settings: settings)
        XCTAssertTrue(trigger.isShift)
        XCTAssertFalse(trigger.rightOnly)
        XCTAssertFalse(trigger.doubleTap)
        XCTAssertFalse(trigger.isCapsLock)
        XCTAssertNil(TriggerConfig.switchHotkey(settings: settings))
        XCTAssertNil(TriggerConfig.caseHotkey(settings: settings))
    }

    func testSymlinkedBackupDirectoryRefusesBeforeWritingOrMarkingMigration() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        let settings = SettingsManager(defaults: defaults)
        XCTAssertFalse(settings.activateNativeShift(backupDirectory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShiftBehaviorPolicy.backupURL(in: target).path))
        XCTAssertNil(defaults.object(forKey: ShiftBehaviorPolicy.markerKey))
    }

    func testCommittedModeKeepsShiftAndV2ChoicesWhenBackupBecomesUnavailable() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set(true, forKey: "com.ruswitcher.autoSwitch")
        defaults.set(true, forKey: "com.ruswitcher.autoConvert")
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        settings.automaticTextEnabled = false
        settings.perAppBackgroundEnabled = true
        let backup = ShiftBehaviorPolicy.backupURL(in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backup.path)
        func assertCommittedMode() {
            let next = SettingsManager(defaults: defaults)
            XCTAssertTrue(next.activateNativeShift(backupDirectory: directory))
            XCTAssertFalse(next.nativeShiftBackupVerified)
            XCTAssertTrue(next.manualShiftEnabled)
            XCTAssertFalse(next.automaticTextEnabled)
            XCTAssertTrue(next.perAppBackgroundEnabled)
            XCTAssertFalse(next.legacyGestureBindingsEnabled)
        }
        assertCommittedMode()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        XCTAssertTrue(SettingsManager(defaults: defaults).activateNativeShift(backupDirectory: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        assertCommittedMode()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var bytes = try Data(contentsOf: backup)
        bytes.append(0)
        try bytes.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        assertCommittedMode()
        try FileManager.default.removeItem(at: backup)
        assertCommittedMode()
    }

    func testOrphanSnapshotDoesNotBindChangedLegacyPreferences() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set(false, forKey: "com.ruswitcher.autoSwitch")
        defaults.set(false, forKey: "com.ruswitcher.autoConvert")
        XCTAssertTrue(SettingsManager(defaults: defaults).activateNativeShift(backupDirectory: directory))
        let orphanURL = ShiftBehaviorPolicy.backupURL(in: directory)
        let orphanData = try Data(contentsOf: orphanURL)
        for key in [ShiftBehaviorPolicy.markerKey, ShiftBehaviorPolicy.backupDigestKey,
            ShiftBehaviorPolicy.automaticBaselineKey, ShiftBehaviorPolicy.perAppBaselineKey] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: "com.ruswitcher.autoSwitch")
        defaults.set(true, forKey: "com.ruswitcher.autoConvert")
        defaults.set(true, forKey: "com.ruswitcher.perAppLayout")
        let next = SettingsManager(defaults: defaults)
        XCTAssertTrue(next.activateNativeShift(backupDirectory: directory))
        XCTAssertTrue(next.automaticTextEnabled)
        XCTAssertTrue(next.perAppBackgroundEnabled)
        XCTAssertEqual(try Data(contentsOf: orphanURL), orphanData)
        let activeURL = ShiftBehaviorPolicy.activeBackupURL(defaults: defaults, directory: directory)
        XCTAssertNotEqual(activeURL, orphanURL)
        let activeEntries = try ShiftBehaviorPolicy.backupEntries(at: activeURL)
        XCTAssertEqual(activeEntries["com.ruswitcher.autoSwitch"]?.type, "boolean")
    }

    func testSymlinkedAncestorAndLooseExistingDirectoryRefuseWithoutMutation() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        let parent = directory.appendingPathComponent("parent")
        let target = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: target)
        let nested = parent.appendingPathComponent("migration")
        XCTAssertFalse(SettingsManager(defaults: defaults).activateNativeShift(backupDirectory: nested))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("migration").path))
        let existing = directory.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)
        XCTAssertFalse(SettingsManager(defaults: defaults).activateNativeShift(backupDirectory: existing))
        let existingAttributes = try FileManager.default.attributesOfItem(atPath: existing.path)
        XCTAssertEqual((existingAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertNil(defaults.object(forKey: ShiftBehaviorPolicy.markerKey))
    }

    func testOversizedValidBackupCannotBeReadButCommittedChoicesRemainActive() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        defaults.set(true, forKey: "com.ruswitcher.autoSwitch")
        defaults.set(true, forKey: "com.ruswitcher.autoConvert")
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.activateNativeShift(backupDirectory: directory))
        settings.automaticTextEnabled = false
        let url = ShiftBehaviorPolicy.activeBackupURL(defaults: defaults, directory: directory)
        let original = try Data(contentsOf: url)
        XCTAssertLessThan(original.count, 16 * 1024)
        var payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: original,
            format: nil) as? [String: Any])
        payload["padding"] = Data(repeating: 0x5A, count: ShiftBehaviorPolicy.maxBackupBytes)
        let oversized = try PropertyListSerialization.data(fromPropertyList: payload,
            format: .binary, options: 0)
        XCTAssertGreaterThan(oversized.count, ShiftBehaviorPolicy.maxBackupBytes)
        try oversized.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertThrowsError(try ShiftBehaviorPolicy.backupEntries(at: url))
        let next = SettingsManager(defaults: defaults)
        XCTAssertTrue(next.activateNativeShift(backupDirectory: directory))
        XCTAssertFalse(next.nativeShiftBackupVerified)
        XCTAssertTrue(next.manualShiftEnabled)
        XCTAssertFalse(next.automaticTextEnabled)
    }

    func testOversizedInitialSnapshotLeavesLegacyModeWithoutTruncatingRawPreference() throws {
        let (defaults, directory, cleanup) = try fixture()
        defer { cleanup() }
        let value = String(repeating: "x", count: ShiftBehaviorPolicy.maxBackupBytes + 1)
        defaults.set(value, forKey: "com.ruswitcher.triggerKey")
        let settings = SettingsManager(defaults: defaults)
        XCTAssertFalse(settings.activateNativeShift(backupDirectory: directory))
        XCTAssertTrue(settings.legacyGestureBindingsEnabled)
        XCTAssertNil(defaults.object(forKey: ShiftBehaviorPolicy.markerKey))
        XCTAssertEqual(defaults.string(forKey: "com.ruswitcher.triggerKey"), value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShiftBehaviorPolicy.backupURL(in: directory).path))
    }
}
