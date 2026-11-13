import AppKit
import XCTest
@testable import RuSwitcher

final class NativeSettingsMenuTests: XCTestCase {
    @MainActor
    func testHealthyStatusMenuIsCompactAndKeepsConditionalSourceRecoveryTags() throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let menu = AppDelegate().makeStatusMenu(nativeShiftApplied: true, automaticEnabled: false)
        XCTAssertNotNil(menu.item(withTag: 742)?.submenu)
        XCTAssertNotNil(menu.item(withTag: 71004))
        XCTAssertNotNil(menu.item(withTag: 71003))
        XCTAssertTrue(menu.item(withTag: 742)?.isHidden == true)
        XCTAssertTrue(menu.item(withTag: 71004)?.isHidden == true)
        XCTAssertTrue(menu.item(withTag: 71003)?.isHidden == true)
        XCTAssertTrue(menu.items.contains { $0.action == NSSelectorFromString("openSettings") })
        XCTAssertTrue(menu.items.contains { $0.action == NSSelectorFromString("openInstructions") })
        XCTAssertTrue(menu.items.contains { $0.action == NSSelectorFromString("openWords") })
        XCTAssertTrue(menu.items.contains { $0.action == NSSelectorFromString("quit") })
        let visible = menu.items.filter { !$0.isHidden }
        XCTAssertEqual(visible.filter { !$0.isSeparatorItem }.map(\.title), [
            L10n.menuAutoConvert, L10n.nativeInstructionsTab, L10n.nativeWordsTab,
            L10n.menuSettings, L10n.menuQuit])
        XCTAssertEqual(visible.filter(\.isSeparatorItem).count, 1)
    }

    @MainActor
    func testMigratedStatusMenuShowsEffectiveAutoWithoutLegacyMaster() {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let menu = AppDelegate().makeStatusMenu(nativeShiftApplied: true, automaticEnabled: false)
        XCTAssertEqual(menu.items.filter { $0.title == L10n.menuAutoConvert }.count, 1)
        XCTAssertEqual(menu.items.first?.state, .off)
        XCTAssertFalse(menu.items.contains { $0.title == L10n.menuAutoSwitch })
    }

    @MainActor
    func testLegacyFallbackStillExposesMasterAndInputSource() {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let menu = AppDelegate().makeStatusMenu(nativeShiftApplied: false, automaticEnabled: false)
        XCTAssertTrue(menu.items.contains { $0.action == NSSelectorFromString("toggleAutoSwitch:") })
        XCTAssertFalse(menu.item(withTag: 742)?.isHidden ?? true)
    }
}
