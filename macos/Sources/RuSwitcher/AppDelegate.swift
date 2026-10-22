import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let keyboardMonitor = KeyboardMonitor()
    private let textConverter = TextConverter()
    private lazy var predictionCoordinator = PredictionCoordinator(monitor: keyboardMonitor, converter: textConverter)
    private let settingsController = SettingsWindowController()
    private let perAppLayoutManager = PerAppLayoutManager()
    private var permissionCheckTimer: Timer?
    private var iconRefreshTimer: Timer?
    private var monitoringActive = false
    private var caretIndicator: CaretIndicator?   // issue #10: флаг у каретки (бета, по умолчанию OFF)
    private let secureNotice = SecureInputNotice()  // issue #27: подсказка о защ. вводе без кражи фокуса
    private let correctionToast = CorrectionToast()
    private var lastFlagShown: String?            // идентичность раскладки для детекта смены (не title!)
    private var badgeCache: [String: NSImage] = [:]  // монохромные плашки, чтобы не перерисовывать 2с-опросом
    private var diagnosticRepro: DiagnosticReproController?
    private static let recoveryCopyItemTag = 71003
    private static let sourceRecoveryItemTag = 71004

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupSettingsCallbacks()
        syncLoginItem()
        // «Запускались раньше?» снимаем ДО визарда: он через startMonitoring →
        // offerLaunchAtLoginIfNeeded выставляет launchAtLoginAsked уже на этом же
        // первом запуске, иначе «Что нового» ложно показалось бы на свежей установке.
        let ranBefore = SettingsManager.shared.launchAtLoginAsked
        runPermissionWizard()
        showWhatsNewIfNeeded(hasRunBefore: ranBefore)
        showBetaWhatsNewIfNeeded()   // отдельная витрина для бет (текст из бета-фида)
        UpdateChecker.checkOnLaunch()
        // Прогрев NSSpellChecker: первый чек поднимает XPC AppleSpell (сотни мс на main) —
        // прогреваем в тихую паузу после старта, а не на первом пробеле пользователя.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in Dict.warmUp() }
        }

        // Скрытая иконка: reopen-событие приходит только УЖЕ работающему приложению.
        // Свежий РУЧНОЙ запуск со скрытой иконкой без этого блока «тих» (ни иконки, ни
        // окна — выглядит как «не запустилось»). Показываем настройки; автологин-старт
        // (флаг login-item в oapp Apple event) остаётся тихим, как и положено.
        if SettingsManager.shared.hideMenuBarIcon && !Self.launchedAsLoginItem() {
            settingsController.showWindow()
        }
        if CommandLine.arguments.contains("--diagnostic-panel") {
            diagnosticRepro = DiagnosticReproController(monitor: keyboardMonitor, converter: textConverter)
            diagnosticRepro?.show()
        }
    }

    /// Запущены ли мы как login item (автостарт): loginwindow помечает oapp-событие
    /// флагом keyAELaunchedAsLogInItem в propData.
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    private func setupSettingsCallbacks() {
        settingsController.onAutoSwitchChanged = { [weak self] _ in
            self?.resetCombinedShiftAfterPause()
            // Не адресуем пункт по индексу: с 2.5.0 item(at: 0) — строка версии, а со списком
            // раскладок индексы вообще динамические. Пересборка — как у соседних колбэков.
            self?.rebuildMenu()
        }
        settingsController.onPerAppLayoutChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.startPerAppLayout()
            } else {
                self.perAppLayoutManager.stop()
            }
        }
        settingsController.onLanguageChanged = { [weak self] in
            self?.rebuildMenu()
        }
        settingsController.onTriggerChanged = { [weak self] in
            self?.reconfigureTap()
        }
        settingsController.onCombinedShiftChanged = { [weak self] in
            self?.keyboardMonitor.resetCombinedShift()
            self?.textConverter.clearState()
            self?.reconfigureTap()
            self?.configurePredictionPreferences()
        }
        settingsController.onAutoConvertChanged = { [weak self] _ in
            self?.predictionCoordinator.invalidate()
            self?.keyboardMonitor.resetPredictionContext()
            self?.reconfigureTap()
            self?.rebuildMenu()  // синхронизировать галочку в меню
        }
        settingsController.onPredictionPreferencesChanged = { [weak self] in
            guard let self else { return }
            self.configurePredictionPreferences()
            self.predictionCoordinator.invalidate()
            self.keyboardMonitor.resetPredictionContext()
        }
        settingsController.onRemoteDesktopChanged = { [weak self] _ in
            self?.reconfigureTap()  // уровень tap зависит от режима
            self?.rebuildMenu()
        }
        settingsController.onCaretFlagChanged = { [weak self] _ in
            self?.rebuildMenu()          // синхронизировать галочку в меню
            self?.syncCaretIndicator()   // создать/снести индикатор + обновить гейт onUserInput
        }
        settingsController.onHideIconChanged = { [weak self] hide in
            self?.statusItem.isVisible = !hide
        }
    }

    private func configurePredictionPreferences() {
        keyboardMonitor.configureCombinedShiftTiming(.init(
            doubleWindowNanoseconds: UInt64(SettingsManager.shared.doubleShiftIntervalMilliseconds) * 1_000_000))
        predictionCoordinator.russianPriorityProvider = { SettingsManager.shared.russianPriorityEnabled }
        predictionCoordinator.phraseExceptionLookup = { original, language in
            PersonalWordStore.shared.containsPhrase(original: original, sourceLanguage: language)
        }
    }

    /// Повторный запуск приложения (двойной клик в «Программах», Spotlight, Launchpad) —
    /// стандартный для menu-bar-утилит путь добраться до настроек при СКРЫТОЙ иконке.
    /// Открываем настройки и при видимой иконке: reopen без реакции выглядит как «не работает».
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let diagnosticRepro { diagnosticRepro.show(); return false }
        settingsController.showWindow()
        return false
    }

    // MARK: - Learn-from-undo (предложить добавить слово в never-convert)

    /// Последняя авто-конвертация: слово (как было набрано) + время. Если пользователь
    /// сразу откатывает ручным триггером — предлагаем занести слово в исключения.
    private var lastAutoConverted: (word: String, at: Date)?
    /// Анти-наг: за сессию про одно слово спрашиваем один раз.
    private var offeredExceptionWords: Set<String> = []

    /// Анти-наг для уведомления о защищённом вводе (не чаще раза в N секунд).
    private var lastSecureNoticeAt: Date?

    /// Ручной триггер нажат, но активен защищённый ввод (фокус в поле пароля — часто во
    /// вкладке браузера в фоне) → конверсия by design не трогает клавиши. Без подсказки это
    /// выглядит как «приложение сломалось» (реальный кейс: пользователь мял триггер и лез в
    /// ioreg). Показываем разовое (троттлённое) объяснение с лечением.
    private func notifySecureInputPaused() {
        guard SettingsManager.shared.secureInputNoticeEnabled else { return }
        if let last = lastSecureNoticeAt, Date().timeIntervalSince(last) < 180 { return }
        lastSecureNoticeAt = Date()
        let holder = AutoSwitchPolicy.secureInputHolderName() ?? L10n.securePausedUnknownApp
        // issue #27: неактивирующая плашка вместо NSAlert.runModal() — модалка активировала
        // приложение и уводила фокус из поля пароля (пользователь терял место в терминале).
        secureNotice.show(title: L10n.securePausedTitle,
                          body: String(format: L10n.securePausedBody, holder))
    }

    /// Called after the edit lease finishes. Only a fresh TIS read may resolve
    /// the requested source; a queued request is not selection evidence.
    private func presentSourceFailure(targetID: String) {
        keyboardMonitor.recordObservedInputSource(LayoutSwitcher.currentLayoutID())
        guard keyboardMonitor.pendingInputSourceTargetID == targetID,
              let message = CombinedShiftFailure.sourceNotConfirmed.userMessage else { return }
        let name = LayoutSwitcher.installedLayouts().first(where: {
            LayoutSwitcher.sourceID($0) == targetID
        }).map(LayoutSwitcher.sourceName) ?? targetID
        secureNotice.show(title: "MacSwitcher", body: "\(message) Нужная раскладка: \(name).")
    }

    private func offerExceptionAfterUndo() {
        guard let last = lastAutoConverted, Date().timeIntervalSince(last.at) < 8 else { return }
        lastAutoConverted = nil
        let word = last.word
        let key = word.lowercased()
        guard !offeredExceptionWords.contains(key) else { return }
        offeredExceptionWords.insert(key)
        guard !SettingsManager.shared.deniedWordsSet.contains(key) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.learnQuestion(word)
        alert.addButton(withTitle: L10n.learnAdd)
        alert.addButton(withTitle: L10n.learnNotNow)
        if alert.runModal() == .alertFirstButtonReturn {
            var list = SettingsManager.shared.deniedWords
            list.append(word)
            SettingsManager.shared.deniedWords = list
            rslog("learn: added word (len=\(word.count)) to never-convert")
        }
    }

    private func startPerAppLayout() {
        perAppLayoutManager.onLayoutRestored = { [weak self] in
            self?.keyboardMonitor.markConverted()
            self?.textConverter.clearState()
            self?.updateStatusIcon()
        }
        perAppLayoutManager.start()
    }

    // MARK: - Login Item Sync

    /// Синхронизирует состояние автозагрузки с системой при старте.
    /// Если галочка включена, но Login Item потерян (переустановка/обновление) — перерегистрирует.
    /// Если галочка выключена, но Login Item есть — снимает.
    private func syncLoginItem() {
        let settings = SettingsManager.shared
        let wanted = settings.launchAtLogin
        let status = settings.loginItemStatus

        rslog("Login item sync: wanted=\(wanted) status=\(status.rawValue)")

        if wanted && status != .enabled {
            // Галочка стоит, но Login Item не активен — перерегистрируем
            rslog("Re-registering login item...")
            settings.launchAtLogin = true  // setter вызовет doUpdateLoginItem
        } else if !wanted && status == .enabled {
            // Галочка снята, но Login Item активен — убираем
            rslog("Unregistering stale login item...")
            settings.launchAtLogin = false
        }
    }

    // MARK: - Permission Wizard

    private func runPermissionWizard(interactive: Bool = false) {
        let acc = AXIsProcessTrusted()
        let inp = CGPreflightListenEventAccess()
        rslog("Permissions: accessibility=\(acc) inputMonitoring=\(inp)")

        if acc && inp {
            // Запоминаем что разрешения были даны
            SettingsManager.shared.permissionsWereGranted = true
            if !monitoringActive { startMonitoring() }
            // Ручная проверка из меню должна давать видимый отклик.
            if interactive { showPermissionsOKAlert() }
            return
        }

        // Проверяем: разрешения были раньше, а теперь сброшены (обновление)
        if SettingsManager.shared.permissionsWereGranted {
            rslog("Permissions were previously granted — reset detected after update")
            SettingsManager.shared.permissionsWereGranted = false
            showPermissionsResetAlert()
            return
        }

        // Первый запуск — обычный визард
        if acc {
            showStep_InputMonitoring()
            return
        }

        showStep_Accessibility()
    }

    /// Подтверждение при ручной проверке, когда все разрешения уже выданы
    private func showPermissionsOKAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.permissionsOkTitle
        alert.informativeText = L10n.permissionsOkText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Уведомление о сбросе разрешений после обновления
    private func showPermissionsResetAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardPermissionsResetTitle
        alert.informativeText = L10n.languageCode == "ru"
            ? "macOS отозвала одно из разрешений MacSwitcher. Проверьте Accessibility и Input Monitoring в Системных настройках. Действующие разрешения сохраняются."
            : "macOS revoked a MacSwitcher permission. Check Accessibility and Input Monitoring in System Settings. Existing permissions are preserved."
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Request only what is missing; never delete a working TCC grant.
        if AXIsProcessTrusted() { showStep_InputMonitoring() }
        else { showStep_Accessibility() }
    }

    private func showStep_Accessibility() {
        // AXIsProcessTrustedWithOptions с prompt=true показывает системный диалог
        // и добавляет программу в список Accessibility автоматически
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    rslog("Accessibility granted!")
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.showStep_InputMonitoring()
                }
            }
        }
    }

    private func showStep_InputMonitoring() {
        // CGRequestListenEventAccess() показывает системный диалог и добавляет
        // программу в список Input Monitoring автоматически
        let preflightOK = CGPreflightListenEventAccess()
        rslog("Preflight check = \(preflightOK)")

        if preflightOK {
            // Уже есть — сразу запускаем
            SettingsManager.shared.permissionsWereGranted = true
            startMonitoring()
            return
        }

        rslog("Requesting access...")
        CGRequestListenEventAccess()

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CGPreflightListenEventAccess() {
                    rslog("Input Monitoring granted! Restarting...")
                    SettingsManager.shared.permissionsWereGranted = true
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.restartApp()
                }
            }
        }
    }

    private func restartApp() {
        rslog("Restarting from: \(Bundle.main.bundlePath)")
        AppRelauncher.relaunch()
    }

    // MARK: - Start Monitoring

    private func startMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil

        if !keyboardMonitor.start(
            onAltTap: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                // Приватность: в защищённом поле (пароль) ничего не делаем — ставим ДО
                // remote-defer, чтобы поведение точно совпадало с handleAutoConvert.
                guard !AutoSwitchPolicy.secureInputActive else { rslog("trigger: bail secure-input"); self.notifySecureInputPaused(); return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                // issue #16: в Spotlight обычный путь оставляет лишнюю букву (серое
                // автодополнение съедает Backspace). Особый путь: Cmd+A + буфер, без
                // Backspace. Гейт isActive() строгий (окно видимо + Spotlight держит поле),
                // поэтому здесь мы ТОЧНО в Spotlight — конвертим только своим путём и НЕ
                // проваливаемся в буфер/count-пути (они тут дают лишнюю букву), что бы
                // convertSpotlight ни вернул.
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                        self.lastAutoConverted = nil
                    }
                    return
                }
                // issue #24: режим «вся строка».
                if SettingsManager.shared.convertWholeLine {
                    let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    if AutoSwitchPolicy.isTerminalApp(frontID) {
                        // Терминал: нет OS-выделения → перепечатываем строку по буферу нажатий.
                        // НЕПУСТОЙ буфер (в т.ч. no-op на уже верной строке) завершаем ЗДЕСЬ и НЕ
                        // проваливаемся на последнее слово — иначе безусловный флип испортил бы
                        // верное слово, напр. «git log»→«git дщп» (скептик 3.2.0). На слово падаем
                        // только при ПУСТОМ/сброшенном буфере (пунктуация/Enter/сдвиг курсора).
                        if !self.keyboardMonitor.lineKeys.isEmpty {
                            if self.textConverter.convertLineBuffer(self.keyboardMonitor.lineKeys) {
                                self.keyboardMonitor.markConverted()
                                LayoutSwitcher.switchToOpposite()
                                self.updateStatusIcon()
                                self.lastAutoConverted = nil
                            }
                            return
                        }
                    } else {
                        // Обычные приложения: сами выделяем строку (Shift+Cmd+←) и конвертируем.
                        if self.textConverter.convertLine() {
                            self.keyboardMonitor.markConverted()
                            LayoutSwitcher.switchToOpposite()
                            self.updateStatusIcon()
                            self.lastAutoConverted = nil
                        }
                        return   // whole-line в обычной проге — всегда завершаем (не last-word)
                    }
                }
                let keys = self.keyboardMonitor.currentWordKeys
                let prevKeys = self.keyboardMonitor.prevWordKeys
                let bc = self.keyboardMonitor.boundaryCount
                if self.textConverter.convert(wordKeys: keys, prevWordKeys: prevKeys, boundaryCount: bc) {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    self.lastAutoConverted = nil
                }
            },
            onAltReconvert: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                guard !AutoSwitchPolicy.secureInputActive else { rslog("reconvert: bail secure-input"); self.notifySecureInputPaused(); return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                // issue #16: в Spotlight реконверт — тот же путь (Cmd+A + буфер), он
                // реверсивен (конвертит текущее содержимое обратно). НЕ проваливаемся в
                // count-based reconvert() в Spotlight (skeptic: он вайпит буфер и селектит
                // по счётчику — ровно то, чего избегаем).
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                    }
                    return
                }
                if self.textConverter.reconvert() {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    self.offerExceptionAfterUndo()
                }
            }
        ) {
            rslog("Event tap failed - will retry in 5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startMonitoring()
            }
            return
        }

        monitoringActive = true
        configurePredictionPreferences()
        keyboardMonitor.onCombinedShift = { [weak self] request in
            self?.handleCombinedShift(request)
        }
        keyboardMonitor.onPredictionInput = { [weak self] snapshot in
            self?.predictionCoordinator.submit(snapshot)
        }
        keyboardMonitor.onPredictionInvalidated = { [weak self] in
            self?.predictionCoordinator.invalidate()
        }
        predictionCoordinator.onApplied = { [weak self] original in
            self?.diagnosticRepro?.noteAutomaticApplication()
            self?.updateStatusIcon()
        }
        predictionCoordinator.onCorrection = { [weak self] notice in
            guard let self else { return }
            self.correctionToast.show(original: notice.original, replacement: notice.replacement,
                onUndo: { [weak self] in
                    self?.predictionCoordinator.undoCorrection(id: notice.id) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .confirmed:
                            self.updateStatusIcon()
                        case .refused:
                            self.secureNotice.show(title: "MacSwitcher",
                                body: L10n.languageCode == "ru"
                                    ? "Текст или поле уже изменились. Отмена этой замены недоступна."
                                    : "The text or field has changed. This correction can no longer be undone.")
                        case .unknown:
                            if let message = CombinedShiftFailure.unconfirmedEdit.userMessage {
                                self.secureNotice.show(title: "MacSwitcher", body: message)
                            }
                        }
                    }
                },
                onNever: { [weak self] in
                    do {
                        try PersonalWordStore.shared.addPhrase(original: notice.original,
                            replacement: notice.replacement, sourceLanguage: notice.sourceLanguage)
                        self?.predictionCoordinator.invalidate()
                    } catch {
                        self?.secureNotice.show(title: "MacSwitcher",
                            body: L10n.languageCode == "ru"
                                ? "Не удалось сохранить исключение. Откройте личный словарь в настройках."
                                : "Could not save the exception. Open the personal dictionary in Settings.")
                    }
                })
        }
        predictionCoordinator.onUnconfirmedEdit = { [weak self] in
            guard let message = CombinedShiftFailure.unconfirmedEdit.userMessage else { return }
            self?.secureNotice.show(title: "MacSwitcher", body: message)
        }
        predictionCoordinator.onSourceFailure = { [weak self] target, _ in
            self?.presentSourceFailure(targetID: target)
        }
        keyboardMonitor.onUserInput = { [weak self] in self?.caretIndicator?.userTyped() }  // issue #10
        // issue #14: хоткей чистого переключения раскладки (без конверсии). Буфер после
        // явной смены раскладки неактуален — тот же паттерн, что per-app restore и меню.
        keyboardMonitor.onSwitchHotkey = { [weak self] in
            guard let self, SettingsManager.shared.autoSwitchEnabled else { return }
            if AutoSwitchPolicy.shouldDeferToRemoteClient {
                // Удалёнка (фокус в клиенте Screen Sharing): переключаем только СВОЮ
                // раскладку, как defer-ветка триггера. markConverted/clearState тут лишние —
                // буфер наполняется через handleForwardedChar, а проброшенные модификаторы
                // сами переключат раскладку на контролируемой машине.
                LayoutSwitcher.switchToOpposite()
                self.updateStatusIcon()
                rslog("switch hotkey: local layout switched (remote client focused)")
                return
            }
            LayoutSwitcher.switchToOpposite()
            self.keyboardMonitor.markConverted()
            self.textConverter.clearState()
            self.updateStatusIcon()
        }
        // issue #29: хоткей смены регистра последнего слова / выделения. Раскладку не трогает,
        // в защищённом поле — пас (приватность), как у триггера.
        keyboardMonitor.onCaseHotkey = { [weak self] in
            guard let self else { return }
            guard !AutoSwitchPolicy.secureInputActive else { rslog("case: bail secure-input"); self.notifySecureInputPaused(); return }
            // Скептик #29: те же гейты, что у onAltTap/onSwitchHotkey. Удалёнка — текст правит
            // контролируемый инстанс (у нас нет своей раскладки для флипа, регистр просто пропускаем).
            if AutoSwitchPolicy.shouldDeferToRemoteClient { rslog("case: bail remote-defer"); return }
            // Spotlight: count-путь оставил бы лишнюю букву (issue #16), а AX там флейкует — не трогаем.
            if SpotlightAX.isActive() { rslog("case: bail spotlight"); return }
            // issue #29: смена регистра зеркалит триггер конверсии — уважает «Convert whole line»
            // (запрос kobygold). Терминал → по буферу строки; обычное приложение → AX-выделение строки.
            if SettingsManager.shared.convertWholeLine {
                let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if AutoSwitchPolicy.isTerminalApp(frontID) {
                    if !self.keyboardMonitor.lineKeys.isEmpty {
                        if self.textConverter.changeCaseLineBuffer(self.keyboardMonitor.lineKeys) { self.textConverter.clearState() }
                        return   // непустой буфер строки — завершаем здесь (как onAltTap)
                    }
                    // пустой буфер → падаем на последнее слово ниже
                } else {
                    if self.textConverter.changeCaseLine() { self.textConverter.clearState() }
                    return   // обычное приложение, whole-line — всегда завершаем здесь
                }
            }
            // Скептик #29: НЕ markConverted() — буфер слова нужен, чтобы повторный тап циклил
            // регистр. Чистим reconvert-состояние, иначе следующий реконверт сработал бы по
            // устаревшим lastOriginal/lastConverted и испортил текст.
            let keys = self.keyboardMonitor.currentWordKeys
            if self.textConverter.changeCase(wordKeys: keys) {
                self.textConverter.clearState()
            }
        }
        updateStatusIcon()        // сначала выставляем флаг меню-бара, пока индикатора ещё нет
        syncCaretIndicator()      // затем создаём индикатор — без стартового ложного «попа»
        // Страховка к issue #9: системное уведомление о смене раскладки ненадёжно
        // (особенно через удалённый стол — на той машине оно часто не доходит), поэтому
        // флаг «застревает». Постоянный лёгкий опрос держит иконку в синхроне с системой.
        iconRefreshTimer?.invalidate()
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.monitoringActive, self.keyboardMonitor.nativeFenceNeedsRecovery {
                    // A timed-out lease stays invalid. Replace the tap/fence
                    // only after main returns; pending originals remain retained.
                    self.reconfigureTap()
                }
                self.updateStatusIcon()
            }
        }
        rslog("Monitoring started successfully")

        if SettingsManager.shared.perAppLayout {
            startPerAppLayout()
        }

        // Предлагаем автозагрузку и автозамену при первом запуске (по разу)
        offerLaunchAtLoginIfNeeded()
        offerAutoConvertIfNeeded()
    }

    /// One native handler owns switching and correction. The first tap is already visible;
    /// the second edits using the original source and selects the result's exact layout.
    private func handleCombinedShift(_ request: CombinedShiftRequest) {
        let isDouble: Bool
        if case .convert = request.action { isDouble = true; RuntimeDiagnostics.record(.doubleReceived) }
        else { isDouble = false; RuntimeDiagnostics.record(.soloReceived) }
        guard SettingsManager.shared.combinedShiftEnabled, SettingsManager.shared.autoSwitchEnabled else {
            if isDouble { RuntimeDiagnostics.record(.doubleDisabled) }; return
        }
        guard !AutoSwitchPolicy.secureInputActive else {
            if isDouble { RuntimeDiagnostics.record(.doubleSecureInput) }
            keyboardMonitor.resetCombinedShift()
            notifySecureInputPaused()
            return
        }
        guard let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              request.frontProcessID > 0, request.frontProcessID == currentPID else {
            if isDouble { RuntimeDiagnostics.record(.doubleWrongProcess) }
            keyboardMonitor.resetCombinedShift()
            return
        }
        let context: CombinedShiftContext
        switch request.action {
        case .switchLayout(let direction):
            if LayoutSwitcher.currentLayoutID() != direction.targetLayoutID {
                LayoutSwitcher.switchTo(layoutID: direction.targetLayoutID)
            }
            updateStatusIcon()
            return  // preserve typed buffers and undo; this may still be the first half of a double
        case .convert(let direction):
            guard request.inputRevision == keyboardMonitor.inputRevision else {
                RuntimeDiagnostics.record(.doubleRevisionChanged); return
            }
            context = direction
        }
        // The controlled instance receives the real Shift gestures. Local source was already
        // selected on tap one; another generic toggle here would race that instance.
        guard !AutoSwitchPolicy.shouldDeferToRemoteClient else { RuntimeDiagnostics.record(.doubleRemoteDeferred); return }
        guard let focus = request.focus, focus.processID == request.frontProcessID else {
            RuntimeDiagnostics.record(.doubleMissingFocus); return
        }
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: request.inputRevision,
            currentInputRevision: { [weak self] in self?.keyboardMonitor.inputRevision ?? UInt64.max })
        guard execution.isValid() else { RuntimeDiagnostics.record(.doubleInvalidExecution); return }

        handleVerifiedCombinedShift(request, context: context, execution: execution)
    }

    private func handleVerifiedCombinedShift(_ request: CombinedShiftRequest,
        context: CombinedShiftContext, execution: CombinedShiftExecutionContext) {
        guard let lease = keyboardMonitor.beginNativeInputTransaction(processID: execution.focus.processID) else {
            RuntimeDiagnostics.record(.nativeFenceUnavailable)
            RuntimeDiagnostics.record(.doubleFailed)
            if let target = keyboardMonitor.pendingInputSourceTargetID {
                DispatchQueue.main.async { [weak self] in self?.presentSourceFailure(targetID: target) }
            }
            return
        }
        let isCurrent = { [weak self] in
            guard let self else { return false }
            return self.keyboardMonitor.nativeInputTransactionIsCurrent(lease)
                && self.keyboardMonitor.inputRevision == execution.inputRevision
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == execution.focus.processID
                && !AutoSwitchPolicy.secureInputActive
        }
        var requestedAt: UInt64 = 0
        let sourceCommit = NativeQueuedSourceCommit(isCurrent: isCurrent, request: { target in
            requestedAt = DispatchTime.now().uptimeNanoseconds
            return LayoutSwitcher.switchToWithConfirmation(layoutID: target)
        }, onUnconfirmed: { [weak self] target in
            self?.keyboardMonitor.noteUnconfirmedInputSource(target, requestedAt: requestedAt)
        })
        var failureNotice: CombinedShiftFailure?
        defer {
            keyboardMonitor.finishNativeInputTransaction(lease, replayLayoutID: sourceCommit.confirmedLayoutID)
            if let failureNotice {
                // Present only after releasing the input fence. This existing
                // nonactivating panel does not take focus from the editor.
                DispatchQueue.main.async { [weak self] in
                    guard let message = failureNotice.userMessage else { return }
                    self?.secureNotice.show(title: "MacSwitcher", body: message)
                }
            }
        }
        let succeeded = textConverter.withNativeInputBudget({ [weak self] in
            self?.keyboardMonitor.nativeInputTransactionRemainingDuration(lease)
        }) {
            textConverter.withNativeTextQueuedHandler({ _ in
                // The queued Unicode is not editor acknowledgement. Completion
                // selects the result source after exact text ACK, under this lease.
            }) {
                CombinedShiftEditing.perform(request: request, context: context, execution: execution,
                    converter: textConverter, inputBarrierIsActive: isCurrent,
                    convertWholeLine: SettingsManager.shared.convertWholeLine,
                    contextForSource: { LayoutSwitcher.combinedShiftContext(sourceLayoutID: $0) },
                    onFailure: { failureNotice = $0 },
                    onDiagnostic: { RuntimeDiagnostics.record($0) },
                    application: CombinedShiftApplicationFamily.classify(
                        bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
            }
        }
        finishCombinedShift(succeeded: succeeded, request: request, context: context,
            sourceCommit: sourceCommit, isInputCurrent: isCurrent)
    }

    private func finishCombinedShift(succeeded: Bool, request: CombinedShiftRequest,
        context: CombinedShiftContext, sourceCommit: NativeQueuedSourceCommit,
        isInputCurrent: () -> Bool) {
        switch CombinedShiftCompletion.finish(succeeded: succeeded, request: request,
            context: context, sourceCommit: sourceCommit, converter: textConverter,
            monitor: keyboardMonitor, isInputCurrent: isInputCurrent) {
        case .stopped:
            break
        case .sourceNotConfirmed(let targetID, _):
            // The current handler's defer releases the lease before this runs.
            DispatchQueue.main.async { [weak self] in self?.presentSourceFailure(targetID: targetID) }
        case .confirmed:
            updateStatusIcon()
            // A modal question must never keep the native input lease open.
            if request.reconvert { DispatchQueue.main.async { [weak self] in self?.offerExceptionAfterUndo() } }
            else { lastAutoConverted = nil }
        }
    }

    private func resetCombinedShiftAfterPause() {
        predictionCoordinator.invalidate()
        keyboardMonitor.resetPredictionContext()
        guard SettingsManager.shared.combinedShiftEnabled else { return }
        keyboardMonitor.resetCombinedShift()
        textConverter.clearState()
    }

    /// Предлагает включить автозагрузку при первом запуске (один раз)
    private func offerLaunchAtLoginIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.launchAtLoginAsked else { return }
        settings.launchAtLoginAsked = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardLaunchAtLoginTitle
        alert.informativeText = L10n.wizardLaunchAtLoginText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            settings.launchAtLogin = true
            rslog("User enabled launch at login")
        } else {
            rslog("User declined launch at login")
        }
    }

    /// Предлагает включить автозамену при первом запуске (один раз). Фича OFF по умолчанию,
    /// поэтому без явного предложения пользователь о ней не узнает.
    private func offerAutoConvertIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.autoConvertOffered else { return }
        settings.autoConvertOffered = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.onboardAutoConvertTitle
        alert.informativeText = L10n.onboardAutoConvertText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        if alert.runModal() == .alertFirstButtonReturn {
            settings.autoConvert = true
            rebuildMenu()  // синхронизировать галочку «Автоматическая конверсия» в меню
            rslog("User enabled auto-convert at onboarding")
        } else {
            settings.autoConvert = false
            predictionCoordinator.invalidate()
            keyboardMonitor.resetPredictionContext()
            rebuildMenu()
            rslog("User declined auto-convert at onboarding")
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Иконку можно полностью скрыть (Настройки → Расширенные). isVisible вместо
        // removeStatusItem: система помнит позицию, а объект живёт — все пути обновления
        // (updateStatusIcon/rebuildMenu) продолжают работать без nil-проверок.
        statusItem.isVisible = !SettingsManager.shared.hideMenuBarIcon
        rebuildMenu()
        // issue #9: иконка должна отражать раскладку и при СИСТЕМНОЙ смене (стандартный/
        // переопределённый хоткей), а не только при нашей конверсии. Слушаем системное
        // распределённое уведомление о смене источника ввода.
        // suspensionBehavior: .deliverImmediately — иначе для фонового menu-bar-приложения
        // распределённое уведомление коалесцируется/откладывается (App Nap / suspend), и
        // иконка после переключения глобусом 🌐 меняется с задержкой до нескольких секунд
        // (ждёт пробуждения или 2-секундного опроса). deliverImmediately обновляет флаг сразу.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemInputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func systemInputSourceChanged() {
        keyboardMonitor.recordObservedInputSource(LayoutSwitcher.currentLayoutID())
        updateStatusIcon()
        keyboardMonitor.soundArmed = true  // issue #7: следующая буква даст звук раскладки
        keyboardMonitor.resetLineBuffer(sourceLayoutID: LayoutSwitcher.currentLayoutID())
    }

    /// Собирает меню статус-бара. Вызывается заново при смене языка интерфейса,
    /// иначе пункты меню остаются на старом языке.
    private func rebuildMenu() {
        let menu = NSMenu()

        // Строка версии (с dev-меткой для непубликуемых сборок) — чтобы было видно, какой билд.
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let devTag = Bundle.main.infoDictionary?["RSDevTag"] as? String ?? ""
        let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "MacSwitcher"
        let verItem = NSMenuItem(title: "\(displayName) \(ver)\(devTag)", action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        menu.addItem(verItem)
        menu.addItem(NSMenuItem.separator())

        // Список раскладок как в системном меню ввода: флаг + имя, галочка на текущей,
        // клик — переключение. Актуализируется в menuWillOpen при каждом открытии.
        for item in layoutMenuItems() { menu.addItem(item) }
        let sourceRecovery = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sourceRecovery.tag = Self.sourceRecoveryItemTag
        sourceRecovery.isEnabled = false
        menu.addItem(sourceRecovery)
        refreshSourceRecoveryMenu(sourceRecovery)
        menu.addItem(NSMenuItem.separator())

        let autoItem = NSMenuItem(title: L10n.menuAutoSwitch, action: #selector(toggleAutoSwitch), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = SettingsManager.shared.autoSwitchEnabled ? .on : .off
        menu.addItem(autoItem)

        let autoConvertItem = NSMenuItem(title: L10n.menuAutoConvert, action: #selector(toggleAutoConvert), keyEquivalent: "")
        autoConvertItem.target = self
        autoConvertItem.state = SettingsManager.shared.autoConvert ? .on : .off
        menu.addItem(autoConvertItem)

        let recovery = NSMenuItem(title: L10n.languageCode == "ru"
            ? "Исходные тексты после сбоя"
            : "Original texts after unconfirmed edits", action: nil, keyEquivalent: "")
        recovery.target = self
        recovery.tag = Self.recoveryCopyItemTag
        recovery.isEnabled = textConverter.hasUnconfirmedAXEdit
        menu.addItem(recovery)
        refreshRecoveryMenu(recovery)

        let keySoundItem = NSMenuItem(title: L10n.menuKeySound, action: #selector(toggleKeySound), keyEquivalent: "")
        keySoundItem.target = self
        keySoundItem.state = SettingsManager.shared.keySound ? .on : .off
        menu.addItem(keySoundItem)

        let caretFlagItem = NSMenuItem(title: L10n.menuCaretFlag, action: #selector(toggleCaretFlag), keyEquivalent: "")
        caretFlagItem.target = self
        caretFlagItem.state = SettingsManager.shared.caretFlag ? .on : .off
        menu.addItem(caretFlagItem)

        // Единый стиль меню-бара (Sequoia): монохромная плашка вместо цветного флага.
        let monoIconItem = NSMenuItem(title: L10n.menuMonoIcon, action: #selector(toggleMonoIcon), keyEquivalent: "")
        monoIconItem.target = self
        monoIconItem.state = SettingsManager.shared.monochromeIcon ? .on : .off
        menu.addItem(monoIconItem)

        // Режим удалённого стола отложен в 2.5 — тумблер скрыт за флагом (для тестирования).
        if SettingsManager.shared.showRemoteDesktopBeta {
            let remoteDesktopItem = NSMenuItem(title: L10n.menuRemoteDesktop, action: #selector(toggleRemoteDesktop), keyEquivalent: "")
            remoteDesktopItem.target = self
            remoteDesktopItem.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
            menu.addItem(remoteDesktopItem)
        }

        menu.addItem(NSMenuItem.separator())

        let permItem = NSMenuItem(title: L10n.menuCheckPermissions, action: #selector(recheckPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        let settingsItem = NSMenuItem(title: L10n.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: L10n.menuCheckUpdates, action: #selector(checkUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        rslog("Menu (re)built with \(menu.items.count) items")
    }

    // MARK: - Layout list in menu

    /// Метка пунктов-раскладок, чтобы находить и обновлять их группу в меню.
    private static let layoutItemTag = 741

    /// Пункты списка раскладок: «флаг + локализованное имя», галочка на текущей.
    private func layoutMenuItems() -> [NSMenuItem] {
        let currentID = LayoutSwitcher.currentLayoutID()
        return LayoutSwitcher.installedLayouts().map { source in
            let id = LayoutSwitcher.sourceID(source)
            let badge = LayoutSwitcher.languageCode(source).map(Self.flagBadge(forLanguage:))
            let title = [badge, LayoutSwitcher.sourceName(source)].compactMap { $0 }.joined(separator: " ")
            let item = NSMenuItem(title: title, action: #selector(selectLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (id == currentID) ? .on : .off
            item.tag = Self.layoutItemTag
            return item
        }
    }

    /// Пересобирает группу раскладок при каждом открытии меню: состав и галочка должны
    /// отражать систему на момент клика (раскладки добавляют/удаляют в настройках ОС,
    /// а текущую меняют и мимо нас — системным хоткеем).
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        if let recovery = menu.item(withTag: Self.recoveryCopyItemTag) { refreshRecoveryMenu(recovery) }
        if let recovery = menu.item(withTag: Self.sourceRecoveryItemTag) { refreshSourceRecoveryMenu(recovery) }
        let insertAt = menu.items.firstIndex { $0.tag == Self.layoutItemTag } ?? 2
        for old in menu.items where old.tag == Self.layoutItemTag { menu.removeItem(old) }
        for (offset, item) in layoutMenuItems().enumerated() {
            menu.insertItem(item, at: insertAt + offset)
        }
    }

    private func refreshSourceRecoveryMenu(_ item: NSMenuItem) {
        guard let target = keyboardMonitor.pendingInputSourceTargetID else {
            item.isHidden = true
            return
        }
        item.isHidden = false
        let name = LayoutSwitcher.installedLayouts().first(where: {
            LayoutSwitcher.sourceID($0) == target
        }).map(LayoutSwitcher.sourceName) ?? target
        item.title = L10n.languageCode == "ru"
            ? "Текст исправлен · подтвердите раскладку \(name)"
            : "Text changed · confirm the \(name) input source"
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if keyboardMonitor.hasPendingInputSourceTransition {
            if id != LayoutSwitcher.currentLayoutID() {
                _ = LayoutSwitcher.switchToWithConfirmation(layoutID: id)
            }
            // A verified user choice is a source observation, not another text
            // edit. Preserve the confirmed replacement and its undo history.
            keyboardMonitor.recordObservedInputSource(LayoutSwitcher.currentLayoutID())
            updateStatusIcon()
            return
        }
        guard id != LayoutSwitcher.currentLayoutID() else { return }
        LayoutSwitcher.switchTo(layoutID: id)
        // Явная смена раскладки делает набранный буфер неактуальным — как при per-app restore.
        keyboardMonitor.markConverted()
        textConverter.clearState()
        updateStatusIcon()
    }

    func updateStatusIcon() {
        let flag = flagForCurrentLayout()
        // Каретку дёргаем ТОЛЬКО при реальной смене раскладки: updateStatusIcon зовётся ещё и
        // 2-секундным опросом-страховкой, иначе флаг у каретки выскакивал бы каждые 2с.
        // Сравниваем по флагу-идентичности, а не по title — в монохромном режиме title пуст.
        let changed = lastFlagShown != flag
        lastFlagShown = flag
        if SettingsManager.shared.monochromeIcon {
            statusItem.button?.title = ""
            statusItem.button?.image = badgeImage(for: currentBadgeLabel())
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = flag
        }
        if changed { caretIndicator?.layoutChanged() }
    }

    /// Подпись монохромной плашки — родная аббревиатура языка, как у системного индикатора.
    private func currentBadgeLabel() -> String {
        if let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty {
            // 'iw' — устаревший код иврита: нормализуем, как и flagBadge.
            let code = LayoutDetector.isHebrew(lang) ? "he" : String(lang.prefix(2))
            let labels: [String: String] = [
                "ru": "РУ", "en": "EN", "uk": "УК", "be": "БЕ",
                "de": "DE", "fr": "FR", "es": "ES", "it": "IT",
                "pt": "PT", "pl": "PL", "ja": "あ", "zh": "拼", "ko": "한",
                "he": "עב",   // иврит (3.0)
                "el": "ΕΛ", "bg": "БГ", "hy": "ՀԱ", "ka": "ქა",
            ]
            return labels[code] ?? code.uppercased()
        }
        // Язык раскладки недоступен — мягкий фолбэк по ID (как у flagForCurrentLayout).
        let id = LayoutSwitcher.currentLayoutID().lowercased()
        return (id.contains("russian") || id.hasSuffix(".ru")) ? "РУ" : "EN"
    }

    /// Монохромная плашка в стиле системного индикатора раскладки Sequoia: скруглённый
    /// прямоугольник с «выбитыми» буквами. Template-image — система сама красит её под
    /// светлый/тёмный меню-бар и пользовательский тинт.
    private func badgeImage(for label: String) -> NSImage {
        if let cached = badgeCache[label] { return cached }
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let textSize = label.size(withAttributes: [.font: font])
        let size = NSSize(width: max(ceil(textSize.width) + 8, 20), height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            // Буквы «выбиваются» из плашки (прозрачные), как у системного индикатора.
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                   y: (rect.height - textSize.height) / 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.white])
            return true
        }
        image.isTemplate = true
        badgeCache[label] = image
        return image
    }

    /// Флаг текущей раскладки по коду языка (BCP-47), а не по подстроке в ID — иначе
    /// "Belarusian" ложно матчил "ru", а любая не-RU/EN пара показывалась как 🇺🇸.
    func flagForCurrentLayout() -> String {
        guard let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty else {
            // Язык раскладки недоступен — мягкий фолбэк по ID.
            let id = LayoutSwitcher.currentLayoutID().lowercased()
            return (id.contains("russian") || id.hasSuffix(".ru")) ? "🇷🇺" : "🇺🇸"
        }
        return Self.flagBadge(forLanguage: lang)
    }

    /// Единый бейдж раскладки для иконки меню-бара и списка раскладок в меню:
    /// «🇷🇺» для известных языков, иначе код («EL»).
    private static func flagBadge(forLanguage lang: String) -> String {
        // Иврит может прийти устаревшим кодом 'iw' — движок его понимает (isHebrew),
        // индикация должна тоже, иначе в баре будет «IW» вместо 🇮🇱.
        let code = LayoutDetector.isHebrew(lang) ? "he" : String(lang.lowercased().prefix(2))
        let flags: [String: String] = [
            "ru": "🇷🇺", "en": "🇺🇸", "uk": "🇺🇦", "be": "🇧🇾",
            "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸", "it": "🇮🇹",
            "pt": "🇵🇹", "pl": "🇵🇱", "ja": "🇯🇵", "zh": "🇨🇳", "ko": "🇰🇷",
            "he": "🇮🇱",   // иврит (3.0). Арабский в 3.1 — глифом ع (флага нет), см. дизайн 3.0.
        ]
        return flags[code] ?? code.uppercased()
    }

    /// issue #10: создаёт/освобождает индикатор каретки по флагу настроек. Создаётся лениво,
    /// только когда фича включена И мониторинг запущен (нужны разрешения).
    private func syncCaretIndicator() {
        keyboardMonitor.caretFlagEnabled = SettingsManager.shared.caretFlag   // гейт диспатча onUserInput
        if SettingsManager.shared.caretFlag, monitoringActive {
            if caretIndicator == nil {
                let ci = CaretIndicator()
                ci.flagProvider = { [weak self] in self?.flagForCurrentLayout() ?? "" }
                caretIndicator = ci
            }
        } else {
            caretIndicator?.teardown()
            caretIndicator = nil
        }
    }

    // MARK: - Actions

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        SettingsManager.shared.autoSwitchEnabled.toggle()
        resetCombinedShiftAfterPause()
        let enabled = SettingsManager.shared.autoSwitchEnabled
        sender.state = enabled ? .on : .off
        settingsController.updateAutoSwitchState(enabled)
    }

    @objc private func toggleAutoConvert(_ sender: NSMenuItem) {
        SettingsManager.shared.autoConvert.toggle()
        predictionCoordinator.invalidate()
        keyboardMonitor.resetPredictionContext()
        reconfigureTap()
        sender.state = SettingsManager.shared.autoConvert ? .on : .off
        settingsController.updateAutoConvertState(SettingsManager.shared.autoConvert)   // #4
    }

    private func refreshRecoveryMenu(_ parent: NSMenuItem) {
        parent.isEnabled = textConverter.hasUnconfirmedAXEdit
        let submenu = NSMenu()
        for (index, original) in textConverter.unconfirmedOriginals.enumerated() {
            let title = L10n.languageCode == "ru" ? "Скопировать исходник \(index + 1)" : "Copy original \(index + 1)"
            let item = NSMenuItem(title: title, action: #selector(copyRecoveryOriginal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = original
            submenu.addItem(item)
        }
        parent.submenu = submenu
    }

    @objc private func copyRecoveryOriginal(_ sender: NSMenuItem) {
        guard let original = sender.representedObject as? TextConverter.RecoveryOriginal else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original.text, forType: .string)
    }

    @objc private func toggleKeySound(_ sender: NSMenuItem) {
        SettingsManager.shared.keySound.toggle()
        sender.state = SettingsManager.shared.keySound ? .on : .off
    }

    @objc private func toggleCaretFlag(_ sender: NSMenuItem) {
        SettingsManager.shared.caretFlag.toggle()
        sender.state = SettingsManager.shared.caretFlag ? .on : .off
        settingsController.updateCaretFlagState(SettingsManager.shared.caretFlag)
        syncCaretIndicator()   // создать/снести индикатор и обновить гейт onUserInput
    }

    @objc private func toggleMonoIcon(_ sender: NSMenuItem) {
        SettingsManager.shared.monochromeIcon.toggle()
        sender.state = SettingsManager.shared.monochromeIcon ? .on : .off
        updateStatusIcon()   // перерисовать в новом стиле сразу
    }

    @objc private func toggleRemoteDesktop(_ sender: NSMenuItem) {
        SettingsManager.shared.remoteDesktopMode.toggle()
        sender.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
        settingsController.updateRemoteDesktopState(SettingsManager.shared.remoteDesktopMode)   // #5
        reconfigureTap()  // уровень event tap зависит от режима
    }

    /// Пересоздаёт event tap и, если создание не удалось (например, session-tap отклонён),
    /// ретраит — иначе тумблер «вкл», а tap'а нет, и приложение молча не реагирует на триггер.
    private func reconfigureTap() {
        guard !keyboardMonitor.reconfigure() else { return }
        rslog("reconfigure failed (tap denied) — retry in 3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.keyboardMonitor.reconfigure() == false { rslog("reconfigure retry failed") }
        }
    }

    @objc private func recheckPermissions() {
        runPermissionWizard(interactive: true)
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func checkUpdates() {
        UpdateChecker.checkNow()
    }

    /// Окно «Что нового» — один раз после обновления, на языке приложения.
    /// НЕ показываем на свежей установке (там визард первого запуска): отличаем по
    /// launchAtLoginAsked — он выставляется на первом запуске, значит приложение уже
    /// работало ⇒ пустой lastWhatsNewVersion при hasRunBefore = обновление со старой версии.
    private func showWhatsNewIfNeeded(hasRunBefore: Bool) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard !current.isEmpty else { return }
        // Бета-версии (с буквой, напр. «3.2.0a») имеют ОТДЕЛЬНУЮ витрину
        // (showBetaWhatsNewIfNeeded) с текстом из бета-фида; локализованный whatsnew.body
        // под беты не обновляется (иначе тестер увидел бы устаревший текст).
        guard current.last?.isLetter != true else { return }
        let settings = SettingsManager.shared
        // Показываем только на РЕАЛЬНОМ повышении версии: current строго новее сохранённой
        // (numeric-сравнение, не строковое) — иначе даунгрейд 3.2→3.1 снова показал бы окно.
        guard current.compare(settings.lastWhatsNewVersion, options: .numeric) == .orderedDescending else { return }
        guard hasRunBefore else {                          // свежая установка: не показываем,
            settings.lastWhatsNewVersion = current         // но фиксируем версию (и на 2-м запуске молчим)
            return
        }
        // После обновления macOS мог сбросить права — идёт визард, мониторинг ещё не поднят.
        // Не наваливаем промо поверх запроса прав: откладываем до следующего запуска,
        // версию НЕ фиксируем (покажем, когда права выданы и мониторинг активен).
        guard monitoringActive else { return }
        settings.lastWhatsNewVersion = current             // фиксируем только когда реально показываем

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(L10n.whatsNewTitle) \(current)"
        alert.informativeText = L10n.whatsNewBody
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L10n.whatsNewMore)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "\(SettingsManager.githubURL)/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Отдельная витрина для БЕТ: текст изменений берётся из notes бета-фида
    /// (version-beta.json), а не из локализованного whatsnew.body — так его можно менять под
    /// каждую бету без пересборки и ×16-локализации. Только для подписчиков беты, один раз на
    /// версию. Текст двуязычный (RU+EN) — аудитория беты небольшая и приглашённая.
    private func showBetaWhatsNewIfNeeded() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard current.last?.isLetter == true else { return }         // только беты
        guard SettingsManager.shared.betaChannelEnabled else { return }  // только подписчики беты
        guard SettingsManager.shared.lastBetaNotesShown != current else { return }
        guard monitoringActive else { return }                        // не поверх запроса прав
        Task { @MainActor in
            guard let notes = await UpdateChecker.fetchBetaNotes(), !notes.isEmpty else { return }
            // перепроверяем после await (мог показаться параллельно / версия изменилась)
            guard SettingsManager.shared.lastBetaNotesShown != current else { return }
            SettingsManager.shared.lastBetaNotesShown = current
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "\(L10n.whatsNewTitle) \(current) \(L10n.updateBeta)"
            alert.informativeText = notes
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: L10n.whatsNewMore)
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "\(SettingsManager.githubURL)/releases") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        predictionCoordinator.invalidate()
        perAppLayoutManager.stop()
        keyboardMonitor.stop()
        // Не теряем буфер обмена в 2-секундном окне отложенного восстановления
        // (актуально и при само-обновлении, которое завершает процесс).
        textConverter.flushPendingClipboardRestore()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard textConverter.hasUnconfirmedAXEdit else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.languageCode == "ru" ? "Сначала сохраните исходный текст" : "Save the original text first"
        alert.informativeText = L10n.languageCode == "ru"
            ? "После неподтверждённой замены полные исходные тексты остались в памяти MacSwitcher. Перед выходом их можно сохранить в локальный файл в Library/Application Support/MacSwitcher/Recovery. Обычное копирование в буфер не считается сохранением."
            : "Full originals from unconfirmed edits remain in MacSwitcher memory. Before quitting, save them to a local file in Library/Application Support/MacSwitcher/Recovery. Clipboard copying is not a saved backup."
        alert.addButton(withTitle: L10n.languageCode == "ru" ? "Сохранить локально и выйти" : "Save locally and quit")
        alert.addButton(withTitle: L10n.languageCode == "ru" ? "Отмена" : "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("MacSwitcher/Recovery", isDirectory: true)
            let originals = textConverter.unconfirmedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
            _ = try RecoveryArchive.save(originals, in: directory)
            return .terminateNow
        } catch {
            let failure = NSAlert()
            failure.messageText = L10n.languageCode == "ru" ? "Исходники не сохранены. Выход отменён." : "Originals were not saved. Quit cancelled."
            failure.runModal()
            return .terminateCancel
        }
    }

    @objc private func quit() {
        textConverter.flushPendingClipboardRestore()
        NSApplication.shared.terminate(nil)
    }
}
