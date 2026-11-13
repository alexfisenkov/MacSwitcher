import AppKit
import XCTest
@testable import RuSwitcher

final class SettingsNavigationTests: XCTestCase {
    @MainActor
    func testNativeSettingsHaveThreeTopTabsWithInstructionsFirst() throws {
        let prior = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(prior) }
        let controller = SettingsWindowController()
        let tabs = controller.makeNativeTabs(nativeShiftApplied: true)
        XCTAssertEqual(tabs.numberOfTabViewItems, 3)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), [L10n.nativeInstructionsTab,
            L10n.nativeWordsTab, L10n.nativeSettingsTab])
        XCTAssertTrue(tabs.selectedTabViewItem === tabs.tabViewItem(at: 0))
        let root = controller.makeSettingsContent(tabView: tabs)
        XCTAssertFalse(descendants(of: root).contains { $0 is NSSplitView || $0 is NSTableView })
        XCTAssertEqual(descendants(of: root).compactMap { $0 as? NSButton }
            .filter { $0.action == NSSelectorFromString("topButtonChanged:") }.count, 3)
        XCTAssertTrue(descendants(of: tabs.tabViewItem(at: 0).view!).contains {
            ($0 as? NSTextField)?.stringValue.contains("ghbdtn → привет") == true
        })
        let words = try XCTUnwrap(tabs.tabViewItem(at: 1).view as? NSTabView)
        XCTAssertEqual(words.numberOfTabViewItems, 4)
        XCTAssertTrue(words.selectedTabViewItem === words.tabViewItem(at: 0))
        XCTAssertEqual(descendants(of: words.tabViewItem(at: 0).view!)
            .compactMap { $0 as? NSButton }.filter { $0.action == NSSelectorFromString("openWordEditor:") }.count, 5)
        XCTAssertTrue(descendants(of: words.tabViewItem(at: 1).view!).contains { $0 is PersonalDictionaryView })
        XCTAssertGreaterThanOrEqual(descendants(of: words.tabViewItem(at: 2).view!)
            .filter { $0 is NSTableView }.count, 3)
        XCTAssertTrue(descendants(of: words.tabViewItem(at: 3).view!).contains { $0 is AdaptiveRulesView })
        let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
        let controls = settings.tabViewItems.flatMap { descendants(of: $0.view!) }.compactMap { $0 as? NSControl }
        XCTAssertFalse(controls.contains { $0.action == NSSelectorFromString("triggerChanged:")
            || $0.action == NSSelectorFromString("combinedShiftChanged:")
            || $0.action == NSSelectorFromString("caseHotkeyChanged:") })
        let fitted = controller.fittedSettingsWindowSize(
            visibleFrame: NSRect(x: 0, y: 0, width: 760, height: 500))
        XCTAssertLessThanOrEqual(fitted.width, 620)
        XCTAssertLessThanOrEqual(fitted.height, 460)
    }

    @MainActor
    func testFailedMigrationShowsLegacyControlsInsteadOfFalseShiftInstructions() throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let tabs = SettingsWindowController().makeNativeTabs(nativeShiftApplied: false)
        let instructions = descendants(of: tabs.tabViewItem(at: 0).view!)
            .compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(instructions.contains(L10n.nativeMigrationPending))
        XCTAssertFalse(instructions.contains("ghbdtn → привет"))
        let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
        XCTAssertTrue(descendants(of: settings.tabViewItem(at: 0).view!)
            .compactMap { $0 as? NSControl }
            .contains { $0.action == NSSelectorFromString("combinedShiftChanged:") })
    }

    @MainActor
    func testWordsRowsOpenReusedEditorsAndReturnToOverview() throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let tabs = SettingsWindowController().makeNativeTabs(nativeShiftApplied: true)
        let words = try XCTUnwrap(tabs.tabViewItem(at: 1).view as? NSTabView)
        let overview = words.tabViewItem(at: 0).view!
        let buttons = descendants(of: overview).compactMap { $0 as? NSButton }
            .filter { $0.action == NSSelectorFromString("openWordEditor:") }
        for (tag, target) in [1, 2, 2, 2, 3].enumerated() {
            let button = try XCTUnwrap(buttons.first { $0.tag == tag })
            button.performClick(nil)
            XCTAssertTrue(words.selectedTabViewItem === words.tabViewItem(at: target))
            let back = try XCTUnwrap(descendants(of: words.tabViewItem(at: target).view!)
                .compactMap { $0 as? NSButton }
                .first { $0.action == NSSelectorFromString("backToWordsOverview") })
            back.performClick(nil)
            XCTAssertTrue(words.selectedTabViewItem === words.tabViewItem(at: 0))
        }
    }

    @MainActor
    func testSupportPaneKeepsRareControlsReachableWithoutInvokingSystemActions() throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let tabs = SettingsWindowController().makeNativeTabs(nativeShiftApplied: true)
        let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
        let daily = settings.tabViewItem(at: 0).view!
        XCTAssertFalse(descendants(of: daily).contains { $0 is NSSlider })
        let help = try XCTUnwrap(descendants(of: daily).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("openSupportSettings") })
        help.performClick(nil)
        XCTAssertTrue(settings.selectedTabViewItem === settings.tabViewItem(at: 1))
        let controls = descendants(of: settings.tabViewItem(at: 1).view!)
        XCTAssertTrue(controls.contains { $0 is NSSlider })
        let actions = Set(controls.compactMap { ($0 as? NSControl)?.action.map(NSStringFromSelector) })
        for action in ["shellBridgeSetupRequested", "runtimeCheckRequested",
            "permissionCheckRequested", "updateCheckRequested", "recoveryArchiveChanged:",
            "inputSourceRequested", "recoveryOriginalsRequested",
            "recoveryArchiveFolderRequested", "perAppLayoutChanged:", "openAboutSettings"] {
            XCTAssertTrue(actions.contains(action), "missing \(action)")
        }
    }

    @MainActor
    func testInstructionsAutoCheckboxShowsEffectiveOffWhenLegacyMasterWasOff() throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let master = "com.ruswitcher.autoSwitch"
        let auto = "com.ruswitcher.autoConvert"
        let previousMaster = UserDefaults.standard.object(forKey: master)
        let previousAuto = UserDefaults.standard.object(forKey: auto)
        defer {
            if let previousMaster { UserDefaults.standard.set(previousMaster, forKey: master) }
            else { UserDefaults.standard.removeObject(forKey: master) }
            if let previousAuto { UserDefaults.standard.set(previousAuto, forKey: auto) }
            else { UserDefaults.standard.removeObject(forKey: auto) }
        }
        UserDefaults.standard.set(false, forKey: master)
        UserDefaults.standard.set(true, forKey: auto)
        let tabs = SettingsWindowController().makeNativeTabs(nativeShiftApplied: true)
        let checkbox = try XCTUnwrap(descendants(of: tabs.tabViewItem(at: 0).view!)
            .compactMap { $0 as? NSSwitch }.first)
        XCTAssertEqual(checkbox.state, .off)
    }

    @MainActor
    func testWholeLineGuideMatchesSavedModeAndRefreshesAfterRareToggle() throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let key = "com.ruswitcher.convertWholeLine"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        let controller = SettingsWindowController()
        let tabs = controller.makeNativeTabs(nativeShiftApplied: true, wholeLine: false)
        _ = controller.makeSettingsContent(tabView: tabs)
        func guideText() -> [String] {
            descendants(of: tabs.tabViewItem(at: 0).view!)
                .compactMap { ($0 as? NSTextField)?.stringValue }
        }
        XCTAssertTrue(guideText().contains(L10n.nativeDoubleShift))
        let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
        let wholeLine = try XCTUnwrap(descendants(of: settings.tabViewItem(at: 1).view!)
            .compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("convertWholeLineChanged:") })
        wholeLine.performClick(nil)
        XCTAssertTrue(SettingsManager.shared.convertWholeLine)
        XCTAssertTrue(guideText().contains(L10n.nativeDoubleShiftWholeLine))
    }

    @MainActor
    func testWordHubUsesAutocorrectionLanguage() throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let languageKey = "com.ruswitcher.interfaceLanguage"
        let previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("ru", forKey: languageKey)
        L10n.reloadLanguage()
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
            L10n.reloadLanguage()
        }
        let tabs = SettingsWindowController().makeNativeTabs(nativeShiftApplied: true)
        let words = try XCTUnwrap(tabs.tabViewItem(at: 1).view as? NSTabView)
        let titles = descendants(of: words.tabViewItem(at: 0).view!)
            .compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(titles.contains(L10n.nativeWordsNever))
        XCTAssertTrue(titles.contains(L10n.nativeWordsAlways))
        XCTAssertTrue(titles.contains(L10n.nativeWordsApps))
        XCTAssertTrue(titles.contains(L10n.nativeLearningEntry))
        XCTAssertEqual(L10n.nativeWordsNever, "Не исправлять автоматически")
        XCTAssertEqual(L10n.nativeWordsAlways, "Всегда исправлять автоматически")
        XCTAssertEqual(L10n.nativeWordsApps, "Приложения-исключения")
        XCTAssertEqual(L10n.nativeLearningEntry, "Запомненные исправления")
    }

    @MainActor
    func testBackupWarningAppearsOnlyInSupportWhenCommittedCopyIsUnavailable() throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        func supportLabels(backupVerified: Bool) throws -> [String] {
            let tabs = SettingsWindowController().makeNativeTabs(
                nativeShiftApplied: true, backupVerified: backupVerified)
            let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
            return descendants(of: settings.tabViewItem(at: 1).view!)
                .compactMap { ($0 as? NSTextField)?.stringValue }
        }
        XCTAssertTrue(try supportLabels(backupVerified: false).contains(L10n.nativeBackupUnavailable))
        XCTAssertFalse(try supportLabels(backupVerified: true).contains(L10n.nativeBackupUnavailable))
    }

    @MainActor
    func testInstructionsFitAcrossSupportedInterfaceLanguages() throws {
        let priorPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(priorPolicy) }
        let key = "com.ruswitcher.interfaceLanguage"
        let priorLanguage = UserDefaults.standard.object(forKey: key)
        defer {
            if let priorLanguage { UserDefaults.standard.set(priorLanguage, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            L10n.reloadLanguage()
        }
        for language in L10n.supportedLanguages.sorted() {
            UserDefaults.standard.set(language, forKey: key)
            L10n.reloadLanguage()
            for wholeLine in [false, true] {
                let controller = SettingsWindowController()
                let tabs = controller.makeNativeTabs(nativeShiftApplied: true, wholeLine: wholeLine)
                let root = controller.makeSettingsContent(tabView: tabs)
                root.layoutSubtreeIfNeeded()
                for button in descendants(of: root).compactMap({ $0 as? NSButton })
                    where button.action == NSSelectorFromString("topButtonChanged:") {
                    let required = button.cell?.cellSize.width ?? 0
                    XCTAssertLessThanOrEqual(required, button.frame.width + 2,
                        "language=\(language), tab=\(button.title)")
                }
                let labels = descendants(of: tabs.tabViewItem(at: 0).view!)
                    .compactMap { $0 as? NSTextField }
                for label in labels where label.font?.pointSize == 12 {
                    let required = label.cell?.cellSize(forBounds: NSRect(
                        x: 0, y: 0, width: label.frame.width, height: 10_000)).height ?? 0
                    XCTAssertLessThanOrEqual(required, label.frame.height + 1,
                        "language=\(language), wholeLine=\(wholeLine), text=\(label.stringValue)")
                }
            }
        }
    }

    @MainActor
    func testDailySettingButtonsFitAcrossSupportedLanguages() throws {
        let priorPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(priorPolicy) }
        let key = "com.ruswitcher.interfaceLanguage"
        let priorLanguage = UserDefaults.standard.object(forKey: key)
        defer {
            if let priorLanguage { UserDefaults.standard.set(priorLanguage, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            L10n.reloadLanguage()
        }
        for language in L10n.supportedLanguages.sorted() {
            UserDefaults.standard.set(language, forKey: key)
            L10n.reloadLanguage()
            let tabs = SettingsWindowController().makeNativeTabs(nativeShiftApplied: true)
            let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
            let daily = settings.tabViewItem(at: 0).view!
            let support = settings.tabViewItem(at: 1).view!
            for pane in [daily, support] {
                for button in descendants(of: pane).compactMap({ $0 as? NSButton })
                    where !button.title.isEmpty && !(button is NSPopUpButton) {
                    let required = button.cell?.cellSize(forBounds: NSRect(x: 0, y: 0,
                        width: button.frame.width, height: 10_000)).height ?? 0
                    XCTAssertLessThanOrEqual(required, button.frame.height + 2,
                        "language=\(language), control=\(button.title)")
                }
            }
        }
    }

    @MainActor
    func testRenderProductionOffscreenComponentsWhenRequested() throws {
        guard let folder = ProcessInfo.processInfo.environment["MACSWITCHER_PREVIEW_DIR"] else {
            throw XCTSkip("Offscreen component export is opt-in")
        }
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func render(appearanceName: String, appearance: NSAppearance.Name,
                    index: Int, wholeLine: Bool = false, support: Bool = false,
                    suffix: String) throws {
            let controller = SettingsWindowController()
            let tabs = controller.makeNativeTabs(nativeShiftApplied: true, wholeLine: wholeLine,
                backupVerified: true)
            let root = controller.makeSettingsContent(tabView: tabs)
            tabs.selectTabViewItem(at: index)
            if support, let settings = tabs.tabViewItem(at: 2).view as? NSTabView {
                settings.selectTabViewItem(at: 1)
            }
            root.frame = NSRect(x: 0, y: 0, width: 600, height: 520)
            root.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            root.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(appearanceName)-\(suffix).png"))
        }
        for (appearanceName, appearance) in [
            ("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)
        ] {
            for index in 0..<3 {
                try render(appearanceName: appearanceName, appearance: appearance,
                    index: index, suffix: String(index))
            }
            try render(appearanceName: appearanceName, appearance: appearance,
                index: 0, wholeLine: true, suffix: "whole-line")
            try render(appearanceName: appearanceName, appearance: appearance,
                index: 2, support: true, suffix: "support")
        }
    }
    @MainActor
    func testNavigationUsesSuppliedPanesAndFitsVisibleFrame() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 600))
        let first = NSTabViewItem(identifier: "first")
        first.label = "Основные"
        first.view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        let second = NSTabViewItem(identifier: "second")
        second.label = "Второй раздел"
        second.view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        tabs.addTabViewItem(first)
        tabs.addTabViewItem(second)

        let controller = SettingsWindowController()
        let content = controller.makeSettingsContent(tabView: tabs)
        XCTAssertTrue(descendants(of: content).contains { $0 === tabs })
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }
            .filter { $0.action == NSSelectorFromString("topButtonChanged:") }
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(buttons.filter { $0.state == .on }.count, 1)
        XCTAssertTrue(tabs.selectedTabViewItem === first)
        tabs.selectTabViewItem(second)
        XCTAssertTrue(tabs.selectedTabViewItem === second)

        let fitted = controller.fittedSettingsWindowSize(
            visibleFrame: NSRect(x: 0, y: 0, width: 760, height: 500)
        )
        XCTAssertLessThanOrEqual(fitted.width, 600)
        XCTAssertLessThanOrEqual(fitted.height, 460)
    }

    @MainActor
    func testGeneralPaneRefreshUsesInjectedReplacementAndPreservesSelection() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 600))
        let general = NSTabViewItem(identifier: "settings.general")
        general.label = "General"
        general.view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        let about = NSTabViewItem(identifier: "about")
        about.label = "About"
        about.view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(about)
        tabs.selectTabViewItem(general)

        let controller = SettingsWindowController()
        _ = controller.makeSettingsContent(tabView: tabs)
        let replacement = NSTabViewItem(identifier: "settings.general")
        replacement.label = "General"
        let refreshedContent = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
        refreshedContent.identifier = NSUserInterfaceItemIdentifier("injected-general-content")
        replacement.view = refreshedContent

        controller.refreshGeneralTabPresentation { replacement }

        XCTAssertEqual(tabs.numberOfTabViewItems, 2)
        XCTAssertTrue(tabs.selectedTabViewItem === replacement)
        XCTAssertTrue(tabs.tabViewItem(at: 0) === replacement)
        XCTAssertEqual(tabs.tabViewItem(at: 0).view?.identifier?.rawValue, "injected-general-content")
    }

    @MainActor
    func testShortPaneContentStaysAtTopForDifferentViewportHeights() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let controller = SettingsWindowController()
        for viewportHeight: CGFloat in [600, 680] {
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
            let control = NSButton(frame: NSRect(x: 20, y: 150, width: 200, height: 22))
            pane.addSubview(control)

            let scrollView = try XCTUnwrap(controller.topAligned(pane) as? NSScrollView)
            scrollView.frame = NSRect(x: 0, y: 0, width: 460, height: viewportHeight)
            scrollView.layoutSubtreeIfNeeded()

            XCTAssertNotNil(scrollView.documentView)
            let clipView = scrollView.contentView
            let visible = clipView.bounds
            let controlRect = control.convert(control.bounds, to: clipView)
            let topGap = clipView.isFlipped
                ? controlRect.minY - visible.minY
                : visible.maxY - controlRect.maxY
            XCTAssertLessThanOrEqual(topGap, 30, "viewport=\(viewportHeight), gap=\(topGap)")
        }
    }

    @MainActor
    func testShortPaneDoesNotScrollIntoEmptyDocumentAfterViewportShrinks() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        let firstControl = NSButton(frame: NSRect(x: 20, y: 150, width: 200, height: 22))
        pane.addSubview(firstControl)
        let scrollView = try XCTUnwrap(SettingsWindowController().topAligned(pane) as? NSScrollView)
        scrollView.frame.size.height = 320
        scrollView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let proposedBounds = NSRect(origin: NSPoint(x: 0, y: 10_000), size: clipView.bounds.size)
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        clipView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clipView)

        XCTAssertEqual(clipView.bounds.minY, 0, accuracy: 0.5)
        let controlRect = firstControl.convert(firstControl.bounds, to: clipView)
        let topGap = clipView.isFlipped
            ? controlRect.minY - clipView.bounds.minY
            : clipView.bounds.maxY - controlRect.maxY
        XCTAssertLessThanOrEqual(topGap, 30)
    }

    @MainActor
    func testLastControlInLongPaneRemainsReachableAfterViewportShrinks() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 900))
        let lastControl = NSButton(frame: NSRect(x: 20, y: 10, width: 200, height: 22))
        pane.addSubview(lastControl)
        let scrollView = try XCTUnwrap(SettingsWindowController().topAligned(pane) as? NSScrollView)
        scrollView.frame.size.height = 320
        scrollView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let proposedBounds = NSRect(origin: NSPoint(x: 0, y: 10_000), size: clipView.bounds.size)
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        clipView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clipView)

        let lastControlRect = lastControl.convert(lastControl.bounds, to: clipView)
        XCTAssertTrue(lastControlRect.intersects(clipView.bounds))
        XCTAssertLessThanOrEqual(clipView.bounds.maxY, 900.5)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
