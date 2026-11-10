import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let keyboardMonitor = KeyboardMonitor()
    private let textConverter = TextConverter()
    private let shellAuthorizationGate = ShellAuthorizationGate()
    private lazy var shellCoordinator = ManualShellCoordinator(gate: shellAuthorizationGate)
    private lazy var recoveryArchiveController = RecoveryArchiveController(
        converter: textConverter,
        enabled: { SettingsManager.shared.automaticRecoveryArchiveEnabled },
        directory: {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("MacSwitcher/Recovery", isDirectory: true)
        })
    private lazy var predictionCoordinator = PredictionCoordinator(monitor: keyboardMonitor, converter: textConverter)
    private let settingsController = SettingsWindowController()
    private let perAppLayoutManager = PerAppLayoutManager()
    private let electronAccessibilityBridge = ElectronAccessibilityBridge()
    private var permissionCheckTimer: Timer?
    private var iconRefreshTimer: Timer?
    private var monitoringActive = false
    private var systemSleeping = false
    private var runtimeSleepObserver: NSObjectProtocol?
    private var runtimeWakeObserver: NSObjectProtocol?
    private lazy var runtimeHealth = RuntimeHealthController(observe: { [weak self] in
        guard let self else { return RuntimeHealthSnapshot(monitoring: false,
            masterEnabled: false, accessibilityGranted: false, inputMonitoringGranted: false,
            secureInput: false, sleeping: false,
            tap: NativeTapRecoveryStatus(tapPresent: false, tapEnabled: false,
                fenceAvailable: false), nativeLeaseActive: false,
            shellEditActive: false, unknownEditRetained: false, shell: .disabled) }
        return self.runtimeHealthSnapshot()
    }, invalidateContext: { [weak self] in
        guard let self else { return }
        _ = self.nativeSelectionAwaitGate.nextAction()
        self.pendingNativeSelection?.cancel()
        self.pendingNativeSelection = nil
        self.predictionCoordinator.invalidate()
        self.keyboardMonitor.invalidateRuntimeInputContext()
        self.shellCoordinator.invalidatePendingForRuntimeTransition()
    }, rearmTap: { [weak self] in
        self?.tapRecovery.request(allowNewEpisode: true)
    }, pollTap: { [weak self] needsRecovery in
        self?.tapRecovery.poll(needsRecovery: needsRecovery)
    }, maintainShell: { [weak self] in
        self?.shellCoordinator.maintainHealth()
    })
    private lazy var tapRecovery = MonitoringTapRecovery(isActive: { [weak self] in
        self?.monitoringActive == true
    }, mayReconfigure: { [weak self] in
        self?.mayReconfigureRuntimeTap() == true
    }, reconfigure: { [weak self] in
        self?.keyboardMonitor.reconfigure() == true
    }, schedule: { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
    })
    private var caretIndicator: CaretIndicator?   // issue #10: флаг у каретки (бета, по умолчанию OFF)
    private let secureNotice = SecureInputNotice()  // issue #27: подсказка о защ. вводе без кражи фокуса
    private let correctionExceptionOffer = CorrectionExceptionOffer()
    private var lastFlagShown: String?            // идентичность раскладки для детекта смены (не title!)
    private var badgeCache: [String: NSImage] = [:]  // монохромные плашки, чтобы не перерисовывать 2с-опросом
    private var diagnosticRepro: DiagnosticReproController?
    private var nativeSelectionAwaitGate = NativeSelectionAwaitGate()
    private var pendingNativeSelection: Task<Void, Never>?
    private let adaptiveQueue = DispatchQueue(label: "com.macswitcher.adaptive-rules", qos: .utility)
    private var manualLearningProvenance = AdaptiveManualProvenance()
    private var automaticUndoLearningProvenance = AdaptiveAutomaticUndoProvenance()
    private var lastRecoveryCapacityNoticeAt: Date?
    private static let recoveryCopyItemTag = 71003
    private static let sourceRecoveryItemTag = 71004

    func applicationDidFinishLaunching(_ notification: Notification) {
        textConverter.onUnconfirmedSourceRetained = { [weak self] in
            self?.recoveryArchiveController.scheduleAutomaticAfterCurrentEvent()
        }
        recoveryArchiveController.onSaved = { [weak self] in
            guard let self, let recovery = self.statusItem.menu?.item(withTag: Self.recoveryCopyItemTag) else { return }
            self.refreshRecoveryMenu(recovery)
        }
        recoveryArchiveController.onFailure = { [weak self] manual, reason in
            self?.showRecoveryArchiveFailure(manual: manual, reason: reason)
        }
        shellCoordinator.onUnknown = { [weak self] in
            guard let self else { return }
            if let menu = self.statusItem?.menu?.item(withTag: Self.recoveryCopyItemTag) {
                self.refreshRecoveryMenu(menu)
            }
            if self.shellCoordinator.hasUnbackedUnknown {
                self.showUnknownEditNotice()
                if SettingsManager.shared.automaticRecoveryArchiveEnabled {
                    if let directory = try? self.recoveryDirectory() {
                        self.shellCoordinator.scheduleAutomaticArchive(in: directory) { [weak self] in
                            self?.showFeedback(title: "MacSwitcher",
                                body: L10n.languageCode == "ru"
                                    ? "Исходная строка терминала осталась в памяти; локальное сохранение не удалось."
                                    : "The original terminal line remains in memory; local saving failed.",
                                kind: .saveFailure)
                        }
                    }
                }
            }
        }
        shellCoordinator.onConfirmed = { [weak self] resultLayoutID in
            guard let self else { return }
            let outcome = LayoutSwitcher.switchToWithConfirmation(layoutID: resultLayoutID)
            self.keyboardMonitor.markConverted()
            if outcome != .confirmed {
                self.keyboardMonitor.requireObservedInputSource(resultLayoutID)
                self.presentSourceFailure(targetID: resultLayoutID)
            }
            self.updateStatusIcon()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(observedApplicationTermination(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        runtimeSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.runtimeWillSleep() }
            }
        runtimeWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.runtimeDidWake() }
            }
        textConverter.onRecoveryCapacityBlocked = { [weak self] reason in
            DispatchQueue.main.async { self?.showRecoveryCapacityNotice(reason) }
        }
        let introShown = UserDefaults.standard.bool(forKey: "com.macswitcher.adaptiveLearningIntroShown")
        AdaptiveRuleStore.shared.setEnabled(AdaptiveIntroPolicy.mayReadOrRecord(
            preferenceEnabled: SettingsManager.shared.adaptiveLearningEnabled,
            explanationShown: introShown))
        setupStatusItem()
        setupSettingsCallbacks()
        configureShellBridge()
        syncLoginItem()
        // «Запускались раньше?» снимаем ДО визарда: он через startMonitoring →
        // offerLaunchAtLoginIfNeeded выставляет launchAtLoginAsked уже на этом же
        // первом запуске, иначе «Что нового» ложно показалось бы на свежей установке.
        let ranBefore = SettingsManager.shared.launchAtLoginAsked
        runPermissionWizard()
        showWhatsNewIfNeeded(hasRunBefore: ranBefore)
        showBetaWhatsNewIfNeeded()   // отдельная витрина для бет (текст из бета-фида)
        showAdaptiveIntroIfNeeded()
        UpdateChecker.checkOnLaunch()
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
        settingsController.onRecoveryArchiveChanged = { [weak self] enabled in
            self?.recoveryArchiveController.settingChanged(enabled)
        }
        settingsController.onAutoSwitchChanged = { [weak self] _ in
            self?.resetCombinedShiftAfterPause()
            self?.syncElectronAccessibilityBridge()
            self?.configureShellBridge()
            // Не адресуем пункт по индексу: меню группирует пункты по назначению,
            // а recovery и раскладки появляются динамически. Пересборка — как у соседних колбэков.
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
            self?.configureShellBridge()
        }
        settingsController.onShellBridgeSetupRequested = { [weak self] in
            self?.showShellBridgeSetup()
        }
        settingsController.onRuntimeCheckRequested = { [weak self] in
            self?.showRuntimeCheck()
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

    private func configureShellBridge() {
        shellCoordinator.configure(enabled: SettingsManager.shared.shellBridgeEnabled
            && SettingsManager.shared.combinedShiftEnabled
            && SettingsManager.shared.autoSwitchEnabled)
        if shellCoordinator.isRequested {
            let gate = shellAuthorizationGate
            keyboardMonitor.onInputRevisionAdvanced = { _ = gate.next() }
        } else {
            keyboardMonitor.onInputRevisionAdvanced = nil
        }
    }

    /// Explicit setup only. Showing this preview does not change the profile.
    private func showShellBridgeSetup() {
        guard let resource = ShellBridgeProfilePatch.packagedResourceURL else {
            showShellBridgeSetupResult(success: false, detail: L10n.languageCode == "ru"
                ? "Ресурс подключения отсутствует в приложении."
                : "The packaged shell resource is missing.")
            return
        }
        let profile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        do {
            let existing = FileManager.default.fileExists(atPath: profile.path)
                ? try Data(contentsOf: profile) : nil
            let current = try ShellBridgeProfilePatch.preview(profileData: existing,
                resourcePath: resource.path)
            let uninstall = current.action == .alreadyInstalled
            let plan = try ShellBridgeProfilePatch.preview(profileData: existing,
                resourcePath: resource.path, uninstall: uninstall)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.languageCode == "ru"
                ? (uninstall ? "Подключение zsh установлено" : "Подключить zsh к MacSwitcher?")
                : (uninstall ? "zsh integration is installed" : "Connect zsh to MacSwitcher?")
            alert.informativeText = (L10n.languageCode == "ru"
                ? "При установке или удалении меняется только одна строка ~/.zshrc. Перед записью сохранится точная приватная копия (0600). После изменения откройте новое окно терминала. Доступ к вкладке запрашивается отдельно.\n\n"
                : "Installing or removing changes exactly one line in ~/.zshrc. A byte-exact private backup (0600) is saved first. Open a new terminal window afterward. Tab access is requested separately.\n\n")
                + plan.sourceLine
            if uninstall {
                alert.addButton(withTitle: L10n.languageCode == "ru" ? "Запросить доступ к вкладке" : "Request tab access")
                alert.addButton(withTitle: L10n.languageCode == "ru" ? "Удалить строку" : "Remove line")
                alert.addButton(withTitle: L10n.languageCode == "ru" ? "Отмена" : "Cancel")
                let choice = alert.runModal()
                if choice == .alertFirstButtonReturn { showShellBridgeConsent(); return }
                guard choice == .alertSecondButtonReturn else { return }
            } else {
                alert.addButton(withTitle: L10n.languageCode == "ru" ? "Установить строку" : "Install line")
                alert.addButton(withTitle: L10n.languageCode == "ru" ? "Отмена" : "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let (result, backup) = try ShellBridgeProfilePatch.apply(profile: profile,
                resourcePath: resource.path, uninstall: uninstall)
            showShellBridgeSetupResult(success: true, detail: L10n.languageCode == "ru"
                ? "\(result.action == .uninstall ? "Подключение удалено" : "Подключение установлено"). Откройте новое окно терминала. Резервная копия: \(backup?.path ?? "—")."
                : "\(result.action == .uninstall ? "Integration removed" : "Integration installed"). Open a new terminal window. Backup: \(backup?.path ?? "—").")
        } catch ShellBridgeProfilePatch.PatchError.conflict {
            showShellBridgeSetupResult(success: false, detail: L10n.languageCode == "ru"
                ? "Другой редактор изменил ~/.zshrc во время настройки. Текущий файл и приватные копии сохранены в ~/.macswitcher-profile-recovery. Проверьте их перед повтором."
                : "Another editor changed ~/.zshrc during setup. The current file and private copies are preserved in ~/.macswitcher-profile-recovery. Review them before retrying.")
        } catch {
            showShellBridgeSetupResult(success: false, detail: L10n.languageCode == "ru"
                ? "Настройка не завершена. Проверьте ~/.zshrc и приватные копии в ~/.macswitcher-profile-recovery перед повтором."
                : "Setup did not finish. Review ~/.zshrc and private copies in ~/.macswitcher-profile-recovery before retrying.")
        }
    }

    private func showShellBridgeSetupResult(success: Bool, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = success ? .informational : .warning
        alert.messageText = "MacSwitcher"
        alert.informativeText = detail
        alert.runModal()
    }

    /// The user clicks this separately after installing the source line.
    /// Capability discovery is local; the TCC consent request runs off main.
    private func showShellBridgeConsent() {
        let discovery = SelectedTTYCapabilityDiscovery()
        let hosts = NSWorkspace.shared.runningApplications.filter {
            discovery.capability(pid: $0.processIdentifier) != nil
        }
        guard hosts.count == 1, let host = hosts.first else {
            showShellBridgeSetupResult(success: false, detail: L10n.languageCode == "ru"
                ? "Откройте один совместимый терминал и повторите запрос доступа."
                : "Open one compatible terminal and request access again.")
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.languageCode == "ru" ? "Разрешить определять активную вкладку?" : "Allow active-tab lookup?"
        alert.informativeText = (host.localizedName ?? host.bundleIdentifier ?? "Terminal")
            + (L10n.languageCode == "ru"
                ? ": macOS может назвать разрешение «управлением приложением». MacSwitcher использует его только чтобы определить активную вкладку терминала. Команды не запускаются."
                : ": macOS may call this permission “control the app.” MacSwitcher uses it only to identify the active terminal tab. No commands are run.")
        alert.addButton(withTitle: L10n.languageCode == "ru" ? "Запросить доступ" : "Request access")
        alert.addButton(withTitle: L10n.languageCode == "ru" ? "Отмена" : "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pid = host.processIdentifier
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                NativeReadOnlyAppleEventExecutor.requestConsent(pid: pid)
            }.value
            self?.showShellBridgeSetupResult(success: result == noErr,
                detail: result == noErr
                    ? (L10n.languageCode == "ru" ? "Доступ к выбранной вкладке разрешён."
                        : "Selected-tab access is allowed.")
                    : (L10n.languageCode == "ru" ? "Доступ пока не получен; строка терминала не будет изменяться."
                        : "Access was not granted; the terminal line will remain untouched."))
        }
    }

    private func recoveryDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("MacSwitcher/Recovery", isDirectory: true)
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
        showFeedback(title: L10n.securePausedTitle,
                          body: String(format: L10n.securePausedBody, holder), kind: .secureInput)
    }

    /// Called after the edit lease finishes. Only a fresh TIS read may resolve
    /// the requested source; a queued request is not selection evidence.
    private func presentSourceFailure(targetID: String) {
        keyboardMonitor.recordObservedInputSource(LayoutSwitcher.currentLayoutID())
        let pending = keyboardMonitor.pendingInputSourceTargetID
        guard LayoutSwitcher.currentLayoutID() != targetID,
              pending == targetID else { return }
        showFeedback(title: "MacSwitcher",
            body: CorrectionFeedbackPolicy.sourceMessage(languageCode: L10n.languageCode),
            kind: .sourceFailure)
    }

    private func switchOppositeExplicitly() {
        let intended = LayoutSwitcher.combinedShiftContext()?.targetLayoutID
        ExplicitSourceSelectionRecovery.switchOpposite(intendedTargetID: intended,
            switchSource: { LayoutSwitcher.switchToOpposite() },
            observeSource: LayoutSwitcher.currentLayoutID,
            confirm: { [weak self] target, observed in
                _ = self?.keyboardMonitor.recordExplicitInputSourceSelection(
                    targetID: target, observedSourceID: observed)
            })
    }

    @discardableResult
    private func showFeedback(title: String, body: String, kind: SecureInputNotice.Kind? = nil,
        actionTitle: String? = nil, onAction: (() -> Void)? = nil) -> Bool {
        // A fresh failure retires an old exception offer even when the
        // duplicate failure notice itself is throttled.
        correctionExceptionOffer.hide()
        return secureNotice.show(title: title, body: body, kind: kind,
            actionTitle: actionTitle, onAction: onAction)
    }

    private func offerExceptionAfterConfirmedUndo(_ notice: ConfirmedCorrectionNotice) {
        secureNotice.hide()
        guard !SettingsManager.shared.deniedWordsSet.contains(notice.original.lowercased()) else { return }
        correctionExceptionOffer.show(notice, onSaved: { [weak self] in
            self?.predictionCoordinator.invalidate()
        }, onFailure: { [weak self] in
            self?.showFeedback(title: "MacSwitcher",
                body: L10n.languageCode == "ru"
                    ? "Не удалось сохранить исключение. Откройте личный словарь в настройках."
                    : "Could not save the exception. Open the personal dictionary in Settings.",
                kind: .saveFailure)
        })
    }

    private func showUnknownEditNotice() {
        let hasRecovery = textConverter.hasUnconfirmedAXEdit || !shellCoordinator.uncertainOriginals.isEmpty
        showFeedback(title: "MacSwitcher",
            body: CorrectionFeedbackPolicy.recoveryMessage(languageCode: L10n.languageCode,
                hasRecovery: hasRecovery),
            kind: .unknownEdit,
            actionTitle: hasRecovery ? (L10n.languageCode == "ru" ? "Показать исходный текст" : "Show original text") : nil,
            onAction: hasRecovery ? { [weak self] in self?.openRecoveryOriginals() } : nil)
    }

    private func showRecoveryCapacityNotice(_ reason: TextConverter.RecoveryCapacityReason) {
        let now = Date()
        if let last = lastRecoveryCapacityNoticeAt, now.timeIntervalSince(last) < 60 { return }
        lastRecoveryCapacityNoticeAt = now
        let body: String
        switch reason {
        case .unsaved:
            body = L10n.languageCode == "ru"
                ? "Память исходных текстов заполнена. Сохраните их локально через меню MacSwitcher, чтобы продолжить в других полях. Поля с неподтверждённой правкой останутся заблокированы."
                : "Original-text memory is full. Save originals locally from the MacSwitcher menu to continue in other fields. Fields with unconfirmed edits stay blocked."
        case .archiveLimit:
            body = L10n.languageCode == "ru"
                ? "Достигнут предел сохранённых полей. Закройте затронутые поля и штатно перезапустите MacSwitcher после проверки архивов."
                : "Saved-field limit reached. Close affected fields and restart MacSwitcher normally after checking the archives."
        }
        showFeedback(title: "MacSwitcher", body: body,
            kind: .unknownEdit,
            actionTitle: L10n.languageCode == "ru" ? "Открыть исходники" : "Open originals",
            onAction: { [weak self] in self?.openRecoveryOriginals() })
    }

    private func showRecoveryArchiveFailure(manual: Bool, reason: RecoveryArchive.Failure) {
        switch reason {
        case .archiveLimit: RuntimeDiagnostics.record(.recoveryArchiveQuota)
        case .verificationFailed, .invalidSources: RuntimeDiagnostics.record(.recoveryArchiveVerificationFailed)
        case .syncFailed, .writeFailed: RuntimeDiagnostics.record(.recoveryArchiveWriteFailed)
        }
        if manual {
            let alert = NSAlert()
            alert.messageText = L10n.languageCode == "ru" ? "Исходники не сохранены" : "Originals were not saved"
            alert.informativeText = L10n.languageCode == "ru"
                ? (reason == .archiveLimit
                    ? "Папка Recovery достигла лимита. Исходники остаются в памяти. Проверьте архивы перед удалением; штатный выход отменится, если сохранить их не удастся."
                    : "Исходники остаются в памяти. Проверьте папку Recovery и повторите сохранение через меню. Штатный выход отменится, если сохранить их не удастся.")
                : (reason == .archiveLimit
                    ? "The Recovery folder reached its limit. Originals remain in memory. Check archives before deleting any; normal quit will be cancelled if saving fails."
                    : "Originals remain in memory. Check the Recovery folder and retry from the menu. Normal quit will be cancelled if saving fails.")
            alert.runModal()
        } else {
            let quota = reason == .archiveLimit
            showFeedback(title: "MacSwitcher", body: L10n.languageCode == "ru"
                ? (quota ? "Папка Recovery достигла лимита. Исходники остаются в памяти. Откройте архивы; перед удалением проверьте, что они больше не нужны."
                    : "Не удалось сохранить исходники локально. Они остаются в памяти; повторите сохранение через меню.")
                : (quota ? "Recovery archive limit reached. Originals remain in memory. Open archives; check that files are no longer needed before deleting any."
                    : "Could not save originals locally. They remain in memory; retry from the menu."),
                kind: .saveFailure,
                actionTitle: L10n.languageCode == "ru" ? "Открыть Recovery" : "Open Recovery",
                onAction: { [weak self] in self?.openRecoveryArchiveFolder() })
        }
    }

    private func openRecoveryOriginals() {
        guard textConverter.hasUnconfirmedAXEdit,
              let parent = statusItem.menu?.item(withTag: Self.recoveryCopyItemTag) else { return }
        refreshRecoveryMenu(parent)
        _ = parent.submenu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
                            }
                            return
                        }
                    } else {
                        // Обычные приложения: сами выделяем строку (Shift+Cmd+←) и конвертируем.
                        if self.textConverter.convertLine() {
                            self.keyboardMonitor.markConverted()
                            LayoutSwitcher.switchToOpposite()
                            self.updateStatusIcon()
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
                }
            }
        ) {
            // Keep the ordinary callbacks configured and let the existing
            // two-second health poll plus one tap recovery queue retry safely.
            rslog("Event tap failed - health poll will retry when safe")
        }

        monitoringActive = true
        syncElectronAccessibilityBridge()
        configurePredictionPreferences()
        keyboardMonitor.onCombinedShift = { [weak self] request in
            self?.handleCombinedShift(request)
        }
        keyboardMonitor.onRuntimeSecureInputObserved = { [weak self] in
            self?.runtimeHealth.noteSecureInputObserved()
        }
        keyboardMonitor.onRuntimeSecureInputResumed = { [weak self] in
            self?.runtimeHealth.noteSecureInputResumed()
        }
        keyboardMonitor.onRuntimeNormalKeyboardActivity = { [weak self] in
            self?.runtimeHealth.noteNormalKeyboardActivity() ?? true
        }
        keyboardMonitor.onPredictionInput = { [weak self] snapshot in
            self?.predictionCoordinator.submit(snapshot)
        }
        keyboardMonitor.onPredictionInvalidated = { [weak self] in
            self?.predictionCoordinator.invalidate()
        }
        predictionCoordinator.onApplied = { [weak self] original in
            self?.manualLearningProvenance.invalidate()
            self?.automaticUndoLearningProvenance.invalidate()
            self?.diagnosticRepro?.noteAutomaticApplication()
            self?.updateStatusIcon()
        }
        // Routine corrections stay quiet. The confirmed receipt remains
        // available to double Shift; an explicit undo may offer an exception.
        predictionCoordinator.onCorrection = nil
        predictionCoordinator.onConfirmedAutomaticUndo = { [weak self] notice in
            self?.offerExceptionAfterConfirmedUndo(notice)
        }
        predictionCoordinator.onAdaptiveAutomaticUndo = { [weak self] id, original, replacement, focus, generation in
            self?.manualLearningProvenance.invalidate()
            self?.automaticUndoLearningProvenance.confirmedUndo(id: id,
                original: original, replacement: replacement, focus: focus)
            self?.enqueueAdaptive(.automaticUndoConfirmed(id: id,
                original: original, replacement: replacement), generation: generation)
        }
        predictionCoordinator.adaptiveRulesProvider = { AdaptiveRuleStore.shared.rules() }
        predictionCoordinator.adaptiveGenerationProvider = { AdaptiveRuleStore.shared.currentGeneration }
        predictionCoordinator.onUnconfirmedEdit = { [weak self] in
            self?.showUnknownEditNotice()
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
                self.switchOppositeExplicitly()
                self.updateStatusIcon()
                rslog("switch hotkey: local layout switched (remote client focused)")
                return
            }
            self.switchOppositeExplicitly()
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
                self.runtimeHealth.poll()
                self.electronAccessibilityBridge.refresh()
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
        // A newer Shift action supersedes any selected-text lexicon await,
        // even if no character event changed the input revision.
        _ = nativeSelectionAwaitGate.nextAction()
        pendingNativeSelection?.cancel()
        pendingNativeSelection = nil
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
            // A fresh, confirmed user choice supersedes an older unresolved
            // source request; passive observations still cannot clear it.
            _ = keyboardMonitor.recordExplicitInputSourceSelection(
                targetID: direction.targetLayoutID, observedSourceID: LayoutSwitcher.currentLayoutID())
            updateStatusIcon()
            shellCoordinator.prepare(first: request)
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
        let nativeFallback = { [weak self] in
            guard let self else { return }
            self.runNativeCombinedShift(request, context: context)
        }
        if shellCoordinator.convert(second: request, context: context,
            converter: textConverter, isCurrent: { [weak self] in
                guard let self else { return false }
                return SettingsManager.shared.shellBridgeEnabled
                    && SettingsManager.shared.combinedShiftEnabled
                    && SettingsManager.shared.autoSwitchEnabled
                    && self.keyboardMonitor.inputRevision == request.inputRevision
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == request.frontProcessID
                    && LayoutSwitcher.currentLayoutID() == context.targetLayoutID
                    && !AutoSwitchPolicy.secureInputActive
            }, nativeFallback: nativeFallback) { return }
        nativeFallback()
    }

    private func runNativeCombinedShift(_ request: CombinedShiftRequest,
                                        context: CombinedShiftContext) {
        guard let focus = request.focus,
              (focus.searchOverlay?.hostPID == request.frontProcessID
                || (focus.searchOverlay == nil && focus.processID == request.frontProcessID)),
              focus.currentTargetProcessID() == focus.processID else {
            RuntimeDiagnostics.record(.doubleMissingFocus); return
        }
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: request.inputRevision,
            currentInputRevision: { [weak self] in self?.keyboardMonitor.inputRevision ?? UInt64.max })
        guard execution.isValid() else { RuntimeDiagnostics.record(.doubleInvalidExecution); return }

        handleVerifiedCombinedShift(request, context: context, execution: execution)
    }

    private func handleVerifiedCombinedShift(_ request: CombinedShiftRequest,
        context: CombinedShiftContext, execution: CombinedShiftExecutionContext) {
        let settings = SettingsManager.shared
        let languages = LayoutSwitcher.currentAndOppositeLanguage(context: context)
        let nativeRUEN = languages.map { Set([$0.current, $0.opposite]) == Set(["ru", "en"]) } == true
        if (execution.focus.initialSelection?.length ?? 0) > 0,
           !textConverter.hasUnconfirmedAXEdit(in: execution.focus),
           !settings.convertByText, settings.smartConversion, nativeRUEN {
            guard !AutoSwitchPolicy.secureInputActive,
                  LayoutSwitcher.currentLayoutID() == context.targetLayoutID,
                  let baseline = textConverter.nativeSelectionBaseline(execution: execution),
                  let queries = SmartConvert.requiredNativeWordEvidence(baseline.selection.text,
                      context: context) else {
                showCombinedShiftRefusal()
                return
            }
            let generation = nativeSelectionAwaitGate.nextAction()
            pendingNativeSelection = Task { @MainActor [weak self] in
                guard let self else { return }
                let evidence = await self.predictionCoordinator.nativeSelectionEvidence(for: queries)
                guard self.nativeSelectionAwaitGate.permits(generation,
                    cancelled: Task.isCancelled) else { return }
                guard let evidence,
                      let current = self.textConverter.nativeSelectionBaseline(execution: execution),
                      baseline.matches(current),
                      self.keyboardMonitor.inputRevision == execution.inputRevision,
                      execution.focus.currentTargetProcessID() == execution.focus.processID,
                      !AutoSwitchPolicy.secureInputActive,
                      LayoutSwitcher.currentLayoutID() == context.targetLayoutID else {
                    self.showCombinedShiftRefusal()
                    return
                }
                self.runVerifiedCombinedShift(request, context: context, execution: execution,
                    selectionKnownWord: { word, language in
                        evidence[SmartConvert.WordQuery(word: word, language: language)]
                    })
            }
            return
        }
        runVerifiedCombinedShift(request, context: context, execution: execution)
    }

    private func showCombinedShiftRefusal() {
        DispatchQueue.main.async { [weak self] in
            self?.showFeedback(title: "MacSwitcher",
                body: CorrectionFeedbackPolicy.retryMessage(languageCode: L10n.languageCode),
                kind: .manualFailure)
        }
    }

    private func runVerifiedCombinedShift(_ request: CombinedShiftRequest,
        context: CombinedShiftContext, execution: CombinedShiftExecutionContext,
        selectionKnownWord: ((String, String) -> Bool?)? = nil) {
        let platform = CombinedShiftTransaction.Platform(
            currentSourceID: LayoutSwitcher.currentLayoutID,
            frontProcessID: { execution.focus.currentTargetProcessID() },
            secureInputActive: { AutoSwitchPolicy.secureInputActive },
            beginLease: { [weak self] pid in
                self?.keyboardMonitor.beginNativeInputTransaction(processID: pid)
            }, leaseIsCurrent: { [weak self] lease in
                self?.keyboardMonitor.nativeInputTransactionIsCurrent(lease) == true
            }, leaseRemaining: { [weak self] lease in
                self?.keyboardMonitor.nativeInputTransactionRemainingDuration(lease)
            }, finishLease: { [weak self] lease, source in
                self?.keyboardMonitor.finishNativeInputTransaction(lease, replayLayoutID: source)
            }, pendingSourceTargetID: { [weak self] in
                self?.keyboardMonitor.pendingInputSourceTargetID
            }, selectSource: { LayoutSwitcher.switchToWithConfirmation(layoutID: $0) },
            noteUnconfirmedSource: { [weak self] target, requestedAt in
                self?.keyboardMonitor.noteUnconfirmedInputSource(target, requestedAt: requestedAt)
            }, observeWholeField: { [weak self] focus in
                guard let self else { return nil }
                let current = CombinedShiftExecutionContext(focus: focus,
                    inputRevision: execution.inputRevision,
                    currentInputRevision: { [weak self] in
                        self?.keyboardMonitor.inputRevision ?? UInt64.max
                    })
                return self.textConverter.nativeSelectionBaseline(execution: current)?.field
            }, applicationFamily: {
                CombinedShiftApplicationFamily.classify(
                    bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            })
        let automaticUndo = predictionCoordinator.claimDoubleShiftAutomaticUndo(
            request: request, context: context, observedSourceID: platform.currentSourceID())
        let result = CombinedShiftTransaction.run(request: request, context: context,
            execution: execution, converter: textConverter, monitor: keyboardMonitor,
            platform: platform, convertWholeLine: SettingsManager.shared.convertWholeLine,
            contextForSource: { LayoutSwitcher.combinedShiftContext(sourceLayoutID: $0) },
            selectionKnownWord: selectionKnownWord, automaticUndo: automaticUndo)
        if let notice = result.failureNotice {
            // The helper released the input fence before any user-facing notice.
            switch notice {
            case .unconfirmedEdit:
                DispatchQueue.main.async { [weak self] in self?.showUnknownEditNotice() }
            case .noSafeEdit:
                let hasTarget = CorrectionFeedbackPolicy.hasManualTarget(
                    selectionLength: execution.focus.initialSelection?.length ?? 0,
                    currentWordCount: request.wordKeys.count,
                    previousWordCount: request.prevWordKeys.count,
                    boundaryCount: request.boundaryCount,
                    reconvert: request.reconvert,
                    hasReconversionState: textConverter.hasReconversionState)
                if case .manual = automaticUndo, hasTarget { showCombinedShiftRefusal() }
            case .sourceNotConfirmed:
                break
            }
        }
        if let target = result.pendingSourceTargetID {
            DispatchQueue.main.async { [weak self] in self?.presentSourceFailure(targetID: target) }
        }
        switch result.outcome {
        case .none, .some(.stopped):
            break
        case .some(.sourceNotConfirmed(let targetID, _)):
            if result.pendingSourceTargetID == nil {
                DispatchQueue.main.async { [weak self] in self?.presentSourceFailure(targetID: targetID) }
            }
        case .some(.confirmed):
            updateStatusIcon()
            if let receipt = result.confirmedAutomaticUndo {
                manualLearningProvenance.invalidate()
                predictionCoordinator.completeDoubleShiftAutomaticUndo(receipt)
            } else if case .manual = automaticUndo {
                if let pair = textConverter.lastConfirmedManualWordPair,
                   let focus = request.focus {
                    if request.reconvert,
                       let retraction = automaticUndoLearningProvenance.confirmedRedo(
                            original: pair.original, replacement: pair.replacement,
                            focus: focus) {
                        manualLearningProvenance.invalidate()
                        enqueueAdaptive(retraction)
                    } else {
                        if !request.reconvert { automaticUndoLearningProvenance.invalidate() }
                        if let evidence = manualLearningProvenance.confirmed(
                            original: pair.original, replacement: pair.replacement,
                            focus: focus, reconvert: request.reconvert) {
                            enqueueAdaptive(evidence)
                        }
                    }
                } else {
                    manualLearningProvenance.invalidate()
                    automaticUndoLearningProvenance.invalidate()
                }
            }
        }
    }

    private func enqueueAdaptive(_ evidence: AdaptiveEvidence, generation: UInt64? = nil) {
        let generation = generation ?? AdaptiveRuleStore.shared.currentGeneration
        adaptiveQueue.async {
            _ = try? AdaptiveRuleStore.shared.record(evidence, generation: generation)
        }
    }

    private func showAdaptiveIntroIfNeeded() {
        let key = "com.macswitcher.adaptiveLearningIntroShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !UserDefaults.standard.bool(forKey: key) else { return }
            let shown = self.showFeedback(title: "Локальное обучение MacSwitcher",
                body: "После двух независимых исправлений одного слова выбор запоминается только на этом Mac. В настройках → Обучение можно отключить функцию и удалить правила. История набора не сохраняется.",
                kind: .adaptiveIntro, actionTitle: "Настройки", onAction: { [weak self] in
                    self?.settingsController.showWindow()
                })
            if shown {
                UserDefaults.standard.set(true, forKey: key)
                AdaptiveRuleStore.shared.setEnabled(SettingsManager.shared.adaptiveLearningEnabled)
            }
        }
    }

    private func resetCombinedShiftAfterPause() {
        _ = nativeSelectionAwaitGate.nextAction()
        pendingNativeSelection?.cancel()
        pendingNativeSelection = nil
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
        menu.addItem(recovery)
        refreshRecoveryMenu(recovery)
        let archiveFolder = NSMenuItem(title: L10n.languageCode == "ru"
            ? "Открыть папку архивов исходников"
            : "Open original-text archive folder", action: #selector(openRecoveryArchiveFolder), keyEquivalent: "")
        archiveFolder.target = self
        menu.addItem(archiveFolder)
        menu.addItem(NSMenuItem.separator())

        let inputSource = NSMenuItem(title: L10n.menuInputSource, action: nil, keyEquivalent: "")
        inputSource.tag = Self.inputSourceMenuTag
        let inputSourceMenu = NSMenu()
        for item in layoutMenuItems() { inputSourceMenu.addItem(item) }
        inputSource.submenu = inputSourceMenu
        menu.addItem(inputSource)

        let sourceRecovery = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sourceRecovery.tag = Self.sourceRecoveryItemTag
        sourceRecovery.isEnabled = false
        menu.addItem(sourceRecovery)
        refreshSourceRecoveryMenu(sourceRecovery)

        let more = NSMenuItem(title: L10n.menuMore, action: nil, keyEquivalent: "")
        let moreMenu = NSMenu()
        let keySoundItem = NSMenuItem(title: L10n.menuKeySound, action: #selector(toggleKeySound), keyEquivalent: "")
        keySoundItem.target = self
        keySoundItem.state = SettingsManager.shared.keySound ? .on : .off
        moreMenu.addItem(keySoundItem)

        let caretFlagItem = NSMenuItem(title: L10n.menuCaretFlag, action: #selector(toggleCaretFlag), keyEquivalent: "")
        caretFlagItem.target = self
        caretFlagItem.state = SettingsManager.shared.caretFlag ? .on : .off
        moreMenu.addItem(caretFlagItem)

        // Единый стиль меню-бара (Sequoia): монохромная плашка вместо цветного флага.
        let monoIconItem = NSMenuItem(title: L10n.menuMonoIcon, action: #selector(toggleMonoIcon), keyEquivalent: "")
        monoIconItem.target = self
        monoIconItem.state = SettingsManager.shared.monochromeIcon ? .on : .off
        moreMenu.addItem(monoIconItem)

        // Режим удалённого стола отложен в 2.5 — тумблер скрыт за флагом (для тестирования).
        if SettingsManager.shared.showRemoteDesktopBeta {
            let remoteDesktopItem = NSMenuItem(title: L10n.menuRemoteDesktop, action: #selector(toggleRemoteDesktop), keyEquivalent: "")
            remoteDesktopItem.target = self
            remoteDesktopItem.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
            moreMenu.addItem(remoteDesktopItem)
        }

        let permItem = NSMenuItem(title: L10n.menuCheckPermissions, action: #selector(recheckPermissions), keyEquivalent: "")
        permItem.target = self
        moreMenu.addItem(NSMenuItem.separator())
        moreMenu.addItem(permItem)
        let updateItem = NSMenuItem(title: L10n.menuCheckUpdates, action: #selector(checkUpdates), keyEquivalent: "")
        updateItem.target = self
        moreMenu.addItem(updateItem)
        more.submenu = moreMenu

        let settingsItem = NSMenuItem(title: L10n.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(more)

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
    private static let inputSourceMenuTag = 742

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
        guard let layoutMenu = menu.item(withTag: Self.inputSourceMenuTag)?.submenu else { return }
        for old in layoutMenu.items where old.tag == Self.layoutItemTag { layoutMenu.removeItem(old) }
        for item in layoutMenuItems() { layoutMenu.addItem(item) }
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
            _ = keyboardMonitor.recordExplicitInputSourceSelection(
                targetID: id, observedSourceID: LayoutSwitcher.currentLayoutID())
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
        statusItem.button?.toolTip = runtimeHealthTooltip(runtimeHealth.state)
        if changed { caretIndicator?.layoutChanged() }
    }

    private func runtimeHealthTooltip(_ state: RuntimeHealthState) -> String? {
        let ru = L10n.languageCode == "ru"
        switch state {
        case .off, .connected: return nil
        case .sleeping: return ru ? "MacSwitcher: выход из сна" : "MacSwitcher: waking up"
        case .permissionsRequired: return ru ? "MacSwitcher: проверьте разрешения" : "MacSwitcher: check permissions"
        case .secureInputPaused: return ru ? "MacSwitcher: защищённый ввод" : "MacSwitcher: Secure Input"
        case .editDeferred: return ru ? "MacSwitcher: восстановление отложено" : "MacSwitcher: recovery deferred"
        case .tapUnavailable: return ru ? "MacSwitcher: нет подключения к клавиатуре" : "MacSwitcher: keyboard connection unavailable"
        case .shellRecovering: return ru ? "MacSwitcher: подключение терминала восстанавливается" : "MacSwitcher: terminal connection recovering"
        case .shellNeedsUserAction: return ru ? "MacSwitcher: проверьте подключение терминала" : "MacSwitcher: check terminal connection"
        case .unconfirmedEdit: return ru ? "MacSwitcher: есть неподтверждённая правка" : "MacSwitcher: an edit is unconfirmed"
        case .selfCheckFailed: return ru ? "MacSwitcher: внутренняя проверка не прошла" : "MacSwitcher: internal check failed"
        }
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

    private func syncElectronAccessibilityBridge() {
        if ElectronAccessibilityBridge.shouldRun(monitoringActive: monitoringActive,
                autoSwitchEnabled: SettingsManager.shared.autoSwitchEnabled) {
            electronAccessibilityBridge.start()
        } else {
            electronAccessibilityBridge.stop()
        }
    }

    // MARK: - Actions

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        SettingsManager.shared.autoSwitchEnabled.toggle()
        resetCombinedShiftAfterPause()
        syncElectronAccessibilityBridge()
        configureShellBridge()
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
        let hasRecovery = textConverter.hasUnconfirmedAXEdit || !shellCoordinator.uncertainOriginals.isEmpty
        parent.isEnabled = hasRecovery
        parent.isHidden = !hasRecovery
        let submenu = NSMenu()
        for (index, original) in textConverter.unconfirmedOriginals.enumerated() {
            let title = L10n.languageCode == "ru" ? "Скопировать исходный текст \(index + 1)" : "Copy original text \(index + 1)"
            let item = NSMenuItem(title: title, action: #selector(copyRecoveryOriginal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = original
            submenu.addItem(item)
        }
        for (index, original) in textConverter.archivedOriginals.enumerated() {
            let title = L10n.languageCode == "ru" ? "Скопировать из архива \(index + 1)" : "Copy from archive \(index + 1)"
            let item = NSMenuItem(title: title, action: #selector(copyArchivedRecoveryOriginal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = original
            submenu.addItem(item)
        }
        for (index, original) in shellCoordinator.uncertainOriginals.enumerated() {
            let title = L10n.languageCode == "ru"
                ? "Скопировать исходную строку терминала \(index + 1)"
                : "Copy original terminal line \(index + 1)"
            let item = NSMenuItem(title: title, action: #selector(copyShellRecoveryOriginal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = original
            submenu.addItem(item)
        }
        if textConverter.hasRAMUnconfirmedAXEdit || shellCoordinator.hasUnbackedUnknown {
            submenu.addItem(NSMenuItem.separator())
            let save = NSMenuItem(title: L10n.languageCode == "ru"
                ? "Сохранить исходники локально и продолжить"
                : "Save originals locally and continue", action: #selector(saveRecoveryOriginals), keyEquivalent: "")
            save.target = self
            submenu.addItem(save)
        }
        parent.submenu = submenu
    }

    @objc private func copyRecoveryOriginal(_ sender: NSMenuItem) {
        guard let original = sender.representedObject as? TextConverter.RecoveryOriginal else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original.text, forType: .string)
    }

    @objc private func copyArchivedRecoveryOriginal(_ sender: NSMenuItem) {
        guard let original = sender.representedObject as? TextConverter.ArchivedRecoveryOriginal else { return }
        do {
            let text = try RecoveryArchive.original(id: original.id, receipt: original.archive)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } catch {
            RuntimeDiagnostics.record(.recoveryArchiveFailed)
            let alert = NSAlert()
            alert.messageText = L10n.languageCode == "ru" ? "Не удалось прочитать архив" : "Could not read the archive"
            alert.runModal()
        }
    }

    @objc private func saveRecoveryOriginals() {
        recoveryArchiveController.requestManual()
        if shellCoordinator.hasUnbackedUnknown {
            do {
                shellCoordinator.scheduleAutomaticArchive(in: try recoveryDirectory()) { [weak self] in
                    self?.showFeedback(title: "MacSwitcher",
                        body: L10n.languageCode == "ru"
                            ? "Исходная строка терминала осталась в памяти; сохранение не удалось."
                            : "The original terminal line remains in memory; saving failed.", kind: .saveFailure)
                }
            } catch {
                showFeedback(title: "MacSwitcher",
                    body: L10n.languageCode == "ru"
                        ? "Исходная строка терминала осталась в памяти; сохранение не удалось."
                        : "The original terminal line remains in memory; saving failed.", kind: .saveFailure)
            }
        }
    }

    @objc private func copyShellRecoveryOriginal(_ sender: NSMenuItem) {
        guard let original = sender.representedObject as? ManualShellCoordinator.RecoveryOriginal else { return }
        let text: String
        if let archive = original.archive {
            guard let saved = try? RecoveryArchive.original(id: original.id, receipt: archive) else { return }
            text = saved
        } else {
            guard let retained = original.text else { return }
            text = retained
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openRecoveryArchiveFolder() {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return }
        let directory = support.appendingPathComponent("MacSwitcher/Recovery", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { NSWorkspace.shared.open(directory) }
    }

    @objc private func observedApplicationTermination(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        textConverter.releaseArchivedLocks(forTerminatedProcessID: application.processIdentifier)
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
        tapRecovery.request(allowNewEpisode: true)
    }

    private func runtimeHealthSnapshot() -> RuntimeHealthSnapshot {
        RuntimeHealthSnapshot(monitoring: monitoringActive,
            masterEnabled: SettingsManager.shared.autoSwitchEnabled,
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: CGPreflightListenEventAccess(),
            secureInput: AutoSwitchPolicy.secureInputActive,
            sleeping: systemSleeping,
            tap: keyboardMonitor.nativeTapRecoveryStatus,
            nativeLeaseActive: keyboardMonitor.hasNativeInputLease,
            shellEditActive: shellCoordinator.hasInFlightEdit,
            unknownEditRetained: textConverter.hasUnconfirmedAXEdit
                || !shellCoordinator.uncertainOriginals.isEmpty,
            shell: shellCoordinator.health)
    }

    private func mayReconfigureRuntimeTap() -> Bool {
        runtimeHealth.mayReconfigureTap()
    }

    private func runtimeWillSleep() {
        systemSleeping = true
        runtimeHealth.poll(reason: .sleep)
    }

    private func runtimeDidWake() {
        systemSleeping = false
        runtimeHealth.poll(reason: .wake)
    }

    private func showRuntimeCheck() {
        let report = runtimeHealth.runManualCheck()
        let ru = L10n.languageCode == "ru"
        let summary: String
        switch report.state {
        case .off: summary = ru ? "Обработка выключена в настройках." : "Processing is off in settings."
        case .sleeping: summary = ru ? "Компьютер выходит из сна." : "The Mac is waking up."
        case .permissionsRequired: summary = ru ? "Проверьте разрешения «Универсальный доступ» и «Мониторинг ввода»." : "Check Accessibility and Input Monitoring permissions."
        case .secureInputPaused: summary = ru ? "Защищённый ввод временно приостановил обработку." : "Secure Input has paused processing."
        case .editDeferred: summary = ru ? "Идёт редактирование; восстановление отложено." : "An edit is in progress; recovery is deferred."
        case .tapUnavailable:
            summary = ru
                ? (tapRecovery.isExhausted ? "MacSwitcher не получает нажатия. Проверьте разрешения и попробуйте проверку ещё раз." : "MacSwitcher пока не подключён к клавиатуре; повторяем проверку.")
                : (tapRecovery.isExhausted ? "MacSwitcher cannot receive keys. Check permissions and run the check again." : "MacSwitcher is not connected to the keyboard yet; checking again.")
        case .shellRecovering: summary = ru ? "Подключение терминала временно недоступно; число повторов ограничено." : "The terminal connection is temporarily unavailable; retries are limited."
        case .shellNeedsUserAction: summary = ru ? "Проверьте подключение терминала и доступ к вкладке." : "Check the terminal connection and tab access."
        case .unconfirmedEdit: summary = ru ? "Есть неподтверждённая замена. Проверьте исходный текст в меню восстановления." : "An edit is unconfirmed. Check the original text in the recovery menu."
        case .connected: summary = ru ? "MacSwitcher подключён к клавиатуре." : "MacSwitcher is connected to the keyboard."
        case .selfCheckFailed: summary = ru ? "Внутренняя проверка не прошла." : "An internal check failed."
        }
        let passed = report.checks.filter { $0.passed }.count
        var detail = ru
            ? "\(summary)\n\nВнутренние проверки: \(passed)/\(report.checks.count). Они не проверяют ввод в других приложениях."
            : "\(summary)\n\nInternal checks: \(passed)/\(report.checks.count). They do not test typing in other apps."
        if case .listening(let sessions) = report.shell, sessions == 0 {
            detail += ru
                ? "\n\nТерминал: сейчас нет подключения. При необходимости проверьте настройку и откройте новое окно."
                : "\n\nzsh: no prompt is connected now. Check setup and open a new window if needed."
        }
        if report.unknownEditRetained && report.state != .unconfirmedEdit {
            detail += ru
                ? "\n\nЕсть неподтверждённая замена. Проверьте исходный текст в меню восстановления."
                : "\n\nAn edit is unconfirmed. Check the original text in the recovery menu."
        }
        let alert = NSAlert()
        alert.messageText = ru ? "Проверка MacSwitcher" : "MacSwitcher check"
        alert.informativeText = detail
        alert.runModal()
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
        NSWorkspace.shared.notificationCenter.removeObserver(self,
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if let runtimeSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(runtimeSleepObserver) }
        if let runtimeWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(runtimeWakeObserver) }
        monitoringActive = false
        tapRecovery.stop()
        iconRefreshTimer?.invalidate()
        predictionCoordinator.invalidate()
        electronAccessibilityBridge.stop()
        perAppLayoutManager.stop()
        keyboardMonitor.stop()
        shellCoordinator.configure(enabled: false)
        // Не теряем буфер обмена в 2-секундном окне отложенного восстановления
        // (актуально и при само-обновлении, которое завершает процесс).
        textConverter.flushPendingClipboardRestore()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shellCoordinator.hasInFlightEdit {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.languageCode == "ru"
                ? "Подождите завершения исправления строки" : "Wait for the line edit to finish"
            alert.informativeText = L10n.languageCode == "ru"
                ? "Исходная строка хранится в памяти, пока результат записи не подтверждён. Повторите выход после завершения проверки."
                : "The original line remains in memory until the edit is verified. Quit again after verification finishes."
            alert.runModal()
            return .terminateCancel
        }
        guard textConverter.hasRAMUnconfirmedAXEdit || shellCoordinator.hasUnbackedUnknown else {
            return .terminateNow
        }
        // Normal quit is an explicit user action, outside the physical input
        // lease. Validate existing backups before deciding which RAM originals
        // still need a new export; never spend archive quota twice for them.
        for source in textConverter.backedOriginals {
            if (try? RecoveryArchive.original(id: source.id, receipt: source.archive)) != source.text {
                textConverter.invalidateBacking(id: source.id, receipt: source.archive)
            }
        }
        guard !textConverter.unbackedOriginals.isEmpty || shellCoordinator.hasUnbackedUnknown else {
            return .terminateNow
        }
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
            let originals = textConverter.unbackedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
            if !originals.isEmpty { _ = try RecoveryArchive.save(originals, in: directory) }
            try shellCoordinator.saveUncertainOriginals(in: directory)
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
