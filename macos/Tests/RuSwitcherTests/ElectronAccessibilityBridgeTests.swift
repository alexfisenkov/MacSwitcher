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
        var enableSucceeds = true
        var enabled: [Int32] = []
        lazy var bridge = ElectronAccessibilityBridge(platform: .init(
            notifications: notifications,
            frontmost: { [unowned self] in target },
            trusted: { [unowned self] in trusted },
            secureInputActive: { [unowned self] in secure },
            remoteDeferred: { [unowned self] in remote },
            electronFrameworkPresent: { [unowned self] _ in electron },
            enable: { [unowned self] in enabled.append($0); return enableSucceeds },
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

    func testEveryEligibilityGateRefusesSetter() {
        let gates: [(Rig) -> Void] = [
            { $0.trusted = false }, { $0.secure = true }, { $0.remote = true },
            { $0.electron = false }, { $0.target = nil },
            { $0.target = self.target(pid: 1) },
        ]
        for blocked in gates {
            let rig = Rig()
            rig.target = target()
            blocked(rig)
            rig.bridge.start()
            XCTAssertTrue(rig.enabled.isEmpty)
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
        rig.bridge.refresh()
        rig.bridge.refresh()
        XCTAssertEqual(rig.enabled, [2772, 2772])
        rig.bridge.stop()
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
