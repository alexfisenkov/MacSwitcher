import AppKit
import XCTest
@testable import RuSwitcher

/// Everyday settings on the main pane, rare ones in «More», one column for every pane.
final class SettingsLayoutTests: XCTestCase {
    private var priorPolicy: NSApplication.ActivationPolicy = .prohibited

    @MainActor
    override func setUp() async throws {
        priorPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    @MainActor
    override func tearDown() async throws {
        NSApplication.shared.setActivationPolicy(priorPolicy)
    }

    @MainActor
    func testMainSettingsPaneShowsOnlyEverydayControlsAndIconChoice() throws {
        let tabs = SettingsWindowController().makeNativeTabs(nativeShiftApplied: true)
        let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
        let controls = descendants(of: settings.tabViewItem(at: 0).view!)
            .compactMap { $0 as? NSControl }.filter { $0.action != nil && !($0 is NSScroller) }
        let actions = controls.compactMap { $0.action.map(NSStringFromSelector) }
        for action in ["autoConvertSwitchChanged:", "languageChanged:", "layout1Changed:",
            "layout2Changed:", "launchAtLoginChanged:", "checkUpdatesEnabledChanged:",
            "statusIconStyleChanged:", "openSupportSettings"] {
            XCTAssertTrue(actions.contains(action), "missing \(action)")
        }
        for hidden in ["triggerChanged:", "switchHotkeyChanged:", "caseHotkeyChanged:",
            "combinedShiftChanged:", "doubleShiftIntervalChanged:", "monochromeIconChanged:"] {
            XCTAssertFalse(actions.contains(hidden), "unexpected \(hidden)")
        }
        XCTAssertLessThanOrEqual(controls.count, 8)
        let more = try XCTUnwrap(controls.compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("openSupportSettings") })
        XCTAssertEqual(more.title, L10n.settingsMoreEntry)
    }

    @MainActor
    func testIconChoiceOnMainPaneSwitchesBetweenBadgeAndFlag() throws {
        let key = "com.ruswitcher.monochromeIcon"
        let prior = UserDefaults.standard.object(forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: key)
        let controller = SettingsWindowController()
        var notified = 0
        controller.onStatusAppearanceChanged = { notified += 1 }
        let tabs = controller.makeNativeTabs(nativeShiftApplied: true)
        let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
        let popup = try XCTUnwrap(descendants(of: settings.tabViewItem(at: 0).view!)
            .compactMap { $0 as? NSPopUpButton }
            .first { $0.action == NSSelectorFromString("statusIconStyleChanged:") })
        XCTAssertEqual(popup.itemTitles, [L10n.settingsIconBadge, L10n.settingsIconFlag])
        XCTAssertEqual(popup.indexOfSelectedItem, 0)
        popup.selectItem(at: 1)
        _ = popup.target?.perform(popup.action, with: popup)
        XCTAssertFalse(SettingsManager.shared.monochromeIcon)
        XCTAssertEqual(notified, 1)
    }

    @MainActor
    func testMorePaneHasCheckAndExpertBlocksWithoutDuplicateLayoutChooser() throws {
        let controller = SettingsWindowController()
        var compactChanges = 0
        controller.onCompactMenuChanged = { compactChanges += 1 }
        let tabs = controller.makeNativeTabs(nativeShiftApplied: true)
        let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
        let pane = settings.tabViewItem(at: 1).view!
        func actions(inSection id: String) throws -> Set<String> {
            let box = try XCTUnwrap(descendants(of: pane).first { $0.identifier?.rawValue == id }, id)
            XCTAssertTrue(descendants(of: box).contains { ($0 as? NSTextField)?.stringValue
                == (id == "settings.section.check" ? L10n.settingsCheckSection : L10n.settingsExpertSection) })
            return Set(descendants(of: box).compactMap { ($0 as? NSControl)?.action.map(NSStringFromSelector) })
        }
        let check = try actions(inSection: "settings.section.check")
        for action in ["permissionCheckRequested", "updateCheckRequested", "openAboutSettings",
            "runtimeCheckRequested"] {
            XCTAssertTrue(check.contains(action), "check: missing \(action)")
        }
        let expert = try actions(inSection: "settings.section.expert")
        for action in ["shellBridgeChanged:", "shellBridgeSetupRequested", "doubleShiftIntervalChanged:",
            "recoveryOriginalsRequested", "recoveryArchiveFolderRequested", "recoveryArchiveChanged:",
            "perAppLayoutChanged:", "betaChannelChanged:", "compactMenuChanged:", "hideIconChanged:"] {
            XCTAssertTrue(expert.contains(action), "expert: missing \(action)")
        }
        let all = Set(descendants(of: pane).compactMap { ($0 as? NSControl)?.action.map(NSStringFromSelector) })
        XCTAssertFalse(all.contains("inputSourceRequested"))
        XCTAssertFalse(all.contains("monochromeIconChanged:"))

        let key = "com.macswitcher.compactMenu"
        let prior = UserDefaults.standard.object(forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        let toggle = try XCTUnwrap(descendants(of: pane).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("compactMenuChanged:") })
        XCTAssertEqual(toggle.title, L10n.settingsCompactMenu)
        toggle.performClick(nil)
        XCTAssertTrue(SettingsManager.shared.compactMenu)
        XCTAssertEqual(compactChanges, 1)
    }

    @MainActor
    func testEveryPaneSharesOneWidthAndLeftEdge() throws {
        let controller = SettingsWindowController()
        let tabs = controller.makeNativeTabs(nativeShiftApplied: true, backupVerified: true)
        let root = controller.makeSettingsContent(tabView: tabs)
        root.frame = NSRect(x: 0, y: 0, width: 600, height: 520)
        let words = try XCTUnwrap(tabs.tabViewItem(at: 1).view as? NSTabView)
        let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
        var panes: [(String, () -> NSView)] = [("instructions", {
            tabs.selectTabViewItem(at: 0); return tabs.tabViewItem(at: 0).view! })]
        for index in 0..<words.numberOfTabViewItems {
            panes.append(("words-\(index)", {
                tabs.selectTabViewItem(at: 1); words.selectTabViewItem(at: index)
                return words.tabViewItem(at: index).view! }))
        }
        for index in 0..<settings.numberOfTabViewItems {
            panes.append(("settings-\(index)", {
                tabs.selectTabViewItem(at: 2); settings.selectTabViewItem(at: index)
                return settings.tabViewItem(at: index).view! }))
        }
        for (name, select) in panes {
            let pane = select()
            root.layoutSubtreeIfNeeded()
            let frames = blocks(in: pane)
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
                .map { ($0, $0.convert($0.bounds, to: root)) }
            let left = try XCTUnwrap(frames.min { $0.1.minX < $1.1.minX }, name)
            let right = try XCTUnwrap(frames.max { $0.1.maxX < $1.1.maxX }, name)
            XCTAssertEqual(left.1.minX, 20, accuracy: 1, "\(name): \(type(of: left.0))")
            XCTAssertEqual(right.1.maxX, 580, accuracy: 1, "\(name): \(type(of: right.0))")
        }
    }

    @MainActor
    func testShiftKeysAreFlatPlatesNotButtons() throws {
        let tabs = SettingsWindowController().makeNativeTabs(nativeShiftApplied: true)
        let keycaps = descendants(of: tabs.tabViewItem(at: 0).view!)
            .filter { $0.identifier?.rawValue == "shift.keycap" }
        XCTAssertEqual(keycaps.count, 2)
        for keycap in keycaps {
            let box = try XCTUnwrap(keycap as? NSBox)
            XCTAssertEqual(box.borderWidth, 0)
            XCTAssertFalse(descendants(of: box).contains { $0 is NSButton })
            XCTAssertTrue(descendants(of: box).contains {
                ["⇧ Shift", "⇧ ×2"].contains(($0 as? NSTextField)?.stringValue ?? "") })
        }
    }

    @MainActor
    func testEachWordsItemHasAnExplanationUnderIt() throws {
        let tabs = SettingsWindowController().makeNativeTabs(nativeShiftApplied: true)
        let words = try XCTUnwrap(tabs.tabViewItem(at: 1).view as? NSTabView)
        let overview = words.tabViewItem(at: 0).view!
        let buttons = descendants(of: overview).compactMap { $0 as? NSButton }
            .filter { $0.action == NSSelectorFromString("openWordEditor:") }.sorted { $0.tag < $1.tag }
        let details = descendants(of: overview).compactMap { $0 as? NSTextField }
            .filter { $0.identifier?.rawValue == "words.row.detail" }
        XCTAssertEqual(buttons.count, 5)
        XCTAssertEqual(Set(details.map(\.stringValue)), Set([L10n.wordsDictionaryDetail,
            L10n.wordsNeverDetail, L10n.wordsAlwaysDetail, L10n.wordsAppsDetail,
            L10n.wordsLearningDetail]))
        for button in buttons {
            let detail = try XCTUnwrap(details.first { $0.superview === button.superview })
            XCTAssertLessThanOrEqual(detail.frame.maxY, button.frame.minY + 1, button.title)
        }
    }

    /// Visible building blocks: controls and groups as wholes, a table by its scroll frame.
    @MainActor
    private func blocks(in view: NSView) -> [NSView] {
        if view is NSScroller { return [] }
        if view is NSControl { return [view] }
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return [scroll] }
        let nested = view.subviews.flatMap { blocks(in: $0) }
        return view is NSBox ? [view] + nested : nested
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
