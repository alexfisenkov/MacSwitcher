import AppKit
import CoreGraphics
import Foundation

/// Маркер для симулированных событий — KeyboardMonitor их игнорирует
let kRuSwitcherEventMarker: Int64 = 0x52555300

/// Одно нажатие в буфере конверсии. Для обычного локального ввода известен keyCode
/// (char == nil). Для ввода, проброшенного через удалённый стол, Apple Screen Sharing
/// шлёт keyCode 0 + сам символ — тогда char != nil, и конверсия идёт по символу,
/// а не по бесполезному keyCode 0 (именно keyCode 0 рождал «фффффф»).
struct TypedKey: Sendable {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
    var char: Character? = nil
}

/// A single immutable gesture handed off after its physical callback returns.
/// Reconfiguration or intervening input retires it before any AX work begins.
@MainActor
final class DeferredCombinedShiftConversion {
    private let request: CombinedShiftRequest
    private let fenceIdentity: ObjectIdentifier
    private let hostIdentity: ObjectIdentifier
    private var consumed = false

    init(request: CombinedShiftRequest, fenceIdentity: ObjectIdentifier,
         hostIdentity: ObjectIdentifier) {
        self.request = request
        self.fenceIdentity = fenceIdentity
        self.hostIdentity = hostIdentity
    }

    func deliver(currentFenceIdentity: ObjectIdentifier, currentHostIdentity: ObjectIdentifier?,
                 currentRevision: UInt64, transportAvailable: Bool,
                 onConversion: (CombinedShiftRequest) -> Void) {
        guard !consumed else { return }
        consumed = true
        guard transportAvailable, currentFenceIdentity == fenceIdentity,
              currentHostIdentity == hostIdentity else { return }
        guard request.inputRevision == currentRevision else {
            RuntimeDiagnostics.record(.doubleRevisionChanged)
            return
        }
        onConversion(request)
    }
}

/// Выделенная очередь для файлового I/O лога — чтобы запись на диск не блокировала
/// поток обработки событий (event tap висит на главном run loop, а лог пишется
/// для каждого нажатия при включённом debug).
private let rsLogQueue = DispatchQueue(label: "com.ruswitcher.log")

func rslog(_ msg: String) {
    // Thread-safe: читаем UserDefaults напрямую (без MainActor)
    guard UserDefaults.standard.bool(forKey: "com.ruswitcher.debugLog") else { return }

    let line = "\(Date()): \(msg)\n"
    rsLogQueue.async {
        let logDir = NSHomeDirectory() + "/Library/Logs/RuSwitcher"
        let path = logDir + "/ruswitcher.log"

        // Создаём директорию если нет
        if !FileManager.default.fileExists(atPath: logDir) {
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            // Ротация: если > 5MB — обрезаем
            if handle.offsetInFile > 5_000_000 {
                handle.truncateFile(atOffset: 0)
                handle.write("--- Log rotated ---\n".data(using: .utf8)!)
            }
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }
}

/// Конфигурация клавиши-триггера (читается из настроек, кэшируется в KeyboardMonitor).
struct TriggerConfig {
    enum Kind {
        case modifier(mask: CGEventFlags, left: UInt16, right: UInt16)
        /// Комбо из двух модификаторов (например ⌘+⇧). Детект по флагам: оба зажаты без
        /// посторонних → отпущены все без клавиш между. Сторона (left/right) не важна.
        case combo(CGEventFlags, CGEventFlags)
        case capsLock
    }
    let kind: Kind
    let rightOnly: Bool
    let doubleTap: Bool

    var isCapsLock: Bool { if case .capsLock = kind { return true } else { return false } }
    var isShift: Bool { if case .modifier(.maskShift, _, _) = kind { return true } else { return false } }

    static func current() -> TriggerConfig {
        let s = SettingsManager.shared
        return parse(key: s.triggerKey, rightOnly: s.triggerRightOnly, doubleTap: s.triggerDoubleTap)
    }

    /// issue #14: конфиг хоткея чистого переключения раскладки. nil — выключен.
    /// Совпадение с триггером конверсии игнорируем (иначе один тап делал бы оба действия).
    /// Белый список обязателен: parse() маппит неизвестные строки в Option — рукописный
    /// мусор в defaults дублировал бы дефолтный триггер (ревью-находка).
    static func switchHotkey() -> TriggerConfig? {
        let known: Set<String> = ["option", "command", "control", "shift",
                                  "command+shift", "control+shift", "command+option", "control+option",
                                  "option+shift"]
        let s = SettingsManager.shared
        let key = s.switchHotkey
        guard known.contains(key), key != s.triggerKey else { return nil }
        return parse(key: key, rightOnly: s.switchRightOnly, doubleTap: s.switchDoubleTap)
    }

    /// issue #29: конфиг хоткея смены регистра (nil — выключен). Должен отличаться и от триггера
    /// конверсии, и от хоткея смены раскладки — иначе один тап делал бы два действия.
    static func caseHotkey() -> TriggerConfig? {
        let known: Set<String> = ["option", "command", "control", "shift",
                                  "command+shift", "control+shift", "command+option", "control+option",
                                  "option+shift"]
        let s = SettingsManager.shared
        let key = s.caseHotkey
        guard known.contains(key), key != s.triggerKey, key != s.switchHotkey else { return nil }
        return parse(key: key, rightOnly: s.caseRightOnly, doubleTap: s.caseDoubleTap)
    }

    static func parse(key: String, rightOnly: Bool, doubleTap: Bool) -> TriggerConfig {
        let kind: Kind
        switch key {
        case "command": kind = .modifier(mask: .maskCommand, left: KC.leftCommand, right: KC.rightCommand)
        case "control": kind = .modifier(mask: .maskControl, left: KC.leftControl, right: KC.rightControl)
        case "shift":   kind = .modifier(mask: .maskShift,   left: KC.leftShift,   right: KC.rightShift)
        // Комбо двух модификаторов (issue #12: привычный по Windows стиль Alt+Shift и т.п.).
        case "command+shift":  kind = .combo(.maskCommand, .maskShift)
        case "control+shift":  kind = .combo(.maskControl, .maskShift)
        case "command+option": kind = .combo(.maskCommand, .maskAlternate)
        case "control+option": kind = .combo(.maskControl, .maskAlternate)
        // discussion #32: ⌥+⇧ — виндовый дефолт; тап-детект комбо (любой keyDown между
        // нажатием и отпусканием сбрасывает взвод) исключает конфликт с ⌥⇧+буква/стрелки.
        case "option+shift":   kind = .combo(.maskAlternate, .maskShift)
        // ТЕХДОЛГ: нативный Caps Lock убран из UI (нестабилен — HID-дебаунс/тоггл,
        // нужен HID-драйвер уровня Karabiner). Код consume-пути оставлен на будущее.
        case "capsLock": kind = .capsLock
        default:        kind = .modifier(mask: .maskAlternate, left: KC.leftOption, right: KC.rightOption)
        }
        return TriggerConfig(kind: kind, rightOnly: rightOnly, doubleTap: doubleTap)
    }
}

final class KeyboardMonitor: @unchecked Sendable {
    private static let maximumHistoryKeys = 512
    fileprivate var eventTap: CFMachPort?
    private var eventTapHost: KeyboardEventTapHost?
    fileprivate var inputFence = InputEventFence()
    private var sourceTransitions = InputSourceTransitionTracker()
    private var nativeTransactionStart: (lease: InputEventFence.Lease, timestamp: UInt64)?
    fileprivate var pendingCombinedShiftConversion: CombinedShiftRequest?
    private var combinedFocusObserver: NSObjectProtocol?

    /// Длина текущего набираемого слова
    private(set) var currentWordLength = 0
    /// Длина слова до последнего пробела
    private(set) var wordBeforeBoundaryLength = 0
    /// Сколько пробелов после слова (только пробелы, не enter/стрелки)
    private(set) var boundaryCount = 0
    /// Были ли реальные нажатия после последней конвертации?
    private(set) var keysTypedSinceConversion = true

    /// Нажатия набираемого слова — для движка перепечатки (без буфера обмена)
    private(set) var currentWordKeys: [TypedKey] = []
    /// Нажатия слова перед последней границей-пробелом
    private(set) var prevWordKeys: [TypedKey] = []
    /// issue #24: буфер ВСЕЙ строки (буквы + пробелы-сентинелы char==" ") для перепечатки строки
    /// в терминале, где нет OS-выделения. Любая пунктуация/структурная клавиша/сдвиг курсора
    /// (fullReset) очищает буфер → тогда «вся строка» откатывается на последнее слово.
    private(set) var lineKeys: [TypedKey] = []
    private var wordHistoryOverflowed = false
    private var lineHistoryOverflowed = false
    /// Фронтмост-приложение на момент границы слова — чтобы авто-путь не перепечатал
    /// в другое поле, если фокус уехал (Cmd-Tab/Spotlight) без клика/Tab.
    private(set) var prevWordBundleID: String?
    /// issue #7: взводится при смене раскладки → на первой букве играем звук раскладки.
    var soundArmed = false

    private var onAltTap: (() -> Void)?
    private var onAltReconvert: (() -> Void)?
    /// Native mode owns BOTH Shift gestures; the vendor conversion/switch handlers never compete.
    var onCombinedShift: (@MainActor (CombinedShiftRequest) -> Void)?
    private var combinedShiftEnabled = SettingsManager.shared.combinedShiftEnabled
    private var combinedShiftGesture = CombinedShiftGesture()
    private var combinedShiftProcessID: Int32?
    private var combinedShiftFirstRequest: CombinedShiftRequest?
    private var combinedShiftFirstSoloAt: UInt64?
    private var combinedShiftDoubleWindowNanoseconds = CombinedShiftGesture.Configuration
        .defaultDoubleWindowNanoseconds
    /// T02 supplies its persisted preference here; the default recognizer still
    /// uses 180 ms until an explicit validated configuration is passed.
    @MainActor
    func configureCombinedShiftTiming(_ configuration: CombinedShiftGesture.Configuration) {
        interruptCombinedShift()
        combinedShiftGesture = CombinedShiftGesture(configuration: configuration)
        combinedShiftDoubleWindowNanoseconds = configuration.doubleWindowNanoseconds
    }
    private(set) var inputRevision: UInt64 = 0
    private var currentWordSourceID: String?
    private var prevWordSourceID: String?
    private var lineSourceID: String?
    private var predictionBuffer = PredictionInputBuffer()
    private var predictionSourceLayoutID: String?
    var predictionSessionID: UInt64 { predictionBuffer.sessionID }
    private(set) var predictionGeneration: UInt64 = 0
    private var nativeInputGateConfigured = false
    var nativeInputGateGeneration: UInt64 { inputFence.generation }
    var nativeInputTransportAvailable: Bool {
        nativeInputGateConfigured && inputFence.isAvailable
            && eventTap.map { CGEvent.tapIsEnabled(tap: $0) } == true
    }
    var nativeInputBarrierIsActive: Bool {
        nativeInputTransportAvailable && inputFence.hasActiveLease
    }
    var nativeFenceNeedsRecovery: Bool { eventTap != nil && !inputFence.isAvailable }

    @MainActor
    func makeDiagnosticFixtureEventProcessor() -> (@Sendable (CGEvent) -> Bool)? {
        guard diagnosticFixtureFlagsEnabled(), nativeInputTransportAvailable else { return nil }
        let fence = inputFence
        return { [weak self] event in
            guard !Thread.isMainThread, let self, diagnosticFixtureEventIsAdmitted(event) else { return false }
            return processKeyboardInput(type: event.type, event: event, monitor: self,
                                        fence: fence, diagnosticFixture: true) != nil
        }
    }
    func beginNativeInputTransaction(processID: Int32) -> InputEventFence.Lease? {
        guard nativeInputGateConfigured else {
            RuntimeDiagnostics.record(.fenceGateNotConfigured); return nil
        }
        guard let eventTap else {
            RuntimeDiagnostics.record(.fenceTapMissing); return nil
        }
        guard CGEvent.tapIsEnabled(tap: eventTap) else {
            RuntimeDiagnostics.record(.fenceTapDisabled); return nil
        }
        guard inputFence.isAvailable else {
            RuntimeDiagnostics.record(.fenceInterrupted); return nil
        }
        guard !sourceTransitions.hasPending else {
            RuntimeDiagnostics.record(.fencePendingSource); return nil
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard let lease = inputFence.begin(processID: processID, maximumDuration: 0.250) else {
            RuntimeDiagnostics.record(.fenceBusy); return nil
        }
        nativeTransactionStart = (lease, startedAt)
        return lease
    }
    func finishNativeInputTransaction(_ lease: InputEventFence.Lease, replayLayoutID: String?) {
        if let start = nativeTransactionStart, start.lease == lease {
            sourceTransitions.recordCompletedWindow(start: start.timestamp,
                end: DispatchTime.now().uptimeNanoseconds)
            nativeTransactionStart = nil
        }
        inputFence.finish(lease, replayLayoutID: replayLayoutID)
    }
    func noteUnconfirmedInputSource(_ targetID: String, requestedAt: UInt64) {
        sourceTransitions.noteUnconfirmed(targetID: targetID, startingAt: requestedAt)
    }
    var hasPendingInputSourceTransition: Bool { sourceTransitions.hasPending }
    var pendingInputSourceTargetID: String? { sourceTransitions.pendingTargetID }
    func requireObservedInputSource(_ targetID: String) {
        sourceTransitions.requireObserved(targetID: targetID, startingAt: DispatchTime.now().uptimeNanoseconds)
    }
    /// The caller must supply a fresh observed TIS source, never a requested ID.
    func recordObservedInputSource(_ sourceID: String) {
        sourceTransitions.observe(sourceID: sourceID, at: DispatchTime.now().uptimeNanoseconds)
    }
    /// Call after an explicit source choice and a fresh observed TIS read.
    @discardableResult
    func recordExplicitInputSourceSelection(targetID: String, observedSourceID: String) -> Bool {
        sourceTransitions.confirmExplicitSelection(targetID: targetID, observedSourceID: observedSourceID,
            at: DispatchTime.now().uptimeNanoseconds)
    }
    fileprivate func inputSourceNeedsRefresh(eventTimestamp: UInt64) -> Bool {
        sourceTransitions.needsRefresh(eventTimestamp: eventTimestamp)
    }
    fileprivate func observeInputSource(_ sourceID: String) {
        sourceTransitions.observe(sourceID: sourceID, at: DispatchTime.now().uptimeNanoseconds)
    }
    func nativeInputTransactionIsCurrent(_ lease: InputEventFence.Lease) -> Bool {
        nativeInputTransportAvailable && inputFence.isCurrent(lease)
    }
    func nativeInputTransactionRemainingDuration(_ lease: InputEventFence.Lease) -> TimeInterval? {
        guard nativeInputTransportAvailable else { return nil }
        return inputFence.remainingDuration(lease)
    }
    var onPredictionInput: (@MainActor (PredictionSnapshot) -> Void)?
    var onPredictionInvalidated: (@MainActor () -> Void)?
    /// issue #10: любой ввод/клик пользователя — чтобы спрятать флаг у каретки во время печати.
    var onUserInput: (() -> Void)?
    /// issue #10: включена ли фича флага-у-каретки. Гейтит диспатч onUserInput на горячем пути,
    /// чтобы при выключенной фиче (по умолчанию) не будить main-очередь на каждом нажатии.
    var caretFlagEnabled = false

    // Конфиг триггера (кэш; обновляется в start/reconfigure)
    private var triggerConfig = TriggerConfig.current()
    /// issue #14: второй хоткей — чистое переключение раскладки (nil = выключен).
    private var switchConfig = TriggerConfig.switchHotkey()
    private var switchArmed = false
    private var switchPressTime: Date?
    private var switchLastTapTime: Date?   // для double-tap хоткея смены
    /// Колбэк чистого переключения раскладки (issue #14). Ставится из AppDelegate.
    var onSwitchHotkey: (() -> Void)?
    /// issue #29: третий хоткей — смена регистра (nil = выключен).
    private var caseConfig = TriggerConfig.caseHotkey()
    private var caseArmed = false
    private var casePressTime: Date?
    private var caseLastTapTime: Date?
    /// Колбэк смены регистра (issue #29). Ставится из AppDelegate.
    var onCaseHotkey: (() -> Void)?

    // Детект соло-тапа модификатора
    private var triggerArmed = false
    private var triggerPressTime: Date?
    // Для двойного тапа
    private var lastTapTime: Date?
    private let tapWindow: TimeInterval = 0.4
    // issue #21: окно «тапа» для КОМБО из двух модификаторов. Намеренно большое: аккорд
    // из двух клавиш держат заметно дольше флика одной (0.4с было слишком узко). Но верхний
    // потолок оставлен — иначе комбо срабатывало бы и на «случайное» долгое удержание
    // модификаторов во время скролла/жеста (эти события не сбрасывают armed — их нет в маске
    // event tap'а). 2с покрывает любой намеренный тап и отсекает попутные удержания.
    private let comboTapWindow: TimeInterval = 2.0

    func start(
        onAltTap: @escaping () -> Void,
        onAltReconvert: @escaping () -> Void
    ) -> Bool {
        if eventTapHost != nil || eventTap != nil { stop() }
        self.onAltTap = onAltTap
        self.onAltReconvert = onAltReconvert

        let precheck = CGPreflightListenEventAccess()
        rslog("Preflight check = \(precheck)")
        if !precheck {
            rslog("Requesting access...")
            CGRequestListenEventAccess()
        }

        triggerConfig = TriggerConfig.current()
        switchConfig = TriggerConfig.switchHotkey()
        caseConfig = TriggerConfig.caseHotkey()   // issue #29
        combinedShiftEnabled = SettingsManager.shared.combinedShiftEnabled
        combinedShiftGesture.interrupt()
        if combinedShiftEnabled { fullReset(); keysTypedSinceConversion = true }
        rslog("Attempting to create event tap... (trigger=\(SettingsManager.shared.triggerKey) switch=\(SettingsManager.shared.switchHotkey.isEmpty ? "off" : SettingsManager.shared.switchHotkey) capsLock=\(triggerConfig.isCapsLock))")
        // Explicit element and integer types keep Swift 6.0's solver bounded.
        let observedEvents: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel
        ]
        let mask = observedEvents.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }

        // A native transaction holds complete keyboard/mouse pairs on the
        // independent tap runloop while the target confirms each edit step.
        let wantsNativeGate = CommandLine.arguments.contains("--diagnostic-native-canary")
            && CommandLine.arguments.contains("--diagnostic-panel")
        let options: CGEventTapOptions = triggerConfig.isCapsLock || wantsNativeGate || combinedShiftEnabled
            || SettingsManager.shared.autoConvert ? .defaultTap : .listenOnly

        // Режим удалённого стола: session-уровень видит проброшенные Screen Sharing
        // нажатия (они инжектятся через CGEventPost, а HID-tap их не видит).
        let tapLocation: CGEventTapLocation =
            SettingsManager.shared.remoteDesktopMode ? .cgSessionEventTap : .cghidEventTap
        rslog("Tap location: \(SettingsManager.shared.remoteDesktopMode ? "session (remote desktop)" : "hid")")

        inputFence = InputEventFence()
        let fence = inputFence
        guard let host = KeyboardEventTapHost.start(location: tapLocation, options: options, mask: mask,
            handler: { [weak self] _, type, event in
                guard let self else { return Unmanaged.passUnretained(event) }
                return keyboardCallback(type: type, event: event, monitor: self, fence: fence)
            }) else {
            rslog("FAILED to create event tap - no permission")
            return false
        }

        eventTapHost = host
        eventTap = host.tap
        nativeInputGateConfigured = options == .defaultTap

        combinedFocusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resetBuffersOnClick() }

        rslog("Event tap created and enabled successfully")
        return true
    }

    func stop() {
        nativeInputGateConfigured = false
        inputFence.interrupt()
        interruptCombinedShift()
        predictionBuffer.reset()
        predictionSourceLayoutID = nil
        if let observer = combinedFocusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            combinedFocusObserver = nil
        }
        eventTapHost?.stop()
        eventTapHost = nil
        eventTap = nil
    }

    fileprivate func nativeGateWasInterrupted() {
        inputFence.interrupt()
        interruptCombinedShift()
        resetPredictionContext()
    }

    /// Перезапускает tap с актуальным конфигом триггера. Нужен при смене настройки —
    /// особенно при переключении на/с Caps Lock, т.к. меняется режим tap (consume).
    @discardableResult
    func reconfigure() -> Bool {
        guard let t = onAltTap, let r = onAltReconvert else { return false }
        rslog("Reconfiguring trigger…")
        stop()
        return start(onAltTap: t, onAltReconvert: r)
    }

    func markConverted() {
        interruptCombinedShift()
        predictionBuffer.reset()
        predictionSourceLayoutID = nil
        currentWordLength = 0
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
        currentWordKeys = []
        prevWordKeys = []
        lineKeys = []
        wordHistoryOverflowed = false
        lineHistoryOverflowed = false
        keysTypedSinceConversion = false
        currentWordSourceID = nil
        prevWordSourceID = nil
        lineSourceID = nil
    }

    /// A native editor has read back the exact whole field after a manual edit.
    /// Seed the next physical key from that confirmed caret prefix, so typing a
    /// suffix continues this word rather than starting a new one. No AX read is
    /// performed here and an unknown edit never reaches this method.
    func adoptConfirmedManualField(_ field: TextConverter.ConfirmedNativeField,
                                   resultLayoutID: String) {
        let pid = field.focus.processID
        guard pid > 0, field.after.selectionLength == 0,
              let beforeRange = Range(NSRange(location: 0,
                    length: field.before.caretUTF16Location), in: field.before.text),
              let afterRange = Range(NSRange(location: 0,
                    length: field.after.caretUTF16Location), in: field.after.text) else {
            markConverted(); return
        }
        let beforePrefix = String(field.before.text[beforeRange])
        let afterPrefix = String(field.after.text[afterRange])
        let originalEndPrefix = field.before.selectionLength > 0
            ? beforePrefix + field.original : beforePrefix
        guard originalEndPrefix.hasSuffix(field.original), afterPrefix.hasSuffix(field.replacement),
              !afterPrefix.isEmpty else { markConverted(); return }
        interruptCombinedShift()
        if field.before.selectionLength > 0
            || predictionBuffer.processID != pid
            || !originalEndPrefix.hasSuffix(predictionBuffer.text)
            || !predictionBuffer.replaceSuffix(original: field.original,
                replacement: field.replacement) {
            predictionBuffer.reset()
            predictionBuffer.append(afterPrefix, processID: pid)
        }
        predictionSourceLayoutID = resultLayoutID
        let trailingSpaces = afterPrefix.reversed().prefix(while: \.isWhitespace).count
        let last = afterPrefix.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let keys = last.map { TypedKey(keyCode: 0, shift: $0.isUppercase, caps: false, char: $0) }
        wordHistoryOverflowed = trailingSpaces == 0 && keys.count > Self.maximumHistoryKeys
        currentWordKeys = trailingSpaces == 0 && !wordHistoryOverflowed ? keys : []
        currentWordLength = currentWordKeys.count
        currentWordSourceID = currentWordKeys.isEmpty ? nil : resultLayoutID
        prevWordKeys = trailingSpaces > 0 && keys.count <= Self.maximumHistoryKeys ? keys : []
        wordBeforeBoundaryLength = prevWordKeys.count
        prevWordSourceID = prevWordKeys.isEmpty ? nil : resultLayoutID
        boundaryCount = trailingSpaces
        lineKeys = []
        lineHistoryOverflowed = true // The confirmed field prefix is not a typed line history.
        lineSourceID = nil
        keysTypedSinceConversion = false
    }

    /// issue #24 / скептик 3.2.0: системная смена раскладки (globe / Ctrl-Space) не проходит через
    /// наш обработчик клавиш, поэтому буфер строки декодировался бы старой раскладкой. Сбрасываем
    /// его (только строку — словный буфер трогаем как раньше).
    func resetLineBuffer(sourceLayoutID: String = LayoutSwitcher.currentLayoutID()) {
        observeInputSource(sourceLayoutID)
        lineHistoryOverflowed = lineHistoryOverflowed || wordHistoryOverflowed || !lineKeys.isEmpty
        lineKeys = []
        lineSourceID = nil
        if let first = combinedShiftFirstRequest,
           case .switchLayout(let direction) = first.action,
           let firstSoloAt = combinedShiftFirstSoloAt,
           first.inputRevision == inputRevision,
           first.frontProcessID == predictionBuffer.processID,
           predictionSourceLayoutID == direction.sourceLayoutID,
           sourceLayoutID == direction.targetLayoutID {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= firstSoloAt, now - firstSoloAt <= combinedShiftDoubleWindowNanoseconds {
                RuntimeDiagnostics.record(.sourceNotificationPreserved)
                return
            }
        }
        // TIS delivers source-change notifications after the source is already
        // selectable. Fast typing may have started under that source before its
        // acknowledgement arrives; it must not cancel that new pending snapshot.
        guard !sourceLayoutID.isEmpty, !predictionBuffer.text.isEmpty,
              predictionSourceLayoutID == sourceLayoutID else {
            RuntimeDiagnostics.record(.sourceNotificationInvalidated)
            resetPredictionContext()
            return
        }
        RuntimeDiagnostics.record(.sourceNotificationPreserved)
    }

    private func fullReset() {
        predictionBuffer.reset()
        predictionSourceLayoutID = nil
        invalidatePrediction()
        currentWordLength = 0
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
        currentWordKeys = []
        prevWordKeys = []
        lineKeys = []
        wordHistoryOverflowed = false
        lineHistoryOverflowed = false
        currentWordSourceID = nil
        prevWordSourceID = nil
        lineSourceID = nil
    }

    private func invalidatePrediction() {
        predictionGeneration &+= 1
        MainActor.assumeIsolated { onPredictionInvalidated?() }
    }

    func resetPredictionContext() {
        predictionBuffer.reset()
        predictionSourceLayoutID = nil
        invalidatePrediction()
    }

    /// Dictionary/scoring stay off the tap. The first event of a new session
    /// performs one bounded original-field capture before deferred prediction.
    private func recordPredictionKey(keyCode: UInt16, flags: CGEventFlags, renderedText: String?,
                                     renderedSourceLayoutID: String?) {
        if SettingsManager.shared.autoSwitchEnabled, SettingsManager.shared.autoConvert,
           !AutoSwitchPolicy.secureInputActive,
           flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty,
           keyCode != KC.backspace, keyCode != KC.enter, keyCode != KC.tab,
           !(keyCode >= KC.left && keyCode <= KC.up) {
            RuntimeDiagnostics.record(.autoInputEligible)
            RuntimeDiagnostics.record(renderedText?.isEmpty == false ? .autoUnicodePresent : .autoUnicodeMissing)
        }
        guard SettingsManager.shared.autoSwitchEnabled, SettingsManager.shared.autoConvert,
              !AutoSwitchPolicy.secureInputActive,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty,
              keyCode != KC.backspace, keyCode != KC.enter, keyCode != KC.tab,
              !(keyCode >= KC.left && keyCode <= KC.up),
              let renderedText, !renderedText.isEmpty,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            predictionBuffer.reset(); predictionSourceLayoutID = nil; return
        }
        recordPredictionText(renderedText, processID: pid,
            sourceLayoutID: renderedSourceLayoutID ?? LayoutSwitcher.currentLayoutID())
    }

    /// Shared input boundary: receives the actual event text and its observed
    /// source identity. Keeping this boundary independent of HID/AX lets delivery
    /// ordering regressions exercise the monitor's real buffering and callbacks.
    func recordPredictionText(_ text: String, processID: Int32, sourceLayoutID: String) {
        guard !sourceLayoutID.isEmpty else { resetPredictionContext(); return }
        // The first character can beat the system notification too. Do not
        // attach it to text from a different, manually selected source.
        if let previous = predictionSourceLayoutID, previous != sourceLayoutID {
            resetPredictionContext()
        }
        predictionSourceLayoutID = nil
        predictionBuffer.append(text, processID: processID)
        guard let snapshot = predictionBuffer.snapshot(sourceLayoutID: sourceLayoutID,
            inputRevision: inputRevision, generation: predictionGeneration) else { return }
        predictionSourceLayoutID = sourceLayoutID
        RuntimeDiagnostics.record(.autoSnapshotSubmitted)
        MainActor.assumeIsolated { onPredictionInput?(snapshot) }
    }

    /// Synthetic events are ignored by the tap, so explicitly adopt the verified
    /// result. The manual double-Shift path can immediately undo it or convert the
    /// following word using the actual result's source identity.
    func recordPredictionResult(original: String, replacement: String, resultLayoutID: String) {
        interruptCombinedShift()
        guard predictionBuffer.replaceSuffix(original: original, replacement: replacement) else {
            fullReset(); keysTypedSinceConversion = false; return
        }
        predictionSourceLayoutID = resultLayoutID
        let text = predictionBuffer.text
        let trailingSpaces = text.reversed().prefix(while: { $0 == " " }).count
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let last = tokens.last.map(String.init) ?? ""
        let keys = last.map { TypedKey(keyCode: 0, shift: $0.isUppercase, caps: false, char: $0) }
        currentWordKeys = trailingSpaces == 0 ? keys : []
        currentWordLength = currentWordKeys.count
        currentWordSourceID = currentWordKeys.isEmpty ? nil : resultLayoutID
        prevWordKeys = trailingSpaces > 0 ? keys : []
        wordBeforeBoundaryLength = prevWordKeys.count
        prevWordSourceID = prevWordKeys.isEmpty ? nil : resultLayoutID
        boundaryCount = trailingSpaces
        lineKeys = []  // a mixed-language predictive window is not a reliable line mapping
        wordHistoryOverflowed = false
        lineHistoryOverflowed = true
        lineSourceID = nil
        keysTypedSinceConversion = false
    }

    /// Developer fixture only: the operator prepares this exact synthetic prefix
    /// in TextEdit. The fixture never renders text itself or accepts arbitrary input.
    func diagnosticReplayTextEditPrefix() -> Bool {
        guard CommandLine.arguments.contains("--diagnostic-panel"),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit",
              LayoutSwitcher.currentLayoutID() == "com.apple.keylayout.US" else { return false }
        handleKeyDown(keyCode: 5, flags: [], renderedText: "ghbd")
        return true
    }

    /// Сброс буфера при клике мышью — иначе backspace перепечатки сотрёт не то
    /// (курсор мог уехать в другое место).
    fileprivate func resetBuffersOnClick() {
        interruptCombinedShift()
        triggerArmed = false
        switchArmed = false
        caseArmed = false; caseLastTapTime = nil   // issue #29
        lastTapTime = nil
        switchLastTapTime = nil
        keysTypedSinceConversion = true
        if caretFlagEnabled { DispatchQueue.main.async { [weak self] in self?.onUserInput?() } }   // issue #10: клик прячет флаг у каретки
        fullReset()
    }

    // MARK: - Event Handling

    /// Cancellation is also used for scrolling, tap recovery, pause/resume, and stale focus.
    fileprivate func interruptCombinedShift() {
        clearCombinedShiftCandidate()
        invalidatePrediction()
        inputRevision &+= 1
    }

    private func clearCombinedShiftCandidate() {
        pendingCombinedShiftConversion = nil
        combinedShiftGesture.interrupt()
        combinedShiftProcessID = nil
        combinedShiftFirstRequest = nil
        combinedShiftFirstSoloAt = nil
    }

    /// A successful held callback starts a fresh gesture; an interrupted lease
    /// cannot start one from compressed delivery.
    func allowCombinedShift(after admission: InputEventFence.Admission) -> Bool {
        if admission.interrupted { interruptCombinedShift() }
        else if admission.wasHeld { clearCombinedShiftCandidate() }
        return !admission.interrupted
    }

    /// Production gesture state transition, shared by the tap callback and its
    /// raw-CGEvent regression tests. Context is captured only on a press.
    func recognizeCombinedShift(side: CombinedShiftGesture.Side, isPressed: Bool,
                                clock: KeyboardInputClock, context: CombinedShiftContext? = nil)
        -> CombinedShiftGesture.Action? {
        if isPressed {
            guard let context else { combinedShiftGesture.interrupt(); return nil }
            combinedShiftGesture.press(side, clock: clock, context: context)
            return nil
        }
        return combinedShiftGesture.release(side, clock: clock)
    }

    func resetCombinedShift() {
        guard combinedShiftEnabled else { return }
        interruptCombinedShift()
        fullReset()
        keysTypedSinceConversion = true
    }

    private func rememberTypedSource(_ renderedSourceLayoutID: String?) {
        let id = renderedSourceLayoutID ?? LayoutSwitcher.currentLayoutID()
        if currentWordLength == 0 { currentWordSourceID = id }
        else if currentWordSourceID != id { currentWordSourceID = nil }  // mixed-source word is unsafe to retype
        if lineKeys.isEmpty { lineSourceID = id }
        else if lineSourceID != id { lineSourceID = nil }
    }

    private func appendHistoryKey(_ key: TypedKey) {
        if !wordHistoryOverflowed {
            if currentWordKeys.count < Self.maximumHistoryKeys {
                currentWordKeys.append(key)
                currentWordLength += 1
            } else {
                currentWordKeys = []
                currentWordLength = 0
                currentWordSourceID = nil
                wordHistoryOverflowed = true
            }
        }
        if !lineHistoryOverflowed {
            if lineKeys.count < Self.maximumHistoryKeys {
                lineKeys.append(key)
            } else {
                lineKeys = []
                lineSourceID = nil
                lineHistoryOverflowed = true
            }
        }
    }

    private func appendHistorySpace() {
        guard !lineHistoryOverflowed, !lineKeys.isEmpty else { return }
        if lineKeys.count < Self.maximumHistoryKeys {
            lineKeys.append(TypedKey(keyCode: KC.space, shift: false, caps: false, char: " "))
        } else {
            lineKeys = []
            lineSourceID = nil
            lineHistoryOverflowed = true
        }
    }

    private func handleCombinedShift(flags: CGEventFlags, keyCode: UInt16, clock: KeyboardInputClock) {
        let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        guard SettingsManager.shared.autoSwitchEnabled, !AutoSwitchPolicy.secureInputActive,
              flags.intersection(otherModifiers).isEmpty,
              keyCode == KC.leftShift || keyCode == KC.rightShift else {
            interruptCombinedShift()
            return
        }
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier, frontPID > 0 else {
            interruptCombinedShift()
            return
        }
        if let priorPID = combinedShiftProcessID, priorPID != frontPID { interruptCombinedShift() }
        combinedShiftProcessID = frontPID
        let side: CombinedShiftGesture.Side = keyCode == KC.leftShift ? .left : .right
        if flags.contains(.maskShift) {
            guard let context = LayoutSwitcher.combinedShiftContext() else { interruptCombinedShift(); return }
            _ = recognizeCombinedShift(side: side, isPressed: true, clock: clock, context: context)
            return
        }
        guard let action = recognizeCombinedShift(side: side, isPressed: false, clock: clock) else { return }
        let focus: CombinedShiftFocus?
        if case .switchLayout = action {
            // Only a qualified first solo reads AX, before its layout flip. Uppercase,
            // shortcuts, held Shift and the second tap perform no AX capture here.
            focus = CombinedShiftFocus.capture(processID: frontPID)
        } else {
            focus = nil
        }
        guard let request = snapshotCombinedShiftRequest(action: action, frontProcessID: frontPID,
            focus: focus, contextForSource: { LayoutSwitcher.combinedShiftContext(sourceLayoutID: $0) }) else { return }
        if case .switchLayout = action {
            // Event handling is synchronously handed to main. Deliver the solo
            // before another character can advance revision and swallow it.
            MainActor.assumeIsolated { onCombinedShift?(request) }
            return
        }
        // Correction validates the immutable first-tap field/revision again at its first edit.
        // Retire this non-text release's forwarding reservation before starting
        // conversion, and handle it before the tap thread admits another event.
        // The OS-owned release returns after the synchronous conversion handoff.
        pendingCombinedShiftConversion = request
    }

    /// Captures the production manual-conversion snapshot after a Shift action.
    /// The resolver is injectable so tests can use real installed source IDs without
    /// selecting a TIS source or querying an accessibility field.
    func snapshotCombinedShiftRequest(action: CombinedShiftGesture.Action, frontProcessID: Int32,
        focus: CombinedShiftFocus?, contextForSource: (String) -> CombinedShiftContext?) -> CombinedShiftRequest? {
        let gestureContext: CombinedShiftContext
        switch action {
        case .switchLayout(let context), .convert(let context): gestureContext = context
        }
        let typedSourceID = !currentWordKeys.isEmpty ? currentWordSourceID
            : (!prevWordKeys.isEmpty && boundaryCount > 0 ? prevWordSourceID : gestureContext.sourceLayoutID)
        var request = CombinedShiftRequest(
            action: action,
            wordContext: typedSourceID.flatMap(contextForSource),
            wordKeys: currentWordKeys, prevWordKeys: prevWordKeys, lineKeys: lineKeys,
            lineSourceLayoutID: lineSourceID, boundaryCount: boundaryCount,
            reconvert: !keysTypedSinceConversion, inputRevision: inputRevision, frontProcessID: frontProcessID,
            focus: focus)
        if case .convert = action {
            RuntimeDiagnostics.record(.doubleRecognized)
            guard let first = combinedShiftFirstRequest, first.inputRevision == inputRevision else {
                RuntimeDiagnostics.record(.doubleFirstSnapshotUnavailable); return nil
            }
            request = CombinedShiftRequest(action: action, wordContext: first.wordContext,
                wordKeys: first.wordKeys, prevWordKeys: first.prevWordKeys, lineKeys: first.lineKeys,
                lineSourceLayoutID: first.lineSourceLayoutID, boundaryCount: first.boundaryCount,
                reconvert: first.reconvert, inputRevision: inputRevision, frontProcessID: frontProcessID, focus: first.focus)
            combinedShiftFirstRequest = nil
            combinedShiftFirstSoloAt = nil
        } else {
            combinedShiftFirstRequest = request
            combinedShiftFirstSoloAt = DispatchTime.now().uptimeNanoseconds
        }
        return request
    }

    @MainActor
    fileprivate func schedulePendingCombinedShiftConversion(after fence: InputEventFence) {
        guard inputFence === fence, let request = pendingCombinedShiftConversion,
              let host = eventTapHost else { return }
        pendingCombinedShiftConversion = nil
        let captured = DeferredCombinedShiftConversion(request: request,
            fenceIdentity: ObjectIdentifier(fence), hostIdentity: ObjectIdentifier(host))
        // The tap callback still owns the physical ShiftUp. Schedule on that
        // same run loop so the conversion cannot start until it returns.
        _ = host.performAfterCurrentCallback { [weak self, weak host] in
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, host != nil else { return }
                captured.deliver(currentFenceIdentity: ObjectIdentifier(self.inputFence),
                    currentHostIdentity: self.eventTapHost.map(ObjectIdentifier.init),
                    currentRevision: self.inputRevision,
                    transportAvailable: self.nativeInputTransportAvailable) { request in
                    self.onCombinedShift?(request)
                }
            }
        }
    }

    func handleKeyDown(keyCode: UInt16, flags: CGEventFlags, char: Character? = nil,
                       renderedText: String? = nil, renderedSourceLayoutID: String? = nil) {
        interruptCombinedShift()
        // Submit after existing buffer mutation. Structural/reset branches clear it.
        defer { recordPredictionKey(keyCode: keyCode, flags: flags, renderedText: renderedText,
            renderedSourceLayoutID: renderedSourceLayoutID) }
        triggerArmed = false
        switchArmed = false   // issue #14: клавиша между модификаторами = шорткат, не хоткей
        caseArmed = false; caseLastTapTime = nil   // issue #29
        lastTapTime = nil
        switchLastTapTime = nil
        keysTypedSinceConversion = true
        if caretFlagEnabled { DispatchQueue.main.async { [weak self] in self?.onUserInput?() } }   // issue #10: спрятать флаг при печати

        // Удалёнка: Screen Sharing шлёт проброшенные символы как keyCode 0 + юникод. Перехватываем
        // ТОЛЬКО в режиме удалённого стола. КРИТИЧНО: локально keyCode 0 — это обычная клавиша
        // 'a' (и 'ф' в ЙЦУКЕН), её нельзя глотать, иначе ломается локальная конверсия слов с
        // этими буквами. В локальном режиме сюда не заходим — буква идёт обычным путём ниже.
        if SettingsManager.shared.remoteDesktopMode, keyCode == 0 {
            // ⌘A/⌘C/⌘X и т.п. по удалёнке прилетают как символ 'a' (keyCode 0) с флагом Cmd.
            // НЕ копим их в буфер: иначе ⌘A добавляет лишнюю «ф» (keyCode 0 = 'ф' в ЙЦУКЕН)
            // и рушит выделение. Сбрасываем буфер — триггер уйдёт по clipboard-пути (выделение).
            // Локальный аналог этого guard — ниже, на ветке модификаторов (PR #13).
            let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
            if !modifiers.isEmpty { fullReset(); return }
            if let ch = char { handleForwardedChar(ch, renderedSourceLayoutID: renderedSourceLayoutID) }
            return
        }

        // Структурные клавиши обрабатываем ВСЕГДА, даже если в flags остался
        // «грязный» модификатор (stale .maskAlternate и т.п.) — иначе счётчик
        // слова не сбрасывается и конвертация захватывает лишние символы.

        // Пробел — единственная граница через которую можно вернуться
        if keyCode == KC.space {
            if wordHistoryOverflowed {
                wordBeforeBoundaryLength = 0
                boundaryCount = 0
                prevWordKeys = []
                prevWordSourceID = nil
                wordHistoryOverflowed = false
            } else if currentWordLength > 0 {
                wordBeforeBoundaryLength = currentWordLength
                boundaryCount = 1
                prevWordKeys = currentWordKeys
                prevWordSourceID = currentWordSourceID
                prevWordBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            } else {
                boundaryCount += 1
            }
            currentWordLength = 0
            currentWordKeys = []
            currentWordSourceID = nil
            appendHistorySpace()
            return
        }

        // Enter, Tab — полный сброс
        if keyCode == KC.enter || keyCode == KC.tab {
            fullReset()
            return
        }

        // Стрелки (Left…Up) — полный сброс
        if keyCode >= KC.left && keyCode <= KC.up {
            fullReset()
            return
        }

        // Backspace
        if keyCode == KC.backspace {
            if wordHistoryOverflowed { return } // The remaining real word is still untrusted.
            if currentWordLength > 0 {
                currentWordLength -= 1
                if !currentWordKeys.isEmpty { currentWordKeys.removeLast() }
                if !lineKeys.isEmpty { lineKeys.removeLast() }   // #24: синхронно с буфером строки
            } else {
                fullReset()   // стирание через границу слова — буфер строки ненадёжен, сброс
            }
            return
        }

        // (Cmd+A, Cmd+C, Cmd+X и т.п.) могло изменить выделение — сбрасываем наш буфер.
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if !modifiers.isEmpty {
            fullReset()
            return
        }

        if KeyMapping.keycodeToEN[keyCode] != nil {
            if !wordHistoryOverflowed { rememberTypedSource(renderedSourceLayoutID) }
            let tk = TypedKey(keyCode: keyCode, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
            appendHistoryKey(tk)
            wordBeforeBoundaryLength = 0
            boundaryCount = 0
            prevWordKeys = []
            prevWordSourceID = nil
            playLayoutSoundIfArmed()
        } else {
            // Esc, F-клавиши, и т.д. — полный сброс
            fullReset()
        }
    }

    /// Обработка символа, проброшенного через удалённый стол (keyCode 0 + юникод).
    /// Работаем по самому символу: пробел — граница слова, backspace — откат,
    /// буква — кладём реальный символ в буфер (конверсия пойдёт по нему, см. convertKeys).
    func handleForwardedChar(_ ch: Character, renderedSourceLayoutID: String?) {
        // Пробел — граница слова (как локальный keyCode space)
        if ch == " " {
            if wordHistoryOverflowed {
                wordBeforeBoundaryLength = 0
                boundaryCount = 0
                prevWordKeys = []
                prevWordSourceID = nil
                wordHistoryOverflowed = false
            } else if currentWordLength > 0 {
                wordBeforeBoundaryLength = currentWordLength
                boundaryCount = 1
                prevWordKeys = currentWordKeys
                prevWordSourceID = currentWordSourceID
                prevWordBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            } else {
                boundaryCount += 1
            }
            currentWordLength = 0
            currentWordKeys = []
            currentWordSourceID = nil
            appendHistorySpace()
            return
        }
        // Перенос строки / таб — полный сброс
        if ch == "\n" || ch == "\r" || ch == "\t" {
            fullReset()
            return
        }
        // Backspace / Delete — откат одной буквы
        if ch == "\u{8}" || ch == "\u{7f}" {
            if wordHistoryOverflowed { return } // No reliable suffix until a new boundary.
            if currentWordLength > 0 {
                currentWordLength -= 1
                if !currentWordKeys.isEmpty { currentWordKeys.removeLast() }
                if !lineKeys.isEmpty { lineKeys.removeLast() }   // #24
            } else {
                fullReset()
            }
            return
        }
        // Буква — кладём реальный символ (keyCode 0 = «проброшено»). shift несём из регистра.
        if ch.isLetter {
            if !wordHistoryOverflowed { rememberTypedSource(renderedSourceLayoutID) }
            let tk = TypedKey(keyCode: 0, shift: ch.isUppercase, caps: false, char: ch)
            appendHistoryKey(tk)
            wordBeforeBoundaryLength = 0
            boundaryCount = 0
            prevWordKeys = []
            prevWordSourceID = nil
            playLayoutSoundIfArmed()
            return
        }
        // Цифры/пунктуация/прочее: в буфер не копим, НО и слово «живым» не оставляем —
        // иначе счёт стирания разъезжается с полем и конверсия портит текст (ревью-находка:
        // «ghbdtn,» по удалёнке = 6 букв в буфере при 7 символах в поле → стёрся бы лишний).
        // Консервативно сбрасываем: слово с пунктуацией по удалёнке просто не авто-конвертится.
        fullReset()
    }

    /// issue #7: на первой букве после смены раскладки даём короткий звук, зависящий от
    /// раскладки — слышно, в какой раскладке начал печатать. Опц., по умолчанию выключено.
    private func playLayoutSoundIfArmed() {
        guard soundArmed, SettingsManager.shared.keySound else { return }
        soundArmed = false
        let sources = LayoutSwitcher.installedLayouts()
        let id1 = SettingsManager.shared.layout1ID.isEmpty
            ? LayoutSwitcher.autoDetectID1(from: sources) : SettingsManager.shared.layout1ID
        let name = LayoutSwitcher.currentLayoutID() == id1 ? "Tink" : "Pop"
        NSSound(named: name)?.play()
    }

    /// Возвращает true, если событие надо «съесть» (только Caps Lock в consume-режиме).
    fileprivate func handleFlagsChanged(flags: CGEventFlags, keyCode: UInt16,
                                        clock: KeyboardInputClock, allowCombinedShift: Bool) -> Bool {
        invalidatePrediction()  // do not advance combined-Shift revision between its two taps
        if combinedShiftEnabled && allowCombinedShift {
            handleCombinedShift(flags: flags, keyCode: keyCode, clock: clock)
        }
        handleSwitchFlags(flags: flags, keyCode: keyCode)   // issue #14: второй хоткей
        handleCaseFlags(flags: flags, keyCode: keyCode)     // issue #29: третий хоткей (регистр)
        if combinedShiftEnabled && triggerConfig.isShift { return false }
        switch triggerConfig.kind {
        case .capsLock:
            guard keyCode == KC.capsLock else { return false }
            // Caps Lock шлёт одно событие на нажатие. Используем как тап и съедаем,
            // чтобы не переключался регистр.
            registerTap()
            return true

        case let .modifier(mask, left, right):
            let accepted: Set<UInt16> = triggerConfig.rightOnly ? [right] : [left, right]
            let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let otherMods = allMods.subtracting(mask)

            if flags.contains(mask) {
                // нажатие: армим только если это нужная клавиша и нет других модификаторов
                if accepted.contains(keyCode) && flags.intersection(otherMods).isEmpty {
                    triggerArmed = true
                    triggerPressTime = Date()
                } else {
                    triggerArmed = false  // не та сторона / комбо
                }
            } else {
                // отпускание: соло-тап нужной клавиши, быстро и без клавиш между
                if triggerArmed, accepted.contains(keyCode), let t = triggerPressTime,
                   Date().timeIntervalSince(t) < tapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            return false

        case let .combo(maskA, maskB):
            let both: CGEventFlags = [maskA, maskB]
            let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let others = allMods.subtracting(both)
            if !flags.intersection(others).isEmpty {
                triggerArmed = false                 // зажат посторонний модификатор — не наш триггер
            } else if flags.contains(both) {
                triggerArmed = true                  // ровно оба нужных, без посторонних → армим
                triggerPressTime = Date()
            } else if flags.intersection(allMods).isEmpty {
                // всё отпущено: комбо, если был армлен и без клавиш между (triggerArmed это
                // гарантирует). Окно расширено 0.4→2с (comboTapWindow, issue #21), но потолок
                // сохранён — не срабатывать на попутное удержание во время скролла/жеста.
                if triggerArmed, let t = triggerPressTime, Date().timeIntervalSince(t) < comboTapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            // частичное состояние (зажат один из двух) — ждём, ничего не трогаем
            return false
        }
    }

    /// issue #14: параллельная машина второго хоткея — чистое переключение раскладки.
    /// Зеркалит триггерную логику; Caps Lock не поддерживается, сторона (left/right) не
    /// различается, одиночный/двойной тап — как у триггера (switchDoubleTap). Разоружается
    /// на keyDown/клике вместе с триггером — Ctrl+Shift+P и подобные не переключают.
    private func handleSwitchFlags(flags: CGEventFlags, keyCode: UInt16) {
        guard let cfg = switchConfig else { return }
        guard !(combinedShiftEnabled && cfg.isShift) else { return }
        let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        switch cfg.kind {
        case .capsLock:
            return
        case let .modifier(mask, left, right):
            let accepted: Set<UInt16> = cfg.rightOnly ? [right] : [left, right]
            let otherMods = allMods.subtracting(mask)
            if flags.contains(mask) {
                if accepted.contains(keyCode) && flags.intersection(otherMods).isEmpty {
                    switchArmed = true
                    switchPressTime = Date()
                } else {
                    switchArmed = false
                }
            } else {
                if switchArmed, accepted.contains(keyCode), let t = switchPressTime,
                   Date().timeIntervalSince(t) < tapWindow {
                    registerSwitchTap()
                }
                switchArmed = false
                switchPressTime = nil
            }
        case let .combo(maskA, maskB):
            let both: CGEventFlags = [maskA, maskB]
            let others = allMods.subtracting(both)
            if !flags.intersection(others).isEmpty {
                switchArmed = false
            } else if flags.contains(both) {
                switchArmed = true
                switchPressTime = Date()
            } else if flags.intersection(allMods).isEmpty {
                // issue #21: окно расширено 0.4→2с (comboTapWindow) — аккорд держат дольше
                // флика, но потолок оставлен, чтобы не срабатывать на попутное удержание
                // во время скролла/жеста (не сбрасывают switchArmed).
                if switchArmed, let t = switchPressTime, Date().timeIntervalSince(t) < comboTapWindow {
                    registerSwitchTap()
                }
                switchArmed = false
                switchPressTime = nil
            }
        }
    }

    /// Учитывает одиночный/двойной тап хоткея смены (зеркало registerTap).
    private func registerSwitchTap() {
        if switchConfig?.doubleTap == true {
            if let last = switchLastTapTime, Date().timeIntervalSince(last) < tapWindow {
                switchLastTapTime = nil
                fireSwitch()
            } else {
                switchLastTapTime = Date()  // ждём второй тап
            }
        } else {
            fireSwitch()
        }
    }

    private func fireSwitch() {
        rslog("switch hotkey: fire")
        DispatchQueue.main.async { [weak self] in self?.onSwitchHotkey?() }
    }

    /// issue #29: параллельная машина хоткея смены регистра — зеркало handleSwitchFlags.
    private func handleCaseFlags(flags: CGEventFlags, keyCode: UInt16) {
        guard let cfg = caseConfig else { return }
        guard !(combinedShiftEnabled && cfg.isShift) else { return }
        let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        switch cfg.kind {
        case .capsLock:
            return
        case let .modifier(mask, left, right):
            let accepted: Set<UInt16> = cfg.rightOnly ? [right] : [left, right]
            let otherMods = allMods.subtracting(mask)
            if flags.contains(mask) {
                if accepted.contains(keyCode) && flags.intersection(otherMods).isEmpty {
                    caseArmed = true
                    casePressTime = Date()
                } else {
                    caseArmed = false
                }
            } else {
                if caseArmed, accepted.contains(keyCode), let t = casePressTime,
                   Date().timeIntervalSince(t) < tapWindow {
                    registerCaseTap()
                }
                caseArmed = false
                casePressTime = nil
            }
        case let .combo(maskA, maskB):
            let both: CGEventFlags = [maskA, maskB]
            let others = allMods.subtracting(both)
            if !flags.intersection(others).isEmpty {
                caseArmed = false
            } else if flags.contains(both) {
                caseArmed = true
                casePressTime = Date()
            } else if flags.intersection(allMods).isEmpty {
                if caseArmed, let t = casePressTime, Date().timeIntervalSince(t) < comboTapWindow {
                    registerCaseTap()
                }
                caseArmed = false
                casePressTime = nil
            }
        }
    }

    private func registerCaseTap() {
        if caseConfig?.doubleTap == true {
            if let last = caseLastTapTime, Date().timeIntervalSince(last) < tapWindow {
                caseLastTapTime = nil
                fireCase()
            } else {
                caseLastTapTime = Date()
            }
        } else {
            fireCase()
        }
    }

    private func fireCase() {
        rslog("case hotkey: fire")
        DispatchQueue.main.async { [weak self] in self?.onCaseHotkey?() }
    }

    /// Учитывает одиночный/двойной тап и запускает конвертацию.
    private func registerTap() {
        if triggerConfig.doubleTap {
            if let last = lastTapTime, Date().timeIntervalSince(last) < tapWindow {
                lastTapTime = nil
                fireConversion()
            } else {
                lastTapTime = Date()  // ждём второй тап
            }
        } else {
            fireConversion()
        }
    }

    private func fireConversion() {
        if !keysTypedSinceConversion {
            rslog("trigger: RECONVERT")
            DispatchQueue.main.async { [weak self] in self?.onAltReconvert?() }
        } else {
            rslog("trigger: CONVERT")
            DispatchQueue.main.async { [weak self] in self?.onAltTap?() }
        }
    }
}

// MARK: - C Callback

private func keyboardCallback(
    type: CGEventType,
    event: CGEvent,
    monitor: KeyboardMonitor,
    fence: InputEventFence
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        RuntimeDiagnostics.record(type == .tapDisabledByTimeout ? .tapDisabledTimeout : .tapDisabledUserInput)
        fence.interrupt()
        DispatchQueue.main.async { [weak monitor] in
            guard let monitor, monitor.inputFence === fence else { return }
            monitor.nativeGateWasInterrupted()
            if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return Unmanaged.passUnretained(event)
    }

    // Игнорируем собственные симулированные события по маркеру
    let marker = event.getIntegerValueField(.eventSourceUserData)
    if marker == kRuSwitcherEventMarker || marker == diagnosticFixtureEventMarker {
        return Unmanaged.passUnretained(event)
    }

    return processKeyboardInput(type: type, event: event, monitor: monitor, fence: fence)
}

private func diagnosticFixtureFlagsEnabled() -> Bool {
    CommandLine.arguments.contains("--diagnostic-panel")
        && CommandLine.arguments.contains("--diagnostic-native-canary")
}

private func diagnosticFixtureEventIsAdmitted(_ event: CGEvent) -> Bool {
    guard diagnosticFixtureFlagsEnabled(),
          event.getIntegerValueField(.eventSourceUserData) == diagnosticFixtureEventMarker,
          let pid = Int32(exactly: event.getIntegerValueField(.eventTargetUnixProcessID)),
          diagnosticFixtureProcessIsKnown(pid),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if event.type == .flagsChanged {
        return (code == 56 || code == 60) && event.flags.subtracting(.maskShift).isEmpty
    }
    return (event.type == .keyDown || event.type == .keyUp)
        && [5, 4, 11, 2, 17, 45, 48, 7].contains(code) && event.flags.isEmpty
}

private func processKeyboardInput(type: CGEventType, event: CGEvent, monitor: KeyboardMonitor,
                                  fence: InputEventFence, diagnosticFixture: Bool = false) -> Unmanaged<CGEvent>? {
    let callback = KeyboardCallbackAdmission.enter(event: event, fence: fence)
    let clock = callback.clock
    let admission = callback.admission
    let handoff = KeyboardCallbackEvent(event)
    let forwarded: Unmanaged<CGEvent>? = DispatchQueue.main.sync {
        let event = handoff.event
        guard monitor.inputFence === fence else {
            return diagnosticFixture ? nil : Unmanaged.passUnretained(event)
        }
        if diagnosticFixture,
           (!monitor.nativeInputTransportAvailable || !diagnosticFixtureEventIsAdmitted(event)) {
            return nil
        }
        if admission.wasHeld { RuntimeDiagnostics.record(.nativeFenceHeldInput) }
        if admission.interrupted { RuntimeDiagnostics.record(.nativeFenceInterrupted) }
        let allowCombinedShift = monitor.allowCombinedShift(after: admission)
        let needsSourceRefresh = admission.needsSourceRefresh
            || monitor.inputSourceNeedsRefresh(eventTimestamp: clock.eventTimestamp ?? 0)
        var observedSource: String?
        func observeSourceOnce() -> String {
            if let observedSource { return observedSource }
            let source = LayoutSwitcher.currentLayoutID()
            observedSource = source
            monitor.observeInputSource(source)
            return source
        }
        // Non-key events still acknowledge a previously unconfirmed transition.
        if needsSourceRefresh { _ = observeSourceOnce() }
        let renderedSourceLayoutID = HeldKeyReplay.refreshForForwarding(event,
            needsSourceRefresh: needsSourceRefresh,
            remoteDesktopMode: SettingsManager.shared.remoteDesktopMode,
            observeSource: observeSourceOnce)
        let result = keyboardEventOnMain(type: type, event: event, monitor: monitor,
            renderedSourceLayoutID: renderedSourceLayoutID, clock: clock,
            allowCombinedShift: allowCombinedShift)
        monitor.schedulePendingCombinedShiftConversion(after: fence)
        return result
    }
    fence.leavePhysicalEvent(admission, wasForwarded: forwarded != nil)
    return forwarded
}

/// The tap thread waits synchronously for main and never touches the event during
/// that handoff. The OS retains it until the original callback returns.
private final class KeyboardCallbackEvent: @unchecked Sendable {
    let event: CGEvent
    init(_ event: CGEvent) { self.event = event }
}

private func keyboardEventOnMain(type: CGEventType, event: CGEvent,
                                 monitor: KeyboardMonitor, renderedSourceLayoutID: String?,
                                 clock: KeyboardInputClock, allowCombinedShift: Bool) -> Unmanaged<CGEvent>? {

    if type == .keyDown {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let remote = SettingsManager.shared.remoteDesktopMode
        // Удалёнка: игнорируем авто-повтор клавиш — латентность Screen Sharing рождает
        // ложные повторы (тот самый «фффффф»), засоряющие буфер конверсии.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0, remote {
            return Unmanaged.passUnretained(event)
        }
        // Удалёнка: Screen Sharing пробрасывает символы как keyCode 0 + юникод-payload.
        // Читаем сам символ — без него буфер забивается keyCode 0 (= один символ → «фффффф»).
        var forwardedChar: Character? = nil
        if remote, keyCode == 0 {
            var buf = [UniChar](repeating: 0, count: 4)
            var len = 0
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
            if len >= 1, let scalar = UnicodeScalar(buf[0]) {
                forwardedChar = Character(scalar)
                if SettingsManager.shared.debugLogEnabled {
                    // Приватность: НЕ логируем сам символ/кодпоинт — иначе получается посимвольный
                    // лог удалённой сессии. Фиксируем только факт проброса.
                    rslog("remote: forwarded char")
                }
            }
        }
        var units = [UniChar](repeating: 0, count: 16)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        // A truncated/composed payload is left to the application and never guessed.
        let rendered = length > 0 && length < units.count
            ? String(decoding: units.prefix(length), as: UTF16.self) : nil
        monitor.handleKeyDown(keyCode: keyCode, flags: event.flags, char: forwardedChar,
            renderedText: rendered, renderedSourceLayoutID: renderedSourceLayoutID)
    } else if type == .flagsChanged {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if monitor.handleFlagsChanged(flags: event.flags, keyCode: keyCode,
                                      clock: clock, allowCombinedShift: allowCombinedShift) {
            return nil  // съедаем Caps Lock, чтобы не переключался регистр
        }
    } else if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
        monitor.resetBuffersOnClick()
    } else if type == .scrollWheel {
        monitor.resetBuffersOnClick()
    }

    return Unmanaged.passUnretained(event)
}
