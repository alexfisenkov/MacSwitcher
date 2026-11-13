import AppKit
import XCTest
@testable import RuSwitcher

@MainActor
final class ElectronAccessibilityBridgeTests: XCTestCase {
    @MainActor private final class Rig {
        let notifications = NotificationCenter()
        var target: ElectronAccessibilityBridge.Target?
        var trusted = true
        var secure = false
        var remote = false
        var electron = true
        var roleSucceeds = true
        var roleReads: [Int32] = []
        var afterRoleRead: (() -> Void)?
        var afterFrameworkProbe: (() -> Void)?
        var clock: TimeInterval = 0
        var enableSucceeds = true
        var enabled: [Int32] = []
        lazy var bridge = ElectronAccessibilityBridge(platform: .init(
            notifications: notifications,
            frontmost: { [unowned self] in target },
            trusted: { [unowned self] in trusted },
            secureInputActive: { [unowned self] in secure },
            remoteDeferred: { [unowned self] in remote },
            electronFrameworkPresent: { [unowned self] _ in
                afterFrameworkProbe?()
                return electron
            },
            readApplicationRole: { [unowned self] in
                roleReads.append($0)
                afterRoleRead?()
                return roleSucceeds
            },
            enable: { [unowned self] in enabled.append($0); return enableSucceeds },
            now: { [unowned self] in clock },
            ownProcessID: 1))

        func activate(_ target: ElectronAccessibilityBridge.Target?) {
            self.target = target
            notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        }

        func sync(monitoring: Bool, autoSwitch: Bool) {
            if ElectronAccessibilityBridge.shouldRun(monitoringActive: monitoring,
                    autoSwitchEnabled: autoSwitch) {
                bridge.start()
            } else {
                bridge.stop()
            }
        }
    }

    private func target(pid: Int32 = 2772, bundleID: String = "com.anthropic.claudefordesktop")
        -> ElectronAccessibilityBridge.Target {
        .init(processID: pid, bundleIdentifier: bundleID,
              bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"),
              launchDate: Date(timeIntervalSince1970: 1))
    }

    func testStartupAndActivationPrepareOnlyCurrentElectronOnceWithoutCaretFlag() {
        let rig = Rig()
        rig.target = target()
        rig.bridge.start()
        XCTAssertEqual(rig.enabled, [2772])
        rig.bridge.start()
        rig.activate(target())
        XCTAssertEqual(rig.enabled, [2772])

        rig.electron = false
        rig.activate(target(pid: 3000, bundleID: "com.apple.TextEdit"))
        XCTAssertEqual(rig.enabled, [2772])
        rig.electron = true
        rig.activate(target())
        XCTAssertEqual(rig.enabled, [2772, 2772])

        rig.bridge.stop()
        rig.activate(target(pid: 4000))
        XCTAssertEqual(rig.enabled, [2772, 2772])
    }

    func testNonElectronBrandedAppGetsReadOnlyRolePreparationWithoutManualSetter() {
        let rig = Rig()
        rig.electron = false
        rig.target = target(bundleID: "org.example.branded")
        rig.bridge.start()
        XCTAssertEqual(rig.roleReads, [2772])
        XCTAssertTrue(rig.enabled.isEmpty)
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772], "successful preparation is idempotent")
    }

    func testRoleFailureRetriesOnExistingPollAndGateResumeRepreparesSameTarget() {
        let rig = Rig()
        rig.electron = false
        rig.roleSucceeds = false
        rig.target = target(bundleID: "org.example.branded")
        rig.bridge.start()
        XCTAssertEqual(rig.roleReads, [2772])
        rig.clock = 1
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772], "one bounded attempt per poll window")
        rig.roleSucceeds = true
        rig.clock = 2
        rig.bridge.refresh()
        rig.clock = 4
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772, 2772])
        rig.secure = true
        rig.bridge.refresh()
        rig.secure = false
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772, 2772, 2772], "cleared gate re-prepares same target")
        XCTAssertTrue(rig.enabled.isEmpty)
    }

    func testTrustGateClosureRetiresSuccessfulReceiptUntilRestored() {
        let rig = Rig()
        rig.electron = false
        rig.target = target(bundleID: "org.example.branded")
        rig.bridge.start()
        XCTAssertEqual(rig.roleReads, [2772])
        rig.trusted = false
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772])
        rig.trusted = true
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772, 2772])
        XCTAssertTrue(rig.enabled.isEmpty)
    }

    func testEveryEligibilityGateRefusesSetter() {
        let gates: [(Rig) -> Void] = [
            { $0.trusted = false }, { $0.secure = true }, { $0.remote = true },
            { $0.target = nil },
            { $0.target = self.target(pid: 1) },
        ]
        for blocked in gates {
            let rig = Rig()
            rig.target = target()
            blocked(rig)
            rig.bridge.start()
            XCTAssertTrue(rig.enabled.isEmpty)
            XCTAssertTrue(rig.roleReads.isEmpty)
            rig.bridge.stop()
        }
    }

    func testStoppedBridgeCannotEnableLaterActivatedApp() {
        let rig = Rig()
        rig.bridge.start()
        rig.bridge.stop()
        rig.activate(target())
        XCTAssertTrue(rig.enabled.isEmpty)
    }

    func testSecureInputRefusalRetriesSameAppAfterGateClears() {
        let rig = Rig()
        rig.target = target()
        rig.secure = true
        rig.bridge.start()
        XCTAssertTrue(rig.enabled.isEmpty)
        rig.secure = false
        rig.bridge.refresh()
        rig.bridge.refresh()
        XCTAssertEqual(rig.enabled, [2772])
        rig.bridge.stop()
    }

    func testNoFrontmostAppRetiresSuccessfulActivation() {
        let rig = Rig()
        rig.target = target()
        rig.bridge.start()
        rig.activate(nil)
        rig.activate(target())
        XCTAssertEqual(rig.enabled, [2772, 2772])
        rig.bridge.stop()
    }

    func testFailedSetterRetriesSameAppOnRefresh() {
        let rig = Rig()
        rig.target = target()
        rig.enableSucceeds = false
        rig.bridge.start()
        XCTAssertEqual(rig.enabled, [2772])
        rig.enableSucceeds = true
        rig.clock = 2
        rig.bridge.refresh()
        rig.bridge.refresh()
        XCTAssertEqual(rig.enabled, [2772, 2772])
        rig.bridge.stop()
    }

    func testLegacyElectronSetterRemainsRequiredWhenRoleReadFails() {
        let rig = Rig()
        rig.target = target()
        rig.roleSucceeds = false
        rig.bridge.start()
        XCTAssertEqual(rig.roleReads, [2772])
        XCTAssertEqual(rig.enabled, [2772])
        rig.clock = 2
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772])
        XCTAssertEqual(rig.enabled, [2772])
    }

    func testGenericAppWithoutBundleURLUsesOnlyReadOnlyRoleProbe() {
        let rig = Rig()
        rig.electron = false
        rig.target = .init(processID: 2772, bundleIdentifier: "org.example.generic",
            bundleURL: nil, launchDate: Date(timeIntervalSince1970: 1))
        rig.bridge.start()
        XCTAssertEqual(rig.roleReads, [2772])
        XCTAssertTrue(rig.enabled.isEmpty)
    }

    func testForegroundChangeDuringRoleProbeNeverCallsLegacySetter() {
        let rig = Rig()
        rig.target = target()
        rig.afterRoleRead = { rig.target = self.target(pid: 3000) }
        rig.bridge.start()
        XCTAssertEqual(rig.roleReads, [2772])
        XCTAssertTrue(rig.enabled.isEmpty)
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772, 3000])
    }

    func testSamePIDNewActivationIdentityDoesNotInheritOldRoleReceipt() {
        let rig = Rig()
        rig.target = target()
        rig.afterRoleRead = {
            rig.target = .init(processID: 2772, bundleIdentifier: "org.example.relaunched",
                bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
                launchDate: Date(timeIntervalSince1970: 2))
        }
        rig.bridge.start()
        XCTAssertEqual(rig.roleReads, [2772])
        XCTAssertTrue(rig.enabled.isEmpty)
    }

    func testUnknownLaunchIdentityNeverSetsLegacyFlagOrCachesRoleSuccess() {
        let rig = Rig()
        rig.target = .init(processID: 2772, bundleIdentifier: "org.example.unknownlaunch",
            bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"), launchDate: nil)
        rig.bridge.start()
        XCTAssertEqual(rig.roleReads, [2772])
        XCTAssertTrue(rig.enabled.isEmpty)
        rig.clock = 1
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772])
        rig.clock = 2
        rig.bridge.refresh()
        XCTAssertEqual(rig.roleReads, [2772, 2772])
        XCTAssertTrue(rig.enabled.isEmpty)
    }

    func testKnownNewLaunchDateReprimesSamePIDBundleAndPath() {
        let rig = Rig()
        let first = target()
        rig.target = first
        rig.bridge.start()
        let second = ElectronAccessibilityBridge.Target(processID: first.processID,
            bundleIdentifier: first.bundleIdentifier, bundleURL: first.bundleURL,
            launchDate: Date(timeIntervalSince1970: 2))
        rig.activate(second)
        XCTAssertEqual(rig.roleReads, [2772, 2772])
        XCTAssertEqual(rig.enabled, [2772, 2772])
    }

    func testForegroundChangeDuringLegacyFrameworkProbeSkipsSetter() {
        let rig = Rig()
        rig.target = target()
        rig.afterFrameworkProbe = { rig.target = self.target(pid: 3000) }
        rig.bridge.start()
        XCTAssertEqual(rig.roleReads, [2772])
        XCTAssertTrue(rig.enabled.isEmpty)
    }

    func testReturningToPreviouslyPreparedAppAfterOtherAppFailureReprimesIt() {
        let rig = Rig()
        rig.electron = false
        let first = target(pid: 2772, bundleID: "org.example.first")
        let second = target(pid: 3000, bundleID: "org.example.second")
        rig.target = first
        rig.bridge.start()
        rig.roleSucceeds = false
        rig.activate(second)
        rig.roleSucceeds = true
        rig.activate(first)
        XCTAssertEqual(rig.roleReads, [2772, 3000, 2772])
        XCTAssertTrue(rig.enabled.isEmpty)
    }

    func testGateClosingDuringRoleReadPreventsSetterAndSuccessCaching() {
        let closeGate: [(Rig) -> Void] = [
            { $0.trusted = false }, { $0.secure = true }, { $0.remote = true }
        ]
        for close in closeGate {
          for legacyElectron in [false, true] {
            let rig = Rig()
            rig.electron = legacyElectron
            rig.target = target(bundleID: "org.example.active")
            rig.afterRoleRead = { close(rig) }
            rig.bridge.start()
            XCTAssertEqual(rig.roleReads, [2772])
            XCTAssertTrue(rig.enabled.isEmpty)
            rig.afterRoleRead = nil
            rig.trusted = true
            rig.secure = false
            rig.remote = false
            rig.bridge.refresh()
            XCTAssertEqual(rig.roleReads, [2772, 2772])
            XCTAssertEqual(rig.enabled, legacyElectron ? [2772] : [])
          }
        }
    }

    func testGlobalAutoSwitchToggleControlsBridgeLifecycle() {
        let rig = Rig()
        rig.target = target()
        rig.sync(monitoring: true, autoSwitch: false)
        XCTAssertTrue(rig.enabled.isEmpty)
        rig.sync(monitoring: true, autoSwitch: true)
        XCTAssertEqual(rig.enabled, [2772])
        rig.sync(monitoring: true, autoSwitch: false)
        rig.activate(target(pid: 3000))
        XCTAssertEqual(rig.enabled, [2772])
        rig.sync(monitoring: true, autoSwitch: true)
        XCTAssertEqual(rig.enabled, [2772, 3000])
        rig.sync(monitoring: false, autoSwitch: true)
        rig.bridge.refresh()
        XCTAssertEqual(rig.enabled, [2772, 3000])
    }
}
