import AppKit
import XCTest
@testable import RuSwitcher

final class WelcomeWindowTests: XCTestCase {
    func testNewInstallGetsWelcomeInsteadOfBareSystemPromptsAndAlerts() {
        XCTAssertEqual(FirstRunPlan.decide(freshProfile: true, welcomeCompleted: false,
            accessibility: false, inputMonitoring: false, permissionsWereGranted: false), .welcome)
        // Even with both permissions already present, the toggles are offered once.
        XCTAssertEqual(FirstRunPlan.decide(freshProfile: true, welcomeCompleted: false,
            accessibility: true, inputMonitoring: true, permissionsWereGranted: true), .welcome)
        // Closed early or revoked later: the same explaining screen, never a bare request.
        XCTAssertEqual(FirstRunPlan.decide(freshProfile: true, welcomeCompleted: true,
            accessibility: true, inputMonitoring: false, permissionsWereGranted: true), .welcome)
        XCTAssertEqual(FirstRunPlan.decide(freshProfile: true, welcomeCompleted: true,
            accessibility: true, inputMonitoring: true, permissionsWereGranted: true), .start)
        XCTAssertFalse(FirstRunPlan.offersLegacyPrompts(freshProfile: true))
    }

    func testExistingInstallKeepsPreviousFirstRunBehaviour() {
        XCTAssertEqual(FirstRunPlan.decide(freshProfile: false, welcomeCompleted: false,
            accessibility: true, inputMonitoring: true, permissionsWereGranted: false), .start)
        XCTAssertEqual(FirstRunPlan.decide(freshProfile: false, welcomeCompleted: false,
            accessibility: false, inputMonitoring: true, permissionsWereGranted: true), .permissionsReset)
        XCTAssertEqual(FirstRunPlan.decide(freshProfile: false, welcomeCompleted: false,
            accessibility: false, inputMonitoring: false, permissionsWereGranted: false), .legacyWizard)
        XCTAssertTrue(FirstRunPlan.offersLegacyPrompts(freshProfile: false))
    }

    @MainActor
    func testWelcomeExplainsBothPermissionsOffersTogglesAndSeesGrants() throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let controller = WelcomeWindowController()
        var opened: [WelcomePermission] = []
        var automatic: [Bool] = []
        var login: [Bool] = []
        var finished = 0
        controller.onOpenSettings = { opened.append($0) }
        controller.onAutomaticCorrectionChanged = { automatic.append($0) }
        controller.onLaunchAtLoginChanged = { login.append($0) }
        controller.onFinish = { finished += 1 }
        let root = controller.makeContent(accessibility: false, inputMonitoring: false,
            automaticCorrection: true, launchAtLogin: false)
        let texts = descendants(of: root).compactMap { ($0 as? NSTextField)?.stringValue }
        for expected in [L10n.welcomeAccessibilityTitle, L10n.welcomeAccessibilityText,
            L10n.welcomeInputMonitoringTitle, L10n.welcomeInputMonitoringText, L10n.menuAutoConvert,
            L10n.welcomeLaunchAtLogin] {
            XCTAssertTrue(texts.contains(expected), "missing \(expected)")
        }
        XCTAssertEqual(texts.filter { $0 == L10n.welcomeMissing }.count, 2)

        let buttons = descendants(of: root).compactMap { $0 as? NSButton }
        let open = buttons.filter { $0.title == L10n.welcomeOpenSettings }
        XCTAssertEqual(open.count, 2)
        open.forEach { $0.performClick(nil) }
        XCTAssertEqual(opened, [.accessibility, .inputMonitoring])

        let switches = descendants(of: root).compactMap { $0 as? NSSwitch }
        XCTAssertEqual(switches.count, 2)
        XCTAssertEqual(switches.map(\.state), [.on, .off])
        switches[0].performClick(nil)
        switches[1].performClick(nil)
        XCTAssertEqual(automatic, [false])
        XCTAssertEqual(login, [true])

        controller.update(accessibility: true, inputMonitoring: false)
        var statuses = descendants(of: root).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(statuses.filter { $0 == L10n.welcomeGranted }.count, 1)
        XCTAssertFalse(open[0].isEnabled)
        XCTAssertTrue(open[1].isEnabled)
        controller.update(accessibility: true, inputMonitoring: true)
        statuses = descendants(of: root).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(statuses.filter { $0 == L10n.welcomeGranted }.count, 2)

        try XCTUnwrap(buttons.first { $0.title == L10n.welcomeDone }).performClick(nil)
        XCTAssertEqual(finished, 1)
    }

    func testRussianPermissionNamesAndLearningPath() throws {
        let key = "com.ruswitcher.interfaceLanguage"
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set("ru", forKey: key)
        L10n.reloadLanguage()
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            L10n.reloadLanguage()
        }
        XCTAssertEqual(L10n.welcomeAccessibilityTitle, "Универсальный доступ")
        XCTAssertEqual(L10n.welcomeInputMonitoringTitle, "Мониторинг ввода")
        for text in [L10n.permissionsResetBody, L10n.permissionsOkText] {
            XCTAssertTrue(text.contains("Универсальный доступ"), text)
            XCTAssertTrue(text.contains("Мониторинг ввода"), text)
            XCTAssertFalse(text.contains("Accessibility"), text)
            XCTAssertFalse(text.contains("Input Monitoring"), text)
        }
        XCTAssertTrue(L10n.adaptiveIntroBody.contains(
            "«\(L10n.nativeWordsTab) → \(L10n.nativeLearningEntry)»"))
        XCTAssertFalse(L10n.adaptiveIntroBody.contains("Настройки → Обучение"))
        UserDefaults.standard.set("en", forKey: key)
        L10n.reloadLanguage()
        XCTAssertTrue(L10n.adaptiveIntroBody.contains("Remembered corrections"))
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
