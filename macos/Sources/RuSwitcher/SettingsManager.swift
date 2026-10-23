import Foundation
import ServiceManagement

/// Централизованное хранение настроек через UserDefaults
/// Настройки приложения. Свойства thread-safe через UserDefaults.
final class SettingsManager: @unchecked Sendable {
    static let shared = SettingsManager(defaults: .standard)

    private let defaults: UserDefaults
    private let combinedShiftDefault: Bool
    private let nativeRolloutAccepted: Bool

    private enum Keys {
        static let autoSwitch = "com.ruswitcher.autoSwitch"
        static let layout1ID = "com.ruswitcher.layout1ID"
        static let layout2ID = "com.ruswitcher.layout2ID"
        static let debugLog = "com.ruswitcher.debugLog"
        static let skippedVersion = "com.ruswitcher.skippedVersion"
        static let lastUpdateCheck = "com.ruswitcher.lastUpdateCheck"
        static let launchAtLogin = "com.ruswitcher.launchAtLogin"
        static let checkUpdatesEnabled = "com.ruswitcher.checkUpdatesEnabled"
        static let betaChannelEnabled = "com.ruswitcher.betaChannelEnabled"
        static let interfaceLanguage = "com.ruswitcher.interfaceLanguage"
        static let permissionsWereGranted = "com.ruswitcher.permissionsWereGranted"
        static let launchAtLoginAsked = "com.ruswitcher.launchAtLoginAsked"
        static let perAppLayout = "com.ruswitcher.perAppLayout"
        static let triggerKey = "com.ruswitcher.triggerKey"
        static let triggerRightOnly = "com.ruswitcher.triggerRightOnly"
        static let triggerDoubleTap = "com.ruswitcher.triggerDoubleTap"
        static let combinedShift = "com.ruswitcher.combinedShiftEnabled"
        static let doubleShiftIntervalMilliseconds = "com.macswitcher.doubleShiftIntervalMilliseconds"
        static let russianPriorityEnabled = "com.macswitcher.russianPriorityEnabled"
        static let switchHotkey = "com.ruswitcher.switchHotkey"
        static let switchDoubleTap = "com.ruswitcher.switchDoubleTap"
        static let switchRightOnly = "com.ruswitcher.switchRightOnly"
        static let caseHotkey = "com.ruswitcher.caseHotkey"       // issue #29
        static let caseDoubleTap = "com.ruswitcher.caseDoubleTap"
        static let caseRightOnly = "com.ruswitcher.caseRightOnly"
        static let autoConvert = "com.ruswitcher.autoConvert"
        static let nativeAutoEnabled = "com.macswitcher.nativeAutoEnabled"
        static let smartConversion = "com.ruswitcher.smartConversion"
        static let convertByText = "com.ruswitcher.convertByText"
        static let convertWholeLine = "com.ruswitcher.convertWholeLine"
        static let remoteDesktopMode = "com.ruswitcher.remoteDesktopMode"
        static let showRemoteDesktopBeta = "com.ruswitcher.showRemoteDesktopBeta"
        static let autoConvertOffered = "com.ruswitcher.autoConvertOffered"
        static let lastWhatsNewVersion = "com.ruswitcher.lastWhatsNewVersion"
        static let lastBetaNotesShown = "com.ruswitcher.lastBetaNotesShown"
        static let keySound = "com.ruswitcher.keySound"
        static let caretFlag = "com.ruswitcher.caretFlag"
        static let secureInputNotice = "com.ruswitcher.secureInputNotice"
        static let hideMenuBarIcon = "com.ruswitcher.hideMenuBarIcon"
        static let monochromeIcon = "com.ruswitcher.monochromeIcon"
        static let deniedAppsAdded = "com.ruswitcher.deniedAppsAdded"
        static let deniedAppsRemoved = "com.ruswitcher.deniedAppsRemoved"
        static let deniedWords = "com.ruswitcher.deniedWords"
        static let alwaysConvertWords = "com.ruswitcher.alwaysConvertWords"
    }

    init(defaults: UserDefaults, combinedShiftDefault: Bool = Bundle.main.object(forInfoDictionaryKey: "LocalCombinedShiftDefault") as? Bool ?? true,
         nativeRolloutAccepted: Bool = Bundle.main.object(forInfoDictionaryKey: "MacSwitcherNativeBackendAccepted") as? Bool ?? false) {
        self.defaults = defaults
        self.combinedShiftDefault = combinedShiftDefault
        self.nativeRolloutAccepted = nativeRolloutAccepted
    }

    // MARK: - Properties

    var autoSwitchEnabled: Bool {
        get { defaults.object(forKey: Keys.autoSwitch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoSwitch) }
    }

    /// ID первой раскладки (пустая строка = авто-определение)
    var layout1ID: String {
        get { defaults.string(forKey: Keys.layout1ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout1ID) }
    }

    /// ID второй раскладки (пустая строка = авто-определение)
    var layout2ID: String {
        get { defaults.string(forKey: Keys.layout2ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout2ID) }
    }

    var debugLogEnabled: Bool {
        get { false }
        set { /* Typed-text logging is disabled in the public alpha. */ }
    }

    var skippedVersion: String {
        get { defaults.string(forKey: Keys.skippedVersion) ?? "" }
        set { defaults.set(newValue, forKey: Keys.skippedVersion) }
    }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Keys.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastUpdateCheck) }
    }

    var launchAtLogin: Bool {
        get { defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            let enabled = newValue
            DispatchQueue.main.async {
                self.doUpdateLoginItem(enabled: enabled)
            }
        }
    }

    /// Авто-проверка обновлений при запуске (дефолт: включено).
    /// На ручную проверку через меню не влияет.
    var checkUpdatesEnabled: Bool {
        get { defaults.object(forKey: Keys.checkUpdatesEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.checkUpdatesEnabled) }
    }

    /// Include prereleases from our GitHub Releases list. Alpha builds default
    /// to this channel; stable builds default to stable-only updates.
    var betaChannelEnabled: Bool {
        get { defaults.object(forKey: Keys.betaChannelEnabled) as? Bool
            ?? (Bundle.main.object(forInfoDictionaryKey: "MacSwitcherChannel") as? String == "alpha") }
        set { defaults.set(newValue, forKey: Keys.betaChannelEnabled) }
    }

    /// Язык интерфейса (пустая строка = авто-определение по системе)
    var interfaceLanguage: String {
        get { defaults.string(forKey: Keys.interfaceLanguage) ?? "" }
        set {
            defaults.set(newValue, forKey: Keys.interfaceLanguage)
            L10n.reloadLanguage()
        }
    }

    /// Флаг: разрешения были ранее выданы (для определения сброса после обновления)
    var permissionsWereGranted: Bool {
        get { defaults.bool(forKey: Keys.permissionsWereGranted) }
        set { defaults.set(newValue, forKey: Keys.permissionsWereGranted) }
    }

    var launchAtLoginAsked: Bool {
        get { defaults.bool(forKey: Keys.launchAtLoginAsked) }
        set { defaults.set(newValue, forKey: Keys.launchAtLoginAsked) }
    }

    var perAppLayout: Bool {
        get { defaults.bool(forKey: Keys.perAppLayout) }
        set { defaults.set(newValue, forKey: Keys.perAppLayout) }
    }

    // MARK: - Триггер конвертации

    /// Клавиша-триггер: "option" | "command" | "control" | "shift" | "capsLock".
    /// Дефолт — option (как было до 2.3, поведение не меняется).
    var triggerKey: String {
        get { defaults.string(forKey: Keys.triggerKey) ?? "option" }
        set { defaults.set(newValue, forKey: Keys.triggerKey) }
    }

    /// Реагировать только на правую клавишу модификатора (для option/command/control/shift).
    var triggerRightOnly: Bool {
        get { defaults.bool(forKey: Keys.triggerRightOnly) }
        set { defaults.set(newValue, forKey: Keys.triggerRightOnly) }
    }

    /// Двойной тап вместо одиночного.
    var triggerDoubleTap: Bool {
        get { defaults.bool(forKey: Keys.triggerDoubleTap) }
        set { defaults.set(newValue, forKey: Keys.triggerDoubleTap) }
    }

    /// Native coordinated single/double Shift, enabled by default in MacSwitcher.
    var combinedShiftEnabled: Bool {
        get { defaults.object(forKey: Keys.combinedShift) as? Bool ?? combinedShiftDefault }
        set { defaults.set(newValue, forKey: Keys.combinedShift) }
    }

    /// A preference only. Automatic editing still requires its separate explicit enablement.
    var russianPriorityEnabled: Bool {
        get { defaults.object(forKey: Keys.russianPriorityEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.russianPriorityEnabled) }
    }

    /// Inclusive double-Shift window, clamped on both read and write.
    var doubleShiftIntervalMilliseconds: Int {
        get {
            let raw = defaults.object(forKey: Keys.doubleShiftIntervalMilliseconds) as? Int ?? 180
            return min(400, max(80, raw))
        }
        set { defaults.set(min(400, max(80, newValue)), forKey: Keys.doubleShiftIntervalMilliseconds) }
    }

    /// issue #14: отдельный хоткей «просто переключить раскладку» (без конверсии) —
    /// в т.ч. модификаторные комбо (Ctrl+Shift), которые системно назначить нельзя.
    /// Кодировка как у triggerKey; пустая строка — выключен (дефолт).
    var switchHotkey: String {
        get { defaults.string(forKey: Keys.switchHotkey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.switchHotkey) }
    }

    /// issue #14: смена раскладки по ДВОЙНОМУ тапу хоткея (зеркало triggerDoubleTap).
    var switchDoubleTap: Bool {
        get { defaults.bool(forKey: Keys.switchDoubleTap) }
        set { defaults.set(newValue, forKey: Keys.switchDoubleTap) }
    }

    /// issue #14: реагировать только на ПРАВУЮ клавишу хоткея (зеркало triggerRightOnly).
    /// Действует лишь для одиночных модификаторов; для комбо сторона не различается.
    var switchRightOnly: Bool {
        get { defaults.bool(forKey: Keys.switchRightOnly) }
        set { defaults.set(newValue, forKey: Keys.switchRightOnly) }
    }

    /// issue #29: хоткей смены регистра (кодировка как triggerKey; пустая строка — выключен, дефолт).
    var caseHotkey: String {
        get { defaults.string(forKey: Keys.caseHotkey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.caseHotkey) }
    }
    var caseDoubleTap: Bool {
        get { defaults.bool(forKey: Keys.caseDoubleTap) }
        set { defaults.set(newValue, forKey: Keys.caseDoubleTap) }
    }
    var caseRightOnly: Bool {
        get { defaults.bool(forKey: Keys.caseRightOnly) }
        set { defaults.set(newValue, forKey: Keys.caseRightOnly) }
    }

    /// Caps Lock как триггер требует consume-tap (чтобы подавить переключение регистра).
    var triggerIsCapsLock: Bool { triggerKey == "capsLock" }

    /// Автоматическая конвертация «на лету» (детект неправильной раскладки на границе
    /// слова). Отдельный флаг от autoSwitchEnabled (тот гейтит РУЧНОЙ триггер).
    /// Fresh installs wait for the onboarding choice; explicit preferences persist.
    var autoConvert: Bool {
        get { defaults.object(forKey: Keys.autoConvert) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Keys.autoConvert)
            if newValue { nativeAutoEnabled = true }
        }
    }

    /// An existing explicit auto-conversion choice remains effective after upgrading from
    /// builds without a separate native key. An explicit native opt-out still wins.
    var nativeAutoEnabled: Bool {
        get { defaults.object(forKey: Keys.nativeAutoEnabled) as? Bool ?? autoConvert }
        set { defaults.set(newValue, forKey: Keys.nativeAutoEnabled) }
    }

    /// issue #22 (вариант B): умная по-словная конверсия выделения — флипаем только слова не в
    /// той раскладке, а верный текст оставляем («iPhone стоит»). По умолчанию ВКЛ. Выключено —
    /// старое одностороннее поведение (всё выделение в одну сторону по текущей раскладке).
    var smartConversion: Bool {
        get { defaults.object(forKey: Keys.smartConversion) == nil ? true : defaults.bool(forKey: Keys.smartConversion) }
        set { defaults.set(newValue, forKey: Keys.smartConversion) }
    }

    /// issue #22 (вариант A): ручной триггер конвертирует ПО ТЕКСТУ — тотальный флип обеих
    /// письменностей (латиница↔кириллица) вместо направления по активной раскладке. Полезно
    /// для mixed-мусора, но переворачивает и намеренный второй язык. По умолчанию ВЫКЛ.
    /// Перебивает «Умную конверсию».
    var convertByText: Bool {
        get { defaults.bool(forKey: Keys.convertByText) }
        set { defaults.set(newValue, forKey: Keys.convertByText) }
    }

    /// issue #24: триггер конвертирует ВСЮ строку (от курсора до начала строки), а не только
    /// последнее слово — сам выделяет строку (без мыши) и прогоняет через умную конверсию.
    /// Удобно в терминале и когда набрал несколько слов не в той раскладке. По умолчанию ВЫКЛ.
    var convertWholeLine: Bool {
        get { defaults.bool(forKey: Keys.convertWholeLine) }
        set { defaults.set(newValue, forKey: Keys.convertWholeLine) }
    }

    /// issue #10: показывать флаг раскладки у текстовой каретки (бета). По умолчанию ВЫКЛ.
    /// issue #27: показывать неактивирующую подсказку, когда защищённый ввод ставит на паузу.
    /// По умолчанию включено; можно отключить тем, кому она мешает.
    var secureInputNoticeEnabled: Bool {
        get { defaults.object(forKey: Keys.secureInputNotice) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.secureInputNotice) }
    }

    /// Полностью скрыть иконку из меню-бара (запрос пользователя: «значок мозолит глаз»).
    /// По умолчанию ВЫКЛ. Путь назад — повторный запуск приложения: reopen-обработчик
    /// открывает Настройки (см. applicationShouldHandleReopen). Аварийный сброс:
    /// defaults delete com.alexfisenkov.macswitcher com.ruswitcher.hideMenuBarIcon
    var hideMenuBarIcon: Bool {
        get { defaults.bool(forKey: Keys.hideMenuBarIcon) }
        set { defaults.set(newValue, forKey: Keys.hideMenuBarIcon) }
    }

    var caretFlag: Bool {
        get { defaults.bool(forKey: Keys.caretFlag) }
        set { defaults.set(newValue, forKey: Keys.caretFlag) }
    }

    /// Режим работы через удалённый рабочий стол (Apple Screen Sharing и т.п.).
    /// При включении: tap поднимается на session-уровень (видит проброшенные
    /// нажатия), и инстанс «уступает удалёнке», если в фокусе клиент удалёнки.
    var remoteDesktopMode: Bool {
        get { defaults.bool(forKey: Keys.remoteDesktopMode) }
        set { defaults.set(newValue, forKey: Keys.remoteDesktopMode) }
    }

    /// Показывать ли тумблер «Режим удалённого стола» (видимая бета в 2.5). По умолчанию
    /// ВКЛючён; спрятать можно явно: `defaults write com.alexfisenkov.macswitcher com.ruswitcher.showRemoteDesktopBeta -bool NO`.
    var showRemoteDesktopBeta: Bool {
        get {
            // Нет записи в defaults → считаем включённым (дефолт ON для 2.5).
            if defaults.object(forKey: Keys.showRemoteDesktopBeta) == nil { return true }
            return defaults.bool(forKey: Keys.showRemoteDesktopBeta)
        }
        set { defaults.set(newValue, forKey: Keys.showRemoteDesktopBeta) }
    }

    /// Последняя версия, для которой показали окно «Что нового». Пусто = ещё не показывали.
    var lastWhatsNewVersion: String {
        get { defaults.string(forKey: Keys.lastWhatsNewVersion) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lastWhatsNewVersion) }
    }

    /// Последняя бета-версия, для которой показали окно «Что нового в бете» (отдельная
    /// витрина беты — текст берётся из notes бета-фида, не из локализованного whatsnew.body).
    var lastBetaNotesShown: String {
        get { defaults.string(forKey: Keys.lastBetaNotesShown) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lastBetaNotesShown) }
    }

    /// Предлагали ли уже автозамену при первом запуске (онбординг показывается один раз).
    var autoConvertOffered: Bool {
        get { defaults.bool(forKey: Keys.autoConvertOffered) }
        set { defaults.set(newValue, forKey: Keys.autoConvertOffered) }
    }

    /// issue #7: звук раскладки на первой букве после смены раскладки. По умолчанию OFF.
    var keySound: Bool {
        get { defaults.bool(forKey: Keys.keySound) }
        set { defaults.set(newValue, forKey: Keys.keySound) }
    }

    /// Иконка меню-бара в системном стиле: монохромная плашка «РУ/EN» (template)
    /// вместо цветного флага-эмодзи. По умолчанию OFF — флаг привычнее.
    var monochromeIcon: Bool {
        get { defaults.bool(forKey: Keys.monochromeIcon) }
        set { defaults.set(newValue, forKey: Keys.monochromeIcon) }
    }

    /// Only explicit user additions block automatic conversion. The old removed-key
    /// delta remains on disk for compatibility but never promotes factory defaults.
    var deniedApps: [String] {
        get {
            var seen: Set<String> = []
            return (defaults.stringArray(forKey: Keys.deniedAppsAdded) ?? [])
                .filter { seen.insert($0).inserted }
        }
        set {
            var seen: Set<String> = []
            defaults.set(newValue.filter { seen.insert($0).inserted }, forKey: Keys.deniedAppsAdded)
        }
    }

    /// Слова, которые авто-конверсия никогда не трогает.
    var deniedWords: [String] {
        get { defaults.stringArray(forKey: Keys.deniedWords) ?? [] }
        set { defaults.set(newValue, forKey: Keys.deniedWords) }
    }
    var deniedWordsSet: Set<String> { Set(deniedWords.map { $0.lowercased() }) }

    /// Слова, которые авто-конверсия переключает всегда (даже если их нет в словаре).
    var alwaysConvertWords: [String] {
        get { defaults.stringArray(forKey: Keys.alwaysConvertWords) ?? [] }
        set { defaults.set(newValue, forKey: Keys.alwaysConvertWords) }
    }
    var alwaysConvertWordsSet: Set<String> { Set(alwaysConvertWords.map { $0.lowercased() }) }

    /// Funding remains hidden until an owner-controlled destination is configured.
    var donateURL: String { "" }
    var contactEmail: String { Self.contactEmail }

    static let githubOwner = "alexfisenkov"
    static let githubRepo = "MacSwitcher"
    static var githubURL: String { "https://github.com/\(githubOwner)/\(githubRepo)" }
    static var websiteURL: String { githubURL }

    /// Own project links only, with no analytics or upstream marketing destinations.
    static func websiteLink(_ page: String = "", source: String = "app", medium: String) -> URL? {
        URL(string: githubURL + (page.isEmpty ? "" : "/releases"))
    }

    static let contactEmail = ""
    static let telegramChatURL = ""
    static let developerTeamID = "5BABN9U6WS"
    static func releaseDMGURL(version: String) -> String {
        "\(githubURL)/releases/download/v\(version)/MacSwitcher-\(version).dmg"
    }

    // MARK: - Login Item

    private func doUpdateLoginItem(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                rslog("Login item registered")
            } else {
                try service.unregister()
                rslog("Login item unregistered")
            }
        } catch {
            rslog("Login item error: \(error)")
        }
    }

    /// Текущий статус автозапуска (может отличаться от настройки)
    var loginItemStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }
}
