import AppKit
import Carbon

/// Native AppKit settings with three top tabs and scrollable long forms.
@MainActor
final class SettingsWindowController: NSObject, NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    private var window: NSWindow?
    private var settingsTabView: NSTabView?
    private var topButtons: [NSButton] = []
    private var wordsSections: NSTabView?
    private var settingsSections: NSTabView?
    private var displayedNativeShiftApplied = false
    private var navigationTable: NSTableView?
    private var autoSwitchCheckbox: NSButton?
    private var launchAtLoginCheckbox: NSButton?
    private var checkUpdatesCheckbox: NSButton?
    private var caretFlagCheckbox: NSButton?
    private var autoConvertCheckboxes: [NSButton] = []
    private var autoConvertSwitches: [NSSwitch] = []
    private var remoteDesktopCheckbox: NSButton?    // #5: то же (опционален — за фичефлагом)
    private var layout1Popup: NSPopUpButton?
    private var layout2Popup: NSPopUpButton?
    private var languagePopup: NSPopUpButton?
    private var switchHotkeyPopup: NSPopUpButton?   // issue #20/#3: пере-populate при смене триггера
    private var caseHotkeyPopup: NSPopUpButton?     // issue #29
    private var exceptionEditors: [ExceptionListEditor] = []
    private var exceptionHeaders: [NSView] = []
    private var intervalValueLabel: NSTextField?

    /// Callback для обновления меню
    var onAutoSwitchChanged: ((Bool) -> Void)?
    var onPerAppLayoutChanged: ((Bool) -> Void)?
    var onLanguageChanged: (() -> Void)?
    var onTriggerChanged: (() -> Void)?
    var onCombinedShiftChanged: (() -> Void)?
    var onShellBridgeSetupRequested: (() -> Void)?
    var onRuntimeCheckRequested: (() -> Void)?
    var onAutoConvertChanged: ((Bool) -> Void)?
    var onRemoteDesktopChanged: ((Bool) -> Void)?
    var onCaretFlagChanged: ((Bool) -> Void)?
    var onHideIconChanged: ((Bool) -> Void)?
    var onPredictionPreferencesChanged: (() -> Void)?
    var onRecoveryArchiveChanged: ((Bool) -> Void)?
    var onStatusAppearanceChanged: (() -> Void)?
    var onPermissionCheckRequested: (() -> Void)?
    var onUpdateCheckRequested: (() -> Void)?
    var onInputSourceRequested: (() -> Void)?
    var onRecoveryOriginalsRequested: (() -> Void)?
    var onRecoveryArchiveFolderRequested: (() -> Void)?
    var onCompactMenuChanged: (() -> Void)?

    func showWindow() {
        if let window {
            settingsTabView?.selectTabViewItem(at: 0)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.settingsTitle
        win.center()
        win.isReleasedWhenClosed = false

        let tabView = makeNativeTabs()

        let root = makeSettingsContent(tabView: tabView)
        win.contentView = root
        // Long forms scroll inside their pane and remain usable on short displays.
        let screen = NSScreen.main
        win.setContentSize(fittedSettingsWindowSize(visibleFrame: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 760, height: 740)))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }

    func showWords() {
        showWindow()
        settingsTabView?.selectTabViewItem(at: 1)
        wordsSections?.selectTabViewItem(at: 0)
    }

    func showSettings() {
        showWindow()
        settingsTabView?.selectTabViewItem(at: 2)
    }

    /// «Words & exceptions → Remembered corrections», the path named by the learning notice.
    func showLearning() {
        showWindow()
        settingsTabView?.selectTabViewItem(at: 1)
        wordsSections?.selectTabViewItem(at: 3)
    }

    func makeNativeTabs(
        nativeShiftApplied: Bool = SettingsManager.shared.nativeShiftMigrationApplied,
        wholeLine: Bool = SettingsManager.shared.convertWholeLine,
        backupVerified: Bool = SettingsManager.shared.nativeShiftBackupVerified
    ) -> NSTabView {
        displayedNativeShiftApplied = nativeShiftApplied
        autoConvertCheckboxes.removeAll()
        autoConvertSwitches.removeAll()
        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 600, height: 520))
        tabs.autoresizingMask = [.width, .height]
        tabs.tabViewType = .noTabsNoBorder
        tabs.delegate = self
        tabs.addTabViewItem(createInstructionsTab(
            nativeShiftApplied: nativeShiftApplied, wholeLine: wholeLine))
        tabs.addTabViewItem(createWordsTab())
        tabs.addTabViewItem(createNativeSettingsTab(
            nativeShiftApplied: nativeShiftApplied, backupVerified: backupVerified))
        tabs.selectTabViewItem(at: 0)
        return tabs
    }

    private func createInstructionsTab(nativeShiftApplied: Bool, wholeLine: Bool) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "native.instructions")
        item.label = L10n.nativeInstructionsTab
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 450))
        if !nativeShiftApplied {
            let warning = NSTextField(wrappingLabelWithString: L10n.nativeMigrationPending)
            warning.font = .systemFont(ofSize: 16)
            warning.textColor = .systemOrange
            warning.frame = NSRect(x: 24, y: 326, width: 550, height: 80)
            view.addSubview(warning)
            let settings = NSButton(title: L10n.nativeSettingsTab,
                target: self, action: #selector(openLegacySettingsTab))
            settings.frame = NSRect(x: 24, y: 275, width: 200, height: 32)
            view.addSubview(settings)
            item.view = topAligned(view)
            return item
        }

        let column = Self.columnWidth, pad = Self.groupPadding
        let heading = NSTextField(labelWithString: "MacSwitcher")
        heading.font = .boldSystemFont(ofSize: 21)
        heading.frame = NSRect(x: 24, y: 406, width: 550, height: 28)
        view.addSubview(heading)

        func gestureRow(y: CGFloat, title: String, subtitle: String, keycap: String) {
            let group = nativeGroup(NSRect(x: Self.columnX, y: y, width: column, height: 74))
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .boldSystemFont(ofSize: 14)
            titleLabel.frame = NSRect(x: pad, y: 43, width: 410, height: 20)
            group.contentView?.addSubview(titleLabel)
            let detail = NSTextField(wrappingLabelWithString: subtitle)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.frame = NSRect(x: pad, y: 7, width: 420, height: 36)
            group.contentView?.addSubview(detail)
            group.contentView?.addSubview(flatKeycap(keycap,
                frame: NSRect(x: column - pad - 92, y: 23, width: 92, height: 28)))
            view.addSubview(group)
        }
        gestureRow(y: 316, title: "Shift", subtitle: L10n.nativeSingleShift, keycap: "⇧ Shift")
        gestureRow(y: 231, title: "Shift × 2", subtitle: wholeLine
            ? L10n.nativeDoubleShiftWholeLine : L10n.nativeDoubleShift, keycap: "⇧ ×2")

        let undo = NSTextField(wrappingLabelWithString: L10n.nativeUndo)
        undo.font = .systemFont(ofSize: 12)
        undo.textColor = .secondaryLabelColor
        undo.frame = NSRect(x: Self.columnX + pad, y: 191, width: column - 2 * pad, height: 31)
        view.addSubview(undo)

        let example = nativeGroup(NSRect(x: Self.columnX, y: 128, width: column, height: 54))
        let exampleText = NSTextField(labelWithString: "ghbdtn → привет")
        exampleText.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        exampleText.frame = NSRect(x: pad, y: 14, width: column - 2 * pad, height: 26)
        example.contentView?.addSubview(exampleText)
        view.addSubview(example)

        let automatic = nativeGroup(NSRect(x: Self.columnX, y: 38, width: column, height: 78))
        let autoTitle = NSTextField(labelWithString: L10n.nativeAutoTitle)
        autoTitle.font = .boldSystemFont(ofSize: 14)
        autoTitle.frame = NSRect(x: pad, y: 45, width: 450, height: 20)
        automatic.contentView?.addSubview(autoTitle)
        let autoCaption = NSTextField(wrappingLabelWithString: L10n.nativeAutoHint)
        autoCaption.font = .systemFont(ofSize: 12)
        autoCaption.textColor = .secondaryLabelColor
        autoCaption.frame = NSRect(x: pad, y: 10, width: 450, height: 35)
        automatic.contentView?.addSubview(autoCaption)
        automatic.contentView?.addSubview(makeAutoConvertSwitch(
            origin: NSPoint(x: column - pad - 48, y: 25)))
        view.addSubview(automatic)
        item.view = topAligned(view)
        return item
    }

    private func makeAutoConvertSwitch(origin: NSPoint) -> NSSwitch {
        let toggle = NSSwitch(frame: NSRect(origin: origin, size: NSSize(width: 48, height: 28)))
        toggle.state = SettingsManager.shared.automaticTextEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(autoConvertSwitchChanged(_:))
        autoConvertSwitches.append(toggle)
        return toggle
    }

    private func nativeGroup(_ frame: NSRect, fill: NSColor = .controlBackgroundColor) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderColor = .separatorColor
        box.fillColor = fill
        box.cornerRadius = 9
        box.contentViewMargins = .zero
        return box
    }

    @objc private func openLegacySettingsTab() {
        settingsTabView?.selectTabViewItem(at: 2)
    }

    private func refreshInstructionsTab() {
        guard let tabs = settingsTabView, tabs.numberOfTabViewItems >= 1 else { return }
        let old = tabs.tabViewItem(at: 0)
        let selected = tabs.selectedTabViewItem
        let replacement = createInstructionsTab(nativeShiftApplied: displayedNativeShiftApplied,
            wholeLine: SettingsManager.shared.convertWholeLine)
        tabs.removeTabViewItem(old)
        tabs.insertTabViewItem(replacement, at: 0)
        if selected === old { tabs.selectTabViewItem(replacement) }
        else if let selected { tabs.selectTabViewItem(selected) }
    }

    private func createWordsTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "native.words")
        item.label = L10n.nativeWordsTab
        let sections = NSTabView(frame: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 450))
        sections.autoresizingMask = [.width, .height]
        sections.tabViewType = .noTabsNoBorder
        let overview = NSTabViewItem(identifier: "words.overview")
        overview.view = createWordsOverview()
        sections.addTabViewItem(overview)
        sections.addTabViewItem(wrapWordEditor(createPersonalDictionaryTab()))
        sections.addTabViewItem(wrapWordEditor(createExceptionsTab()))
        sections.addTabViewItem(wrapWordEditor(createAdaptiveRulesTab()))
        sections.selectTabViewItem(at: 0)
        wordsSections = sections
        item.view = sections
        return item
    }

    private func createWordsOverview() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 450))
        let heading = NSTextField(labelWithString: L10n.nativeWordsTab)
        heading.font = .boldSystemFont(ofSize: 20)
        heading.frame = NSRect(x: 24, y: 402, width: 550, height: 28)
        view.addSubview(heading)
        let rows = [(L10n.nativeDictionaryEntry, L10n.wordsDictionaryDetail),
            (L10n.nativeWordsNever, L10n.wordsNeverDetail),
            (L10n.nativeWordsAlways, L10n.wordsAlwaysDetail),
            (L10n.nativeWordsApps, L10n.wordsAppsDetail),
            (L10n.nativeLearningEntry, L10n.wordsLearningDetail)]
        let column = Self.columnWidth, pad = Self.groupPadding
        var top: CGFloat = 388
        for (index, row) in rows.enumerated() {
            // The explanation wraps instead of being cut: long translations get a taller row.
            let detailWidth = column - 2 * pad - 32
            let detail = Self.measuredLabel(row.1, size: 11, width: detailWidth, secondary: true)
            let height = max(58, 9 + detail.frame.height + 4 + 22 + 8)
            let group = nativeGroup(NSRect(x: Self.columnX, y: top - height, width: column, height: height))
            top -= height + 8
            let button = NSButton(title: row.0, target: self, action: #selector(openWordEditor(_:)))
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.attributedTitle = NSAttributedString(string: row.0, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ])
            button.frame = NSRect(x: pad, y: height - 30, width: column - 2 * pad - 30, height: 22)
            button.tag = index
            group.contentView?.addSubview(button)
            detail.identifier = NSUserInterfaceItemIdentifier("words.row.detail")
            detail.toolTip = row.1
            detail.frame.origin = NSPoint(x: pad - 1, y: 9)
            group.contentView?.addSubview(detail)
            let chevron = NSTextField(labelWithString: "›")
            chevron.font = .systemFont(ofSize: 22)
            chevron.textColor = .tertiaryLabelColor
            chevron.frame = NSRect(x: column - pad - 20, y: height / 2 - 15, width: 20, height: 30)
            group.contentView?.addSubview(chevron)
            view.addSubview(group)
        }
        return view
    }

    private func wrapWordEditor(_ editor: NSTabViewItem) -> NSTabViewItem {
        let wrapped = NSTabViewItem(identifier: editor.identifier)
        wrapped.label = editor.label
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 450))
        let back = NSButton(title: "‹  \(L10n.nativeWordsTab)", target: self,
            action: #selector(backToWordsOverview))
        back.isBordered = false
        back.alignment = .left
        back.frame = NSRect(x: Self.columnX, y: 409, width: 480, height: 30)
        view.addSubview(back)
        if let content = editor.view {
            content.frame = NSRect(x: Self.columnX, y: 0, width: Self.columnWidth, height: 398)
            content.autoresizingMask = [.width, .height]
            view.addSubview(content)
        }
        wrapped.view = view
        return wrapped
    }

    @objc private func openWordEditor(_ sender: NSButton) {
        let targets = [1, 2, 2, 2, 3]
        guard (0..<targets.count).contains(sender.tag) else { return }
        wordsSections?.selectTabViewItem(at: targets[sender.tag])
        let headerIndex: Int? = [nil, 1, 2, 0, nil][sender.tag]
        if let headerIndex, exceptionHeaders.indices.contains(headerIndex) {
            let header = exceptionHeaders[headerIndex]
            DispatchQueue.main.async { header.scrollToVisible(header.bounds) }
        }
    }

    @objc private func backToWordsOverview() {
        wordsSections?.selectTabViewItem(at: 0)
    }

    private func createNativeSettingsTab(nativeShiftApplied: Bool, backupVerified: Bool) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "native.settings")
        item.label = L10n.nativeSettingsTab
        let sections = NSTabView(frame: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 450))
        sections.autoresizingMask = [.width, .height]
        if nativeShiftApplied { sections.tabViewType = .noTabsNoBorder }
        sections.addTabViewItem(nativeShiftApplied
            ? createDailySettingsPane() : createGeneralTab())
        sections.addTabViewItem(nativeShiftApplied
            ? wrapSupportSettings(createAdvancedTab(showBackupWarning: !backupVerified,
                showNativePerApp: true))
            : createAdvancedTab(showBackupWarning: false, showNativePerApp: false))
        sections.addTabViewItem(nativeShiftApplied
            ? wrapSupportSettings(createAboutTab()) : createAboutTab())
        sections.selectTabViewItem(at: 0)
        settingsSections = sections
        item.view = sections
        return item
    }

    private func createDailySettingsPane() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "settings.general")
        item.label = L10n.settingsTabGeneral
        let settings = SettingsManager.shared
        var column = SettingsColumn()
        let labelWidth: CGFloat = 180

        // Shift gestures and the automatic-correction switch — the two things used daily.
        let gestures = SettingsFormGroup()
        let textWidth = gestures.innerWidth - 92 - 12
        for (keycap, text) in [("⇧ Shift", L10n.nativeSingleShift), ("⇧ ×2", settings.convertWholeLine
            ? L10n.nativeDoubleShiftWholeLine : L10n.nativeDoubleShift)] {
            let label = Self.measuredLabel(text, size: 12, width: textWidth, secondary: true)
            gestures.add([(flatKeycap(keycap, frame: NSRect(x: 0, y: 0, width: 92, height: 24)), 0),
                (label, 104)], gap: 6)
        }
        let autoTitle = Self.measuredLabel(L10n.nativeAutoTitle, size: 13,
            width: gestures.innerWidth - 60, bold: true)
        gestures.add([(autoTitle, 0),
            (makeAutoConvertSwitch(origin: .zero), gestures.innerWidth - 48)])
        column.add(gestures.makeBox(identifier: "settings.gestures"), gap: 8)

        // Keyboard layouts and interface language.
        let languages = SettingsFormGroup()
        languages.addTitle(L10n.nativeLanguagesGroup)
        func popupRow(_ group: SettingsFormGroup, _ title: String, action: Selector,
                      populate: (NSPopUpButton) -> Void) -> NSPopUpButton {
            let label = Self.measuredLabel(title, size: 12, width: labelWidth)
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0,
                width: group.innerWidth - labelWidth - 8, height: 28))
            populate(popup)
            popup.target = self
            popup.action = action
            group.add([(label, 0), (popup, labelWidth + 8)], gap: 4)
            return popup
        }
        languagePopup = popupRow(languages, L10n.settingsLanguage,
            action: #selector(languageChanged), populate: populateLanguagePopup)
        layout1Popup = popupRow(languages, L10n.settingsLayout1,
            action: #selector(layout1Changed)) { popup in
            populateLayoutPopup(popup, selectedID: settings.layout1ID)
        }
        layout2Popup = popupRow(languages, L10n.settingsLayout2,
            action: #selector(layout2Changed)) { popup in
            populateLayoutPopup(popup, selectedID: settings.layout2ID)
        }
        column.add(languages.makeBox(identifier: "settings.languages"), gap: 8)

        // Startup, updates and the menu bar icon.
        let startup = SettingsFormGroup()
        startup.addTitle(L10n.settingsStartupIconGroup)
        let login = Self.wrappingCheckbox(L10n.settingsLaunchAtLogin, target: self,
            action: #selector(launchAtLoginChanged), on: settings.launchAtLogin, width: startup.innerWidth)
        startup.add(login, gap: 4)
        launchAtLoginCheckbox = login
        let updates = Self.wrappingCheckbox(L10n.settingsCheckUpdates, target: self,
            action: #selector(checkUpdatesEnabledChanged), on: settings.checkUpdatesEnabled,
            width: startup.innerWidth)
        startup.add(updates, gap: 8)
        checkUpdatesCheckbox = updates
        _ = popupRow(startup, L10n.settingsIcon, action: #selector(statusIconStyleChanged(_:))) { popup in
            popup.addItems(withTitles: [L10n.settingsIconBadge, L10n.settingsIconFlag])
            popup.selectItem(at: settings.monochromeIcon ? 0 : 1)
        }
        column.add(startup.makeBox(identifier: "settings.startup"), gap: 8)

        let more = NSButton(title: L10n.settingsMoreEntry,
            target: self, action: #selector(openSupportSettings))
        more.frame.size = NSSize(width: Self.columnWidth, height: 30)
        column.add(more)
        item.view = topAligned(column.makeView(width: Self.paneWidth, top: 10, bottom: 10))
        return item
    }

    @objc private func statusIconStyleChanged(_ sender: NSPopUpButton) {
        SettingsManager.shared.monochromeIcon = sender.indexOfSelectedItem == 0
        onStatusAppearanceChanged?()
    }

    @objc private func compactMenuChanged(_ sender: NSButton) {
        SettingsManager.shared.compactMenu = sender.state == .on
        onCompactMenuChanged?()
    }

    @objc private func openSupportSettings() {
        settingsSections?.selectTabViewItem(at: 1)
    }

    @objc private func backToDailySettings() {
        settingsSections?.selectTabViewItem(at: 0)
    }

    @objc private func openAboutSettings() {
        settingsSections?.selectTabViewItem(at: 2)
    }

    private func wrapSupportSettings(_ support: NSTabViewItem) -> NSTabViewItem {
        let wrapped = NSTabViewItem(identifier: support.identifier)
        wrapped.label = support.label
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 450))
        let back = NSButton(title: "‹  " + L10n.nativeSettingsTab,
            target: self, action: #selector(backToDailySettings))
        back.isBordered = false
        back.alignment = .left
        back.frame = NSRect(x: Self.columnX, y: 409, width: 480, height: 30)
        view.addSubview(back)
        if let content = support.view {
            // A scrolling form spans the whole pane and starts its column 20 pt in, so a
            // permanent scroll bar sits in the right margin instead of cutting the column.
            if let scroll = content as? NSScrollView {
                scroll.frame = NSRect(x: 0, y: 0, width: Self.paneWidth, height: 398)
                scroll.automaticallyAdjustsContentInsets = false
                scroll.contentInsets = NSEdgeInsets(top: 0, left: Self.columnX, bottom: 0, right: 0)
            } else {
                content.frame = NSRect(x: Self.columnX, y: 0, width: Self.columnWidth, height: 398)
            }
            content.autoresizingMask = [.width, .height]
            view.addSubview(content)
        }
        wrapped.view = view
        return wrapped
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if tabView === settingsTabView,
           let tabViewItem, let index = tabView.tabViewItems.firstIndex(of: tabViewItem) {
            for (buttonIndex, button) in topButtons.enumerated() {
                button.state = buttonIndex == index ? .on : .off
            }
        }
        if let tabViewItem, let index = tabView.tabViewItems.firstIndex(of: tabViewItem),
           navigationTable?.selectedRow != index {
            navigationTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        resizeSettingsWindow(for: tabView)
    }

    /// Builds the production tab shell without opening or activating a window.
    func makeSettingsContent(tabView: NSTabView) -> NSView {
        settingsTabView = tabView
        let root = SettingsRootView(frame: NSRect(x: 0, y: 0, width: 600, height: 520))
        tabView.frame = NSRect(x: 0, y: 0, width: 600, height: 470)
        tabView.autoresizingMask = [.width, .height]
        root.addSubview(tabView)
        let tabs = NSStackView()
        tabs.orientation = .horizontal
        tabs.distribution = .fillEqually
        tabs.spacing = 8
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            tabs.heightAnchor.constraint(equalToConstant: 32)
        ])
        topButtons = tabView.tabViewItems.enumerated().map { index, item in
            let button = NSButton(title: item.label, target: self, action: #selector(topButtonChanged(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.tag = index
            button.state = index == 0 ? .on : .off
            tabs.addArrangedSubview(button)
            return button
        }
        tabView.selectTabViewItem(at: 0)
        return root
    }

    @objc private func topButtonChanged(_ sender: NSButton) {
        guard let settingsTabView, sender.tag >= 0,
              sender.tag < settingsTabView.numberOfTabViewItems else { return }
        settingsTabView.selectTabViewItem(at: sender.tag)
    }

    private final class SettingsRootView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? 130 : proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? max(130, splitView.bounds.width - 320) : proposedMaximumPosition
    }

    func fittedSettingsWindowSize(visibleFrame: NSRect) -> NSSize {
        NSSize(width: min(600, max(1, visibleFrame.width - 60)),
               height: min(520, max(1, visibleFrame.height - 40)))
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        settingsTabView?.numberOfTabViewItems ?? 6
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("SettingsNavigationCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
            ?? NSTableCellView(frame: .zero)
        cell.identifier = cellID
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = label
        }
        cell.textField?.stringValue = settingsTabView?.tabViewItem(at: row).label ?? ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tabView = settingsTabView, let table = notification.object as? NSTableView,
              table.selectedRow >= 0, table.selectedRow < tabView.numberOfTabViewItems else { return }
        tabView.selectTabViewItem(at: table.selectedRow)
    }

    private func resizeSettingsWindow(for tabView: NSTabView) {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main
        let top = window.frame.maxY
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 760, height: 740)
        window.setContentSize(fittedSettingsWindowSize(visibleFrame: visibleFrame))
        var origin = NSPoint(x: window.frame.minX, y: top - window.frame.height)
        if let screen {
            origin.y = max(screen.visibleFrame.minY,
                min(origin.y, screen.visibleFrame.maxY - window.frame.height))
        }
        window.setFrameOrigin(origin)
    }

    /// Обновить состояние чекбокса автопереключения извне
    func updateAutoSwitchState(_ enabled: Bool) {
        autoSwitchCheckbox?.state = enabled ? .on : .off
    }

    /// Обновить чекбокс «флаг у курсора» извне (когда переключили из меню)
    func updateCaretFlagState(_ enabled: Bool) {
        caretFlagCheckbox?.state = enabled ? .on : .off
    }

    /// #4/#5: синхронизировать чекбоксы с переключением из меню-бара.
    func updateAutoConvertState(_ enabled: Bool) {
        for checkbox in autoConvertCheckboxes { checkbox.state = enabled ? .on : .off }
        for toggle in autoConvertSwitches { toggle.state = enabled ? .on : .off }
    }
    func updateRemoteDesktopState(_ enabled: Bool) {
        remoteDesktopCheckbox?.state = enabled ? .on : .off
    }

    // MARK: - General Tab

    private final class TopAlignedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    /// Длинные формы прокручиваются в пределах вкладки. Компактные разделы остаются
    /// прижатыми к верху, а размер окна не меняется при навигации.
    func topAligned(_ content: NSView) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        // Existing pane forms use fixed 460 pt coordinates; preserve access to their
        // controls if the available display is narrower than the normal window.
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let document = TopAlignedDocumentView(
            frame: NSRect(x: 0, y: 0, width: content.frame.width, height: content.frame.height)
        )
        // Pane contents use unflipped, bottom-origin coordinates. Keep their frames
        // unchanged inside a flipped document so short forms begin at the viewport top.
        content.autoresizingMask = []
        content.frame.origin = .zero
        document.addSubview(content)
        scrollView.documentView = document
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return scrollView
    }

    // MARK: - Подгонка вёрстки под длину текста

    /// Вкладки свёрстаны абсолютными фреймами, и длинные переводы обрезались: на 16 языках
    /// нашлось 113 мест (проверка: site/tools/make_shots.sh --audit). После сборки вкладки
    /// этот проход подгоняет её под фактический текст:
    ///  • строки «подпись + список» — общая колонка подписей по самой длинной; если список
    ///    при этом не влезает, подпись переносится на несколько строк;
    ///  • многострочные пояснения и длинные чекбоксы получают нужную высоту (чекбоксы переносятся);
    ///  • кнопки расширяются под текст, а ряд кнопок, который не влезает, встаёт в столбик;
    ///  • всё, что ниже выросшего элемента, сдвигается вниз, высота вкладки — по содержимому.
    private func fitToText(_ view: NSView, left: CGFloat = 20, right: CGFloat = 440) {
        let gap: CGFloat = 8
        let items = view.subviews.filter { !$0.isHidden }
        guard !items.isEmpty else { return }
        let topMargin = view.frame.height - (items.map { $0.frame.maxY }.max() ?? view.frame.height)

        // Строки — элементы, чьи рамки заметно пересекаются по вертикали (подпись и список рядом).
        func sameRow(_ a: NSRect, _ b: NSRect) -> Bool {
            min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.3 * min(a.height, b.height)
        }
        var rows: [[NSView]] = []
        for v in items.sorted(by: { $0.frame.maxY > $1.frame.maxY }) {
            if let i = rows.firstIndex(where: { $0.contains { sameRow($0.frame, v.frame) } }) {
                rows[i].append(v)
            } else {
                rows.append([v])
            }
        }
        rows.sort { ($0.map { $0.frame.maxY }.max() ?? 0) > ($1.map { $0.frame.maxY }.max() ?? 0) }

        var grow: [ObjectIdentifier: CGFloat] = [:]       // на сколько выросла высота (верх на месте)
        func setHeight(_ v: NSView, _ h: CGFloat) {
            let top = v.frame.maxY
            grow[ObjectIdentifier(v), default: 0] += h - v.frame.height
            v.frame = NSRect(x: v.frame.minX, y: top - h, width: v.frame.width, height: h)
        }
        func fitHeight(_ c: NSControl, width: CGFloat) -> CGFloat {
            ceil(c.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? c.frame.height)
        }
        func makeWrapping(_ c: NSControl) {
            c.cell?.wraps = true
            c.cell?.lineBreakMode = .byWordWrapping
            (c as? NSTextField)?.maximumNumberOfLines = 0
        }

        // 1. «Подпись + список»: одна колонка подписей на всю вкладку.
        var pairs: [(label: NSTextField, popup: NSPopUpButton)] = []
        for row in rows {
            let labels = row.compactMap { $0 as? NSTextField }.filter { !$0.isEditable && $0.cell?.wraps != true }
            let popups = row.compactMap { $0 as? NSPopUpButton }
            if labels.count == 1, popups.count == 1, labels[0].frame.minX < popups[0].frame.minX {
                pairs.append((labels[0], popups[0]))
            }
        }
        if !pairs.isEmpty {
            let popupNeed = min(pairs.map { ceil($0.popup.cell?.cellSize.width ?? 0) }.max() ?? 0, right - left - gap - 90)
            let labelNeed = pairs.map { ceil($0.label.cell?.cellSize.width ?? 0) + 2 }.max() ?? 0
            // Колонка не уже самого длинного слова: иначе слово рвётся по буквам («Դասավորությա / ն»).
            let longestWord = pairs.flatMap { p in
                p.label.stringValue.split(whereSeparator: \.isWhitespace).map { word in
                    ceil(NSAttributedString(string: String(word), attributes: [.font: p.label.font ?? NSFont.systemFont(ofSize: 13)]).size().width) + 4
                }
            }.max() ?? 0
            let column = min(labelNeed, max(90, right - left - gap - popupNeed))
            if column >= longestWord {
                for (label, popup) in pairs {
                    label.frame = NSRect(x: left, y: label.frame.minY, width: column, height: label.frame.height)
                    if ceil(label.cell?.cellSize.width ?? 0) + 2 > column {
                        makeWrapping(label)
                        setHeight(label, fitHeight(label, width: column))
                    }
                    let x = left + column + gap
                    popup.frame = NSRect(x: x, y: popup.frame.minY, width: right - x, height: popup.frame.height)
                }
            } else {
                // Подписи над списками, во всю ширину — одинаково для всей вкладки.
                for (label, popup) in pairs {
                    let top = max(label.frame.maxY, popup.frame.maxY)
                    let rowHeight = top - min(label.frame.minY, popup.frame.minY)
                    makeWrapping(label)
                    let lh = fitHeight(label, width: right - left)
                    label.frame = NSRect(x: left, y: top - lh, width: right - left, height: lh)
                    popup.frame = NSRect(x: left, y: label.frame.minY - 4 - popup.frame.height,
                                         width: right - left, height: popup.frame.height)
                    grow[ObjectIdentifier(popup), default: 0] += (lh + 4 + popup.frame.height) - rowHeight
                }
            }
        }

        // 2. Многострочные пояснения и чекбоксы (кнопки без рамки) — высота по тексту.
        for v in items {
            if let tf = v as? NSTextField, !tf.isEditable, tf.cell?.wraps == true {
                let h = fitHeight(tf, width: tf.frame.width)
                if h > tf.frame.height { setHeight(tf, h) }
            } else if let b = v as? NSButton, !(b is NSPopUpButton), !b.isBordered, !b.title.isEmpty,
                      ceil(b.cell?.cellSize.width ?? 0) > b.frame.width {
                makeWrapping(b)
                setHeight(b, max(b.frame.height, fitHeight(b, width: b.frame.width)))
            }
        }

        // 3. Кнопки с рамкой: ширина по тексту; ряд, который не влезает, — в столбик на всю ширину.
        for row in rows {
            let buttons = row.compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) && $0.isBordered }
                .sorted { $0.frame.minX < $1.frame.minX }
            guard !buttons.isEmpty else { continue }
            let need = buttons.map { ceil($0.cell?.cellSize.width ?? 0) + 2 }     // cellSize уже с полями кнопки
            guard zip(buttons, need).contains(where: { $0.frame.width < $1 }) else { continue }
            let start = buttons[0].frame.minX
            let rowGap: CGFloat = buttons.count > 1 ? buttons[1].frame.minX - buttons[0].frame.maxX : 10
            let gaps = rowGap * CGFloat(buttons.count - 1)
            // прежние ширины, где хватает; если ряд так не влезает — точно по тексту
            var widths = zip(buttons, need).map { max($0.frame.width, $1) }
            if start + widths.reduce(0, +) + gaps > right { widths = need }
            if start + widths.reduce(0, +) + gaps <= right {
                var x = start
                for (b, w) in zip(buttons, widths) {
                    b.frame = NSRect(x: x, y: b.frame.minY, width: w, height: b.frame.height)
                    x += w + rowGap
                }
            } else {
                // столбиком: первая кнопка на месте, остальные ниже; рост ряда — на первой кнопке
                let h = buttons[0].frame.height, step = h + 8
                for (i, b) in buttons.enumerated() {
                    b.frame = NSRect(x: start, y: buttons[0].frame.minY - CGFloat(i) * step, width: right - start, height: h)
                }
                grow[ObjectIdentifier(buttons[0]), default: 0] += step * CGFloat(buttons.count - 1)
            }
        }

        // 4. Сдвиг вниз всего, что ниже выросших элементов.
        var offset: CGFloat = 0
        for row in rows {
            var rowGrow: CGFloat = 0
            for v in row {
                v.frame.origin.y -= offset
                rowGrow = max(rowGrow, grow[ObjectIdentifier(v)] ?? 0)
            }
            offset += rowGrow
        }

        // 5. Высота вкладки — по содержимому: прежний отступ сверху, 16 снизу.
        let low = items.map { $0.frame.minY }.min() ?? 0
        let high = items.map { $0.frame.maxY }.max() ?? 0
        let height = topMargin + (high - low) + 16
        for v in items { v.frame.origin.y += 16 - low }
        view.frame = NSRect(x: view.frame.minX, y: view.frame.minY, width: view.frame.width, height: height)
    }

    private func createGeneralTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "settings.general")
        item.label = L10n.settingsTabGeneral

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 790))
        var y: CGFloat = 750

        // Автопереключение
        let autoSwitch = NSButton(checkboxWithTitle: L10n.settingsAutoSwitch, target: self, action: #selector(autoSwitchChanged))
        autoSwitch.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        autoSwitch.state = SettingsManager.shared.autoSwitchEnabled ? .on : .off
        view.addSubview(autoSwitch)
        autoSwitchCheckbox = autoSwitch
        y -= 30

        let combinedShift = NSButton(checkboxWithTitle: L10n.text("settings.combinedShift"),
                                     target: self, action: #selector(combinedShiftChanged))
        combinedShift.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        combinedShift.state = SettingsManager.shared.combinedShiftEnabled ? .on : .off
        combinedShift.toolTip = L10n.text("settings.combinedShift.tip")
        view.addSubview(combinedShift)
        y -= 30

        let shellBridge = NSButton(checkboxWithTitle: L10n.nativeShellEnabled,
            target: self, action: #selector(shellBridgeChanged))
        shellBridge.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        shellBridge.state = SettingsManager.shared.shellBridgeEnabled ? .on : .off
        shellBridge.toolTip = L10n.text("settings.shellBridge.tip")
        view.addSubview(shellBridge)
        y -= 30

        let shellSetup = NSButton(title: L10n.nativeShellSetup,
            target: self, action: #selector(shellBridgeSetupRequested))
        shellSetup.frame = NSRect(x: 40, y: y, width: 300, height: 26)
        view.addSubview(shellSetup)
        y -= 36

        let runtimeCheck = NSButton(title: L10n.nativeRuntimeCheck,
            target: self, action: #selector(runtimeCheckRequested))
        runtimeCheck.frame = NSRect(x: 40, y: y, width: 300, height: 26)
        view.addSubview(runtimeCheck)
        y -= 36

        if SettingsManager.shared.combinedShiftEnabled {
        let intervalTitle = NSTextField(labelWithString: L10n.nativeShiftInterval)
        intervalTitle.frame = NSRect(x: 20, y: y, width: 175, height: 22)
        view.addSubview(intervalTitle)
        let interval = NSSlider(frame: NSRect(x: 190, y: y - 2, width: 175, height: 25))
        interval.minValue = 80
        interval.maxValue = 400
        interval.integerValue = SettingsManager.shared.doubleShiftIntervalMilliseconds
        interval.target = self
        interval.action = #selector(doubleShiftIntervalChanged)
        view.addSubview(interval)
        let value = NSTextField(labelWithString: L10n.settingsIntervalValue(interval.integerValue))
        value.frame = NSRect(x: 370, y: y, width: 70, height: 22)
        view.addSubview(value)
        intervalValueLabel = value
        y -= 34
        }

        if !SettingsManager.shared.combinedShiftEnabled {
        // Триггер конвертации
        let triggerLabel = NSTextField(labelWithString: L10n.settingsTrigger)
        triggerLabel.frame = NSRect(x: 20, y: y, width: 150, height: 22)
        view.addSubview(triggerLabel)

        let triggerPopup = NSPopUpButton(frame: NSRect(x: 175, y: y - 2, width: 255, height: 26))
        populateTriggerPopup(triggerPopup)
        triggerPopup.target = self
        triggerPopup.action = #selector(triggerChanged)
        view.addSubview(triggerPopup)
        y -= 34

        let rightOnlyCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerRightOnly, target: self, action: #selector(triggerRightOnlyChanged))
        rightOnlyCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        rightOnlyCheckbox.state = SettingsManager.shared.triggerRightOnly ? .on : .off
        view.addSubview(rightOnlyCheckbox)
        y -= 26

        let doubleTapCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerDoubleTap, target: self, action: #selector(triggerDoubleTapChanged))
        doubleTapCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        doubleTapCheckbox.state = SettingsManager.shared.triggerDoubleTap ? .on : .off
        view.addSubview(doubleTapCheckbox)
        y -= 30
        }

        // issue #14: отдельный хоткей чистого переключения раскладки (без конверсии) —
        // в т.ч. Ctrl+Shift и другие модификаторные комбо, недоступные системным настройкам.
        let switchLabel = NSTextField(labelWithString: L10n.settingsSwitchHotkey)
        switchLabel.frame = NSRect(x: 20, y: y, width: 150, height: 22)
        view.addSubview(switchLabel)

        let switchPopup = NSPopUpButton(frame: NSRect(x: 175, y: y - 2, width: 255, height: 26))
        populateSwitchHotkeyPopup(switchPopup)
        switchPopup.target = self
        switchPopup.action = #selector(switchHotkeyChanged)
        view.addSubview(switchPopup)
        switchHotkeyPopup = switchPopup
        y -= 34   // как зазор popup→rightOnly у триггера (попап высотой 26 на y-2)

        // issue #14: только правая клавиша хоткея смены (зеркало rightOnly триггера).
        let switchRightOnlyCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerRightOnly, target: self, action: #selector(switchRightOnlyChanged))
        switchRightOnlyCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        switchRightOnlyCheckbox.state = SettingsManager.shared.switchRightOnly ? .on : .off
        view.addSubview(switchRightOnlyCheckbox)
        y -= 26

        // issue #14: смена по двойному тапу выбранного хоткея (зеркало double-tap триггера).
        let switchDoubleTapCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerDoubleTap, target: self, action: #selector(switchDoubleTapChanged))
        switchDoubleTapCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        switchDoubleTapCheckbox.state = SettingsManager.shared.switchDoubleTap ? .on : .off
        view.addSubview(switchDoubleTapCheckbox)
        y -= 34

        // issue #29: отдельный хоткей смены регистра (последнее слово / выделение), как Alt+Break
        // в Punto. Должен отличаться от триггера и от хоткея смены раскладки (движок игнорирует совпадения).
        let caseLabel = NSTextField(labelWithString: L10n.settingsCaseHotkey)
        caseLabel.frame = NSRect(x: 20, y: y, width: 150, height: 22)
        view.addSubview(caseLabel)

        let casePopup = NSPopUpButton(frame: NSRect(x: 175, y: y - 2, width: 255, height: 26))
        populateCaseHotkeyPopup(casePopup)
        casePopup.target = self
        casePopup.action = #selector(caseHotkeyChanged)
        view.addSubview(casePopup)
        caseHotkeyPopup = casePopup
        y -= 34

        let caseRightOnlyCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerRightOnly, target: self, action: #selector(caseRightOnlyChanged))
        caseRightOnlyCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        caseRightOnlyCheckbox.state = SettingsManager.shared.caseRightOnly ? .on : .off
        view.addSubview(caseRightOnlyCheckbox)
        y -= 26

        let caseDoubleTapCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerDoubleTap, target: self, action: #selector(caseDoubleTapChanged))
        caseDoubleTapCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        caseDoubleTapCheckbox.state = SettingsManager.shared.caseDoubleTap ? .on : .off
        view.addSubview(caseDoubleTapCheckbox)
        y -= 32

        if !SettingsManager.shared.combinedShiftEnabled {
        let triggerHint = NSTextField(wrappingLabelWithString: L10n.settingsTriggerHint)
        triggerHint.frame = NSRect(x: 40, y: y - 22, width: 400, height: 36)
        triggerHint.font = .systemFont(ofSize: 11)
        triggerHint.textColor = .secondaryLabelColor
        view.addSubview(triggerHint)
        y -= 48
        }

        // Запуск при логине
        let loginCheckbox = NSButton(checkboxWithTitle: L10n.settingsLaunchAtLogin, target: self, action: #selector(launchAtLoginChanged))
        loginCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        loginCheckbox.state = SettingsManager.shared.launchAtLogin ? .on : .off
        view.addSubview(loginCheckbox)
        launchAtLoginCheckbox = loginCheckbox
        y -= 30

        // Запоминание раскладки по приложению
        let perAppCheckbox = NSButton(checkboxWithTitle: L10n.settingsPerAppLayout, target: self, action: #selector(perAppLayoutChanged))
        perAppCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        perAppCheckbox.state = SettingsManager.shared.perAppLayout ? .on : .off
        view.addSubview(perAppCheckbox)
        y -= 30

        // Авто-проверка обновлений
        let updCheckbox = NSButton(checkboxWithTitle: L10n.settingsCheckUpdates,
                                   target: self, action: #selector(checkUpdatesEnabledChanged))
        updCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        updCheckbox.state = SettingsManager.shared.checkUpdatesEnabled ? .on : .off
        updCheckbox.toolTip = L10n.settingsCheckUpdatesHint
        view.addSubview(updCheckbox)
        checkUpdatesCheckbox = updCheckbox
        y -= 18

        let updHint = NSTextField(wrappingLabelWithString: L10n.settingsCheckUpdatesHint)
        updHint.frame = NSRect(x: 40, y: y - 18, width: 400, height: 32)
        updHint.font = .systemFont(ofSize: 11)
        updHint.textColor = .secondaryLabelColor
        view.addSubview(updHint)
        y -= 40

        // Язык интерфейса
        let langLabel = NSTextField(labelWithString: L10n.settingsLanguage)
        langLabel.frame = NSRect(x: 20, y: y, width: 130, height: 22)
        view.addSubview(langLabel)

        let langPopup = NSPopUpButton(frame: NSRect(x: 155, y: y - 2, width: 275, height: 26))
        populateLanguagePopup(langPopup)
        langPopup.target = self
        langPopup.action = #selector(languageChanged)
        view.addSubview(langPopup)
        languagePopup = langPopup
        y -= 40

        // Раскладка 1
        let label1 = NSTextField(labelWithString: L10n.settingsLayout1)
        label1.frame = NSRect(x: 20, y: y, width: 100, height: 22)
        view.addSubview(label1)

        let popup1 = NSPopUpButton(frame: NSRect(x: 130, y: y - 2, width: 300, height: 26))
        populateLayoutPopup(popup1, selectedID: SettingsManager.shared.layout1ID)
        popup1.target = self
        popup1.action = #selector(layout1Changed)
        view.addSubview(popup1)
        layout1Popup = popup1
        y -= 35

        // Раскладка 2
        let label2 = NSTextField(labelWithString: L10n.settingsLayout2)
        label2.frame = NSRect(x: 20, y: y, width: 100, height: 22)
        view.addSubview(label2)

        let popup2 = NSPopUpButton(frame: NSRect(x: 130, y: y - 2, width: 300, height: 26))
        populateLayoutPopup(popup2, selectedID: SettingsManager.shared.layout2ID)
        popup2.target = self
        popup2.action = #selector(layout2Changed)
        view.addSubview(popup2)
        layout2Popup = popup2
        y -= 50

        if !SettingsManager.shared.combinedShiftEnabled {
            // Описание хоткея
            let hotkeyLabel = NSTextField(wrappingLabelWithString: L10n.settingsHotkey)
            hotkeyLabel.frame = NSRect(x: 20, y: y - 40, width: 420, height: 55)
            hotkeyLabel.font = .systemFont(ofSize: 12)
            hotkeyLabel.textColor = .secondaryLabelColor
            view.addSubview(hotkeyLabel)
        }

        fitToText(view)
        item.view = topAligned(view)
        return item
    }

    // MARK: - Exceptions Tab

    private func createExceptionsTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabExceptions

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
        var y: CGFloat = 586          // y — верх следующего элемента, идём сверху вниз
        exceptionEditors.removeAll()
        exceptionHeaders.removeAll()

        // Авто-конвертация
        let autoConvert = NSButton(checkboxWithTitle: L10n.settingsAutoConvert, target: self, action: #selector(autoConvertChanged))
        autoConvert.frame = NSRect(x: 0, y: y - 22, width: 560, height: 22)
        autoConvert.state = SettingsManager.shared.automaticTextEnabled ? .on : .off
        view.addSubview(autoConvert)
        autoConvertCheckboxes.append(autoConvert)
        y -= 24
        let acHint = NSTextField(wrappingLabelWithString: L10n.settingsAutoConvertHint)
        acHint.frame = NSRect(x: 20, y: y - 32, width: 540, height: 32)
        acHint.font = .systemFont(ofSize: 11); acHint.textColor = .secondaryLabelColor
        view.addSubview(acHint)
        y -= 38

        let russianPriority = NSButton(checkboxWithTitle: L10n.text("settings.russianPriority"),
            target: self, action: #selector(russianPriorityChanged))
        russianPriority.frame = NSRect(x: 0, y: y - 22, width: 560, height: 22)
        russianPriority.state = SettingsManager.shared.russianPriorityEnabled ? .on : .off
        russianPriority.toolTip = L10n.text("settings.russianPriority.tip")
        view.addSubview(russianPriority)
        y -= 32

        // Флаг у курсора (issue #10)
        let caretFlag = NSButton(checkboxWithTitle: L10n.settingsCaretFlag, target: self, action: #selector(caretFlagChanged))
        caretFlag.frame = NSRect(x: 0, y: y - 22, width: 560, height: 22)
        caretFlag.state = SettingsManager.shared.caretFlag ? .on : .off
        view.addSubview(caretFlag)
        caretFlagCheckbox = caretFlag
        y -= 24
        let cfHint = NSTextField(wrappingLabelWithString: L10n.settingsCaretFlagHint)
        cfHint.frame = NSRect(x: 20, y: y - 44, width: 540, height: 44)
        cfHint.font = .systemFont(ofSize: 11); cfHint.textColor = .secondaryLabelColor
        view.addSubview(cfHint)
        y -= 52

        // Режим удалённого стола отложен в 2.5 — блок скрыт за флагом (для тестирования).
        if SettingsManager.shared.showRemoteDesktopBeta {
            let remote = NSButton(checkboxWithTitle: L10n.menuRemoteDesktop, target: self, action: #selector(remoteDesktopChanged))
            remote.frame = NSRect(x: 0, y: y - 22, width: 560, height: 22)
            remote.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
            view.addSubview(remote)
            remoteDesktopCheckbox = remote
            y -= 24
            let rHint = NSTextField(wrappingLabelWithString: L10n.settingsRemoteDesktopHint)
            rHint.frame = NSRect(x: 20, y: y - 44, width: 540, height: 44)
            rHint.font = .systemFont(ofSize: 11); rHint.textColor = .secondaryLabelColor
            view.addSubview(rHint)
            y -= 52
        }

        // Секция: заголовок сверху, ниже — таблица с кнопками. Зазоры фиксированные,
        // поэтому раскладка одинаково корректна на всех языках (заголовки не переносятся).
        func addSection(_ title: String, _ editor: ExceptionListEditor) {
            let header = NSTextField(labelWithString: title)
            header.frame = NSRect(x: 0, y: y - 18, width: 560, height: 18)
            header.font = .boldSystemFont(ofSize: 11)
            header.lineBreakMode = .byTruncatingTail
            view.addSubview(header)
            exceptionHeaders.append(header)
            let contH: CGFloat = 96
            let cont = editor.makeContainer(frame: NSRect(x: 0, y: y - 22 - contH, width: 560, height: contH))
            view.addSubview(cont)
            exceptionEditors.append(editor)
            y -= (22 + contH + 14)   // заголовок+зазор + таблица + зазор до следующей секции
        }

        addSection(L10n.settingsExceptionsApps, ExceptionListEditor(
            kind: .apps,
            get: { SettingsManager.shared.deniedApps },
            set: { SettingsManager.shared.deniedApps = $0 }))

        addSection(L10n.settingsExceptionsNever, ExceptionListEditor(
            kind: .words,
            get: { SettingsManager.shared.deniedWords },
            set: { SettingsManager.shared.deniedWords = $0 },
            addWordPrompt: L10n.settingsAddWordPrompt))

        addSection(L10n.settingsExceptionsAlways, ExceptionListEditor(
            kind: .words,
            get: { SettingsManager.shared.alwaysConvertWords },
            set: { SettingsManager.shared.alwaysConvertWords = $0 },
            addWordPrompt: L10n.settingsAddWordPrompt))

        fitToText(view, left: 0, right: 560)
        item.view = topAligned(view)
        return item
    }

    // MARK: - About Tab

    private func createPersonalDictionaryTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.nativeDictionaryEntry
        let view = PersonalDictionaryView(frame: NSRect(x: 0, y: 0, width: Self.columnWidth, height: 480))
        view.onChanged = { [weak self] in self?.onPredictionPreferencesChanged?() }
        item.view = topAligned(view)
        return item
    }

    private func createAdaptiveRulesTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.nativeLearningEntry
        let view = AdaptiveRulesView(frame: NSRect(x: 0, y: 0, width: Self.columnWidth, height: 480))
        view.onChanged = { [weak self] in self?.onPredictionPreferencesChanged?() }
        item.view = topAligned(view)
        return item
    }

    // MARK: - About Tab

    private func createAboutTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabAbout

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))

        let appIcon = NSImageView(image: NSApp.applicationIconImage)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.frame = NSRect(x: 240, y: 300, width: 80, height: 80)
        view.addSubview(appIcon)

        let titleLabel = NSTextField(labelWithString: "MacSwitcher")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 0, y: 256, width: 560, height: 28)
        view.addSubview(titleLabel)

        let releaseVersion = Bundle.main.object(forInfoDictionaryKey: "MacSwitcherReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "?"
        let versionLabel = NSTextField(labelWithString: releaseVersion)
        versionLabel.frame = NSRect(x: 0, y: 232, width: 560, height: 18)
        versionLabel.alignment = .center
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        view.addSubview(versionLabel)

        let purpose = NSTextField(wrappingLabelWithString: L10n.settingsVersion)
        purpose.frame = NSRect(x: 0, y: 190, width: 560, height: 32)
        purpose.alignment = .center
        purpose.font = .systemFont(ofSize: 12)
        purpose.textColor = .secondaryLabelColor
        view.addSubview(purpose)

        let siteLink = NSButton(title: "github.com/alexfisenkov/MacSwitcher", target: self, action: #selector(openWebsite))
        siteLink.isBordered = false
        siteLink.attributedTitle = NSAttributedString(string: "github.com/alexfisenkov/MacSwitcher", attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 12),
        ])
        siteLink.frame = NSRect(x: 0, y: 150, width: 560, height: 22)
        view.addSubview(siteLink)

        let contactBtn = NSButton(title: L10n.text("settings.report"),
                                  target: self, action: #selector(openContact))
        contactBtn.frame = NSRect(x: 0, y: 102, width: 560, height: 32)
        contactBtn.bezelStyle = .rounded
        view.addSubview(contactBtn)

        let updateBtn = NSButton(title: L10n.menuCheckUpdates, target: self, action: #selector(checkUpdates))
        updateBtn.frame = NSRect(x: 0, y: 58, width: 560, height: 32)
        updateBtn.bezelStyle = .rounded
        view.addSubview(updateBtn)

        fitToText(view, left: 0, right: 560)
        item.view = topAligned(view)
        return item
    }

    // MARK: - Advanced Tab

    /// «More»: two blocks. «Check» holds what verifies the app; «For advanced users» holds
    /// rare switches. Both sit in the same 560 pt column as every other pane.
    private func createAdvancedTab(showBackupWarning: Bool, showNativePerApp: Bool) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabAdvanced
        let settings = SettingsManager.shared
        var column = SettingsColumn()
        column.left = 0
        if showBackupWarning {
            column.add(Self.measuredLabel(L10n.nativeBackupUnavailable, size: 12,
                width: Self.columnWidth, secondary: true), gap: 10)
        }

        let check = SettingsFormGroup()
        check.addTitle(L10n.settingsCheckSection)
        check.addButtons([
            NSButton(title: L10n.menuCheckPermissions, target: self, action: #selector(permissionCheckRequested)),
            NSButton(title: L10n.nativeRuntimeCheck, target: self, action: #selector(runtimeCheckRequested))])
        check.addButtons([
            NSButton(title: L10n.menuCheckUpdates, target: self, action: #selector(updateCheckRequested)),
            NSButton(title: L10n.settingsTabAbout, target: self, action: #selector(openAboutSettings))])
        column.add(check.makeBox(identifier: "settings.section.check"))

        let expert = SettingsFormGroup()
        let width = expert.innerWidth
        func checkbox(_ title: String, _ action: Selector, _ on: Bool, hint: String? = nil) -> NSButton {
            let box = Self.wrappingCheckbox(title, target: self, action: action, on: on, width: width)
            expert.add(box, gap: hint == nil ? 10 : 2)
            if let hint {
                expert.add(Self.measuredLabel(hint, size: 11, width: width - 20, secondary: true),
                    indent: 20, gap: 10)
            }
            return box
        }
        expert.addTitle(L10n.settingsExpertSection)
        if showNativePerApp {
            _ = checkbox(L10n.settingsPerAppLayout, #selector(perAppLayoutChanged), settings.perAppBackgroundEnabled)
        }
        _ = checkbox(L10n.nativeShellEnabled, #selector(shellBridgeChanged), settings.shellBridgeEnabled)
        let setup = NSButton(title: L10n.nativeShellSetup, target: self, action: #selector(shellBridgeSetupRequested))
        setup.frame.size = NSSize(width: max(200, ceil(setup.cell?.cellSize.width ?? 0) + 2), height: 28)
        expert.add(setup, gap: 12)

        let intervalTitle = Self.measuredLabel(L10n.nativeShiftInterval, size: 13, width: 190)
        let interval = NSSlider(frame: NSRect(x: 0, y: 0, width: width - 190 - 8 - 80 - 8, height: 25))
        interval.minValue = 80
        interval.maxValue = 400
        interval.integerValue = settings.doubleShiftIntervalMilliseconds
        interval.target = self
        interval.action = #selector(doubleShiftIntervalChanged)
        let value = NSTextField(labelWithString: L10n.settingsIntervalValue(interval.integerValue))
        value.frame.size = NSSize(width: 80, height: 18)
        intervalValueLabel = value
        expert.add([(intervalTitle, 0), (interval, 198), (value, width - 80)], gap: 12)

        expert.addButtons([
            NSButton(title: L10n.nativeOpenOriginals, target: self, action: #selector(recoveryOriginalsRequested)),
            NSButton(title: L10n.nativeOpenArchive, target: self, action: #selector(recoveryArchiveFolderRequested))],
            gap: 12)
        _ = checkbox(L10n.text("settings.recoveryAuto"),
            #selector(recoveryArchiveChanged(_:)), settings.automaticRecoveryArchiveEnabled,
            hint: L10n.text("settings.recoveryAuto.hint"))
        _ = checkbox(L10n.settingsBetaChannel, #selector(betaChannelChanged), settings.betaChannelEnabled,
            hint: L10n.settingsBetaChannelHint)
        _ = checkbox(L10n.settingsSmartConversion, #selector(smartConversionChanged), settings.smartConversion,
            hint: L10n.settingsSmartConversionHint)
        _ = checkbox(L10n.settingsConvertByText, #selector(convertByTextChanged), settings.convertByText,
            hint: L10n.settingsConvertByTextHint)
        _ = checkbox(L10n.settingsConvertWholeLine, #selector(convertWholeLineChanged), settings.convertWholeLine,
            hint: L10n.settingsConvertWholeLineHint)
        _ = checkbox(L10n.settingsSecureNotice, #selector(secureNoticeChanged), settings.secureInputNoticeEnabled)
        _ = checkbox(L10n.settingsHideIcon, #selector(hideIconChanged(_:)), settings.hideMenuBarIcon,
            hint: L10n.settingsHideIconHint)
        _ = checkbox(L10n.menuKeySound, #selector(keySoundChanged), settings.keySound)
        _ = checkbox(L10n.settingsCompactMenu, #selector(compactMenuChanged(_:)), settings.compactMenu,
            hint: L10n.settingsCompactMenuHint)
        column.add(expert.makeBox(identifier: "settings.section.expert"), gap: 0)

        item.view = topAligned(column.makeView(width: Self.columnWidth, top: 4, bottom: 16))
        return item
    }

    @objc private func hideIconChanged(_ sender: NSButton) {
        let hide = sender.state == .on
        if hide {
            // Подтверждение с рецептом возврата — снимает страх «а как я его потом найду».
            let alert = NSAlert()
            alert.messageText = L10n.settingsHideIconAlertTitle
            alert.informativeText = L10n.settingsHideIconAlertText
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.settingsHideIcon)
            alert.addButton(withTitle: L10n.commonCancel)
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn {
                sender.state = .off
                return
            }
        }
        SettingsManager.shared.hideMenuBarIcon = hide
        onHideIconChanged?(hide)
    }

    @objc private func keySoundChanged(_ sender: NSButton) {
        SettingsManager.shared.keySound = sender.state == .on
    }

    @objc private func monochromeIconChanged(_ sender: NSButton) {
        SettingsManager.shared.monochromeIcon = sender.state == .on
        onStatusAppearanceChanged?()
    }

    @objc private func recoveryArchiveChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        if enabled {
            let alert = NSAlert()
            alert.messageText = L10n.text("settings.recoveryAuto.alert.title")
            alert.informativeText = L10n.text("settings.recoveryAuto.alert.body")
            alert.addButton(withTitle: L10n.text("settings.recoveryAuto.alert.enable"))
            alert.addButton(withTitle: L10n.commonCancel)
            if alert.runModal() != .alertFirstButtonReturn { sender.state = .off; return }
        }
        SettingsManager.shared.automaticRecoveryArchiveEnabled = enabled
        onRecoveryArchiveChanged?(enabled)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Language Popup

    private func populateLanguagePopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        popup.addItem(withTitle: "🌐 \(L10n.settingsLanguageAuto)")
        popup.menu?.items.last?.representedObject = "" as NSString

        for lang in L10n.languageNames {
            popup.addItem(withTitle: lang.name)
            popup.menu?.items.last?.representedObject = lang.code as NSString
        }

        selectItem(in: popup, matching: SettingsManager.shared.interfaceLanguage)
    }

    /// Выбирает в popup пункт, у которого representedObject == id (или первый при пустом id)
    private func selectItem(in popup: NSPopUpButton, matching id: String) {
        if id.isEmpty {
            popup.selectItem(at: 0)
            return
        }
        for (i, item) in popup.itemArray.enumerated() {
            if (item.representedObject as? String) == id {
                popup.selectItem(at: i)
                return
            }
        }
        popup.selectItem(at: 0)
    }

    // MARK: - Layout Popup

    private func populateLayoutPopup(_ popup: NSPopUpButton, selectedID: String) {
        popup.removeAllItems()
        popup.addItem(withTitle: L10n.settingsAutoDetect)
        popup.menu?.items.last?.representedObject = "" as NSString

        let layouts = LayoutSwitcher.installedLayouts()
        for layout in layouts {
            let id = LayoutSwitcher.sourceID(layout)
            let name = LayoutSwitcher.sourceName(layout)
            popup.addItem(withTitle: "\(name) (\(id.components(separatedBy: ".").last ?? id))")
            popup.menu?.items.last?.representedObject = id as NSString
        }

        selectItem(in: popup, matching: selectedID)
    }

    private func selectedLayoutID(from popup: NSPopUpButton) -> String {
        (popup.selectedItem?.representedObject as? String) ?? ""
    }

    // MARK: - Trigger Popup

    private func populateTriggerPopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        // Имена клавиш не локализуем — это стандартные обозначения Apple.
        let items: [(key: String, title: String)] = [
            ("option", "Option ⌥ (Alt)"),
            ("command", "Command ⌘"),
            ("control", "Control ⌃"),
            ("shift", "Shift ⇧"),
            // Caps Lock убран: нативный перехват нестабилен (HID-дебаунс/тоггл) — см. техдолг.
        ]
        // issue #12: комбо двух модификаторов (привычный по Windows стиль Alt+Shift).
        let comboItems: [(key: String, title: String)] = [
            ("option+shift", "⌥ + ⇧  (Option + Shift)"),   // discussion #32: виндовый дефолт
            ("command+shift", "⌘ + ⇧  (Command + Shift)"),
            ("control+shift", "⌃ + ⇧  (Control + Shift)"),
            ("command+option", "⌘ + ⌥  (Command + Option)"),
            ("control+option", "⌃ + ⌥  (Control + Option)"),
        ]
        for it in items {
            popup.addItem(withTitle: it.title)
            popup.menu?.items.last?.representedObject = it.key as NSString
        }
        popup.menu?.addItem(.separator())
        for it in comboItems {
            popup.addItem(withTitle: it.title)
            popup.menu?.items.last?.representedObject = it.key as NSString
        }
        selectItem(in: popup, matching: SettingsManager.shared.triggerKey)
    }

    // MARK: - Actions

    @objc private func autoSwitchChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.autoSwitchEnabled = enabled
        onAutoSwitchChanged?(enabled)
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        SettingsManager.shared.launchAtLogin = sender.state == .on
    }

    @objc private func checkUpdatesEnabledChanged(_ sender: NSButton) {
        SettingsManager.shared.checkUpdatesEnabled = sender.state == .on
        UpdateChecker.setAutomaticChecks(SettingsManager.shared.checkUpdatesEnabled)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let langCode = (sender.selectedItem?.representedObject as? String) ?? ""
        SettingsManager.shared.interfaceLanguage = langCode  // вызывает L10n.reloadLanguage()
        onLanguageChanged?()  // пересобрать меню статус-бара под новый язык
        // Пересоздаём окно для применения нового языка
        window?.close()
        window = nil
        showWindow()
    }

    @objc private func layout1Changed(_ sender: NSPopUpButton) {
        SettingsManager.shared.layout1ID = selectedLayoutID(from: sender)
        DynamicKeyMapping.clearCache()
    }

    @objc private func layout2Changed(_ sender: NSPopUpButton) {
        SettingsManager.shared.layout2ID = selectedLayoutID(from: sender)
        DynamicKeyMapping.clearCache()
    }

    @objc private func perAppLayoutChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.perAppBackgroundEnabled = enabled
        onPerAppLayoutChanged?(enabled)
    }

    @objc private func triggerChanged(_ sender: NSPopUpButton) {
        SettingsManager.shared.triggerKey = (sender.selectedItem?.representedObject as? String) ?? "option"
        onTriggerChanged?()
        // issue #3: «занят триггером» в списке хоткея смены зависит от текущего триггера —
        // пере-populate, иначе метка устареет и можно выбрать хоткей = триггеру (молча мёртвый).
        if let p = switchHotkeyPopup { populateSwitchHotkeyPopup(p) }
        if let p = caseHotkeyPopup { populateCaseHotkeyPopup(p) }   // issue #29: та же логика для хоткея регистра
    }

    @objc private func combinedShiftChanged(_ sender: NSButton) {
        SettingsManager.shared.combinedShiftEnabled = sender.state == .on
        onCombinedShiftChanged?()
        refreshGeneralTabPresentation()
    }

    @objc private func shellBridgeChanged(_ sender: NSButton) {
        SettingsManager.shared.shellBridgeEnabled = sender.state == .on
        onCombinedShiftChanged?()
    }

    @objc private func shellBridgeSetupRequested() {
        onShellBridgeSetupRequested?()
    }

    @objc private func runtimeCheckRequested() {
        onRuntimeCheckRequested?()
    }

    @objc private func permissionCheckRequested() {
        onPermissionCheckRequested?()
    }

    @objc private func updateCheckRequested() {
        onUpdateCheckRequested?()
    }

    @objc private func inputSourceRequested() {
        onInputSourceRequested?()
    }

    @objc private func recoveryOriginalsRequested() {
        onRecoveryOriginalsRequested?()
    }

    @objc private func recoveryArchiveFolderRequested() {
        onRecoveryArchiveFolderRequested?()
    }


    private func refreshGeneralTabPresentation() {
        refreshGeneralTabPresentation { createGeneralTab() }
        if let p = switchHotkeyPopup { populateSwitchHotkeyPopup(p) }
        if let p = caseHotkeyPopup { populateCaseHotkeyPopup(p) }
    }

    /// Replace the general pane while keeping its selected state and the sidebar in sync.
    /// The factory also gives UI tests a way to exercise refresh without reading user settings.
    func refreshGeneralTabPresentation(makeReplacement: () -> NSTabViewItem) {
        let tabView = (settingsTabView?.tabViewItems.last?.view as? NSTabView) ?? settingsTabView
        guard let tabView,
              let oldItem = tabView.tabViewItems.first(where: { ($0.identifier as? String) == "settings.general" }) else { return }
        let selectedGeneral = tabView.selectedTabViewItem === oldItem
        let index = tabView.indexOfTabViewItem(oldItem)
        let replacement = makeReplacement()
        tabView.removeTabViewItem(oldItem)
        tabView.insertTabViewItem(replacement, at: index)
        if selectedGeneral { tabView.selectTabViewItem(replacement) }
        navigationTable?.reloadData()
        resizeSettingsWindow(for: tabView)
    }

    @objc private func doubleShiftIntervalChanged(_ sender: NSSlider) {
        SettingsManager.shared.doubleShiftIntervalMilliseconds = sender.integerValue
        intervalValueLabel?.stringValue = L10n.settingsIntervalValue(
            SettingsManager.shared.doubleShiftIntervalMilliseconds)
        onCombinedShiftChanged?()
    }

    @objc private func russianPriorityChanged(_ sender: NSButton) {
        SettingsManager.shared.russianPriorityEnabled = sender.state == .on
        onPredictionPreferencesChanged?()
    }

    /// issue #14: попап второго хоткея — «Выключен» + те же модификаторы/комбо (без Caps Lock).
    private func populateSwitchHotkeyPopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        popup.addItem(withTitle: L10n.settingsSwitchHotkeyOff)
        popup.menu?.items.last?.representedObject = "" as NSString
        popup.menu?.addItem(.separator())
        let items: [(key: String, title: String)] = [
            ("option", "Option ⌥ (Alt)"),
            ("command", "Command ⌘"),
            ("control", "Control ⌃"),
            ("shift", "Shift ⇧"),
        ]
        let comboItems: [(key: String, title: String)] = [
            ("option+shift", "⌥ + ⇧  (Option + Shift)"),   // discussion #32: виндовый дефолт
            ("command+shift", "⌘ + ⇧  (Command + Shift)"),
            ("control+shift", "⌃ + ⇧  (Control + Shift)"),
            ("command+option", "⌘ + ⌥  (Command + Option)"),
            ("control+option", "⌃ + ⌥  (Control + Option)"),
        ]
        for it in items {
            popup.addItem(withTitle: it.title)
            popup.menu?.items.last?.representedObject = it.key as NSString
        }
        popup.menu?.addItem(.separator())
        for it in comboItems {
            popup.addItem(withTitle: it.title)
            popup.menu?.items.last?.representedObject = it.key as NSString
        }
        // Пункт, совпадающий с триггером конверсии, гасим: движок его всё равно
        // игнорирует (один тап не должен делать два действия) — не даём выбрать
        // «мёртвую» настройку без индикации (ревью-находка).
        popup.autoenablesItems = false
        let triggerKey = SettingsManager.shared.triggerKey
        for item in popup.menu?.items ?? [] where (item.representedObject as? String) == triggerKey {
            item.isEnabled = false
            // issue #20: не оставлять пункт немым серым — объяснить, что он занят триггером.
            item.title += L10n.settingsSwitchHotkeyBusy
            item.toolTip = L10n.settingsSwitchHotkeyBusy
        }
        if SettingsManager.shared.combinedShiftEnabled {
            for item in popup.menu?.items ?? [] where (item.representedObject as? String) == "shift" {
                item.isEnabled = false
                item.toolTip = "Shift используется совместным режимом одиночного и двойного нажатия."
            }
        }
        let current = SettingsManager.shared.switchHotkey
        if let idx = popup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == current }) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func switchHotkeyChanged(_ sender: NSPopUpButton) {
        SettingsManager.shared.switchHotkey = (sender.selectedItem?.representedObject as? String) ?? ""
        onTriggerChanged?()   // reconfigure перечитает и switchConfig
        if let p = caseHotkeyPopup { populateCaseHotkeyPopup(p) }   // issue #29: хоткей регистра не должен совпасть со сменой раскладки
    }

    /// issue #29: список хоткеев смены регистра. Гасим совпадения с триггером И с хоткеем смены
    /// раскладки — движок их всё равно игнорирует (один тап = одно действие).
    private func populateCaseHotkeyPopup(_ popup: NSPopUpButton) {
        populateSwitchHotkeyPopup(popup)   // те же пункты
        popup.autoenablesItems = false
        let taken: Set<String> = [SettingsManager.shared.triggerKey, SettingsManager.shared.switchHotkey]
        for item in popup.menu?.items ?? [] {
            let key = (item.representedObject as? String) ?? ""
            if !key.isEmpty && taken.contains(key) {
                item.isEnabled = false
                if !item.title.hasSuffix(L10n.settingsSwitchHotkeyBusy) { item.title += L10n.settingsSwitchHotkeyBusy }
            }
        }
        let current = SettingsManager.shared.caseHotkey
        if let idx = popup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == current }) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func caseHotkeyChanged(_ sender: NSPopUpButton) {
        SettingsManager.shared.caseHotkey = (sender.selectedItem?.representedObject as? String) ?? ""
        onTriggerChanged?()
    }

    @objc private func caseDoubleTapChanged(_ sender: NSButton) {
        SettingsManager.shared.caseDoubleTap = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func caseRightOnlyChanged(_ sender: NSButton) {
        SettingsManager.shared.caseRightOnly = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func switchDoubleTapChanged(_ sender: NSButton) {
        SettingsManager.shared.switchDoubleTap = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func switchRightOnlyChanged(_ sender: NSButton) {
        SettingsManager.shared.switchRightOnly = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func triggerRightOnlyChanged(_ sender: NSButton) {
        SettingsManager.shared.triggerRightOnly = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func triggerDoubleTapChanged(_ sender: NSButton) {
        SettingsManager.shared.triggerDoubleTap = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func autoConvertChanged(_ sender: NSButton) {
        setAutomaticText(sender.state == .on)
    }

    @objc private func autoConvertSwitchChanged(_ sender: NSSwitch) {
        setAutomaticText(sender.state == .on)
    }

    private func setAutomaticText(_ enabled: Bool) {
        SettingsManager.shared.automaticTextEnabled = enabled
        let effective = SettingsManager.shared.automaticTextEnabled
        updateAutoConvertState(effective)
        onAutoConvertChanged?(effective)
    }

    @objc private func remoteDesktopChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.remoteDesktopMode = enabled
        onRemoteDesktopChanged?(enabled)
    }

    @objc private func caretFlagChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.caretFlag = enabled
        onCaretFlagChanged?(enabled)
    }

    @objc private func betaChannelChanged(_ sender: NSButton) {
        SettingsManager.shared.betaChannelEnabled = sender.state == .on
        UpdateChecker.setBetaChannel(SettingsManager.shared.betaChannelEnabled)
    }

    @objc private func smartConversionChanged(_ sender: NSButton) {
        SettingsManager.shared.smartConversion = sender.state == .on
    }

    @objc private func convertByTextChanged(_ sender: NSButton) {
        SettingsManager.shared.convertByText = sender.state == .on
    }

    @objc private func convertWholeLineChanged(_ sender: NSButton) {
        SettingsManager.shared.convertWholeLine = sender.state == .on
        refreshInstructionsTab()
    }

    @objc private func secureNoticeChanged(_ sender: NSButton) {
        SettingsManager.shared.secureInputNoticeEnabled = sender.state == .on
    }

    @objc private func openWebsite() {
        if let url = SettingsManager.websiteLink(medium: "about") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openDonate() {
        if let url = URL(string: SettingsManager.shared.donateURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openContact() {
        if let url = URL(string: SettingsManager.githubURL + "/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkUpdates() {
        UpdateChecker.checkNow()
    }

}

// MARK: - One column for every pane

extension SettingsWindowController {
    /// Every pane is 600 pt wide and puts its blocks in one column, x 20…580 — the same
    /// width as the three top buttons. Content inside a group starts 16 pt further in.
    static let paneWidth: CGFloat = 600
    static let columnX: CGFloat = 20
    static let columnWidth: CGFloat = 560
    static let groupPadding: CGFloat = 16

    /// A flat «⇧ Shift» plate: a label on a tinted rounded shape, not a button.
    func flatKeycap(_ text: String, frame: NSRect) -> NSBox {
        let plate = NSBox(frame: frame)
        plate.boxType = .custom
        plate.titlePosition = .noTitle
        plate.borderWidth = 0
        plate.fillColor = .quaternaryLabelColor
        plate.cornerRadius = 6
        plate.contentViewMargins = .zero
        plate.identifier = NSUserInterfaceItemIdentifier("shift.keycap")
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.frame = NSRect(x: 4, y: (frame.height - 17) / 2, width: frame.width - 8, height: 17)
        plate.contentView?.addSubview(label)
        return plate
    }

    static func measuredLabel(_ text: String, size: CGFloat, width: CGFloat,
                              secondary: Bool = false, bold: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        if secondary { label.textColor = .secondaryLabelColor }
        label.frame = NSRect(x: 0, y: 0, width: width, height: fittingHeight(label, width: width))
        return label
    }

    static func fittingHeight(_ control: NSControl, width: CGFloat) -> CGFloat {
        ceil(control.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
            height: 10_000)).height ?? control.frame.height)
    }

    /// Checkbox whose long translation wraps instead of being cut.
    static func wrappingCheckbox(_ title: String, target: AnyObject, action: Selector,
                                 on: Bool, width: CGFloat) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: target, action: action)
        box.state = on ? .on : .off
        box.frame.size.width = width
        if ceil(box.cell?.cellSize.width ?? 0) > width {
            box.cell?.wraps = true
            box.cell?.lineBreakMode = .byWordWrapping
        }
        box.frame.size.height = max(22, fittingHeight(box, width: width))
        return box
    }

    /// Row of bordered buttons: side by side when every title fits, otherwise one per row.
    static func buttonRows(_ buttons: [NSButton], width: CGFloat, gap: CGFloat = 12) -> [[NSButton]] {
        guard buttons.count > 1 else { return [buttons] }
        let each = (width - gap * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        let fits = buttons.allSatisfy { ceil($0.cell?.cellSize.width ?? 0) + 2 <= each }
        return fits ? [buttons] : buttons.map { [$0] }
    }
}

/// Top-down rows inside one 560 pt group; heights come from the real text, so long
/// translations grow the group instead of overlapping the next row.
@MainActor
final class SettingsFormGroup {
    private let width: CGFloat
    private let pad = SettingsWindowController.groupPadding
    private let verticalPad: CGFloat = 12
    private var rows: [(items: [(NSView, CGFloat)], height: CGFloat, gap: CGFloat)] = []
    var innerWidth: CGFloat { width - 2 * pad }

    init(width: CGFloat = SettingsWindowController.columnWidth) { self.width = width }

    /// Items carry their inner x offset; each is vertically centred in the row.
    func add(_ items: [(NSView, CGFloat)], gap: CGFloat = 8) {
        let height = items.map { $0.0.frame.height }.max() ?? 0
        rows.append((items, height, gap))
    }

    func add(_ view: NSView, indent: CGFloat = 0, gap: CGFloat = 8) {
        add([(view, indent)], gap: gap)
    }

    func addTitle(_ text: String) {
        add(SettingsWindowController.measuredLabel(text, size: 13, width: innerWidth, bold: true), gap: 6)
    }

    func addButtons(_ buttons: [NSButton], gap: CGFloat = 8) {
        for (index, row) in SettingsWindowController.buttonRows(buttons, width: innerWidth).enumerated() {
            let each = (innerWidth - 12 * CGFloat(row.count - 1)) / CGFloat(row.count)
            for button in row { button.frame.size = NSSize(width: each, height: 28) }
            add(row.enumerated().map { ($1, CGFloat($0) * (each + 12)) },
                gap: index == 0 && row.count < buttons.count ? 8 : gap)
        }
    }

    func makeBox(identifier: String? = nil) -> NSBox {
        let content = rows.enumerated().reduce(CGFloat(0)) { sum, row in
            sum + row.element.height + (row.offset == rows.count - 1 ? 0 : row.element.gap)
        }
        let height = content + 2 * verticalPad
        let box = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: height))
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 9
        box.contentViewMargins = .zero
        if let identifier { box.identifier = NSUserInterfaceItemIdentifier(identifier) }
        var top = height - verticalPad
        for row in rows {
            for (view, x) in row.items {
                view.frame.origin = NSPoint(x: pad + x,
                    y: top - row.height + (row.height - view.frame.height) / 2)
                box.contentView?.addSubview(view)
            }
            top -= row.height + row.gap
        }
        return box
    }
}

/// Stacks full-width blocks from the top of a pane with fixed gaps.
@MainActor
struct SettingsColumn {
    private var blocks: [(view: NSView, x: CGFloat, gap: CGFloat)] = []
    /// Left edge of blocks: 20 in a full pane, 0 in content that a wrapper already places at 20.
    var left: CGFloat = SettingsWindowController.columnX

    mutating func add(_ view: NSView, x: CGFloat? = nil, gap: CGFloat = 12) {
        blocks.append((view, x ?? left, gap))
    }

    /// Pane of the given width with blocks laid out from `top` points below its upper edge.
    func makeView(width: CGFloat, top: CGFloat = 16, bottom: CGFloat = 16) -> NSView {
        let content = blocks.enumerated().reduce(CGFloat(0)) { sum, block in
            sum + block.element.view.frame.height + (block.offset == blocks.count - 1 ? 0 : block.element.gap)
        }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: top + content + bottom))
        var y = view.frame.height - top
        for (block, x, gap) in blocks {
            block.frame.origin = NSPoint(x: x, y: y - block.frame.height)
            view.addSubview(block)
            y -= block.frame.height + gap
        }
        return view
    }
}
