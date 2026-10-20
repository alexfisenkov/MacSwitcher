import AppKit
import ApplicationServices
import CoreGraphics

/// A restore is permitted only while the clipboard still has the exact version
/// last written by this transaction. User copies always supersede our snapshot.
@MainActor
final class ClipboardRestoreSession {
    private let pasteboard: NSPasteboard
    private var savedItems: [NSPasteboardItem]?
    private var ownedChangeCount: Int?
    var hasSnapshot: Bool { savedItems != nil }

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    private var stillOwnsClipboard: Bool {
        guard let ownedChangeCount else { return false }
        return savedItems != nil && pasteboard.changeCount == ownedChangeCount
    }

    func permitsPaste() -> Bool { stillOwnsClipboard }

    func begin() -> Bool {
        if stillOwnsClipboard { return true } // rapid reconvert preserves the first snapshot
        discard()
        let count = pasteboard.changeCount
        let snapshot = (pasteboard.pasteboardItems ?? []).map { oldItem in
            let item = NSPasteboardItem()
            for type in oldItem.types {
                if let data = oldItem.data(forType: type) { item.setData(data, forType: type) }
            }
            return item
        }
        guard pasteboard.changeCount == count else { return false }
        savedItems = snapshot
        ownedChangeCount = count
        return true
    }

    func clearForCopy() -> Int? {
        guard stillOwnsClipboard else { discard(); return nil }
        let count = pasteboard.clearContents()
        ownedChangeCount = count
        guard pasteboard.changeCount == count else { discard(); return nil }
        return count
    }

    /// The caller must verify that the copied text matches the original AX
    /// selection before claiming an asynchronous Cmd+C write as ours.
    func claimVerifiedCopy(changeCount: Int) -> Bool {
        guard savedItems != nil, let previous = ownedChangeCount,
              changeCount != previous, pasteboard.changeCount == changeCount else { return false }
        ownedChangeCount = changeCount
        return true
    }

    func writeTemporaryText(_ text: String) -> Bool {
        guard let count = clearForCopy(), pasteboard.setString(text, forType: .string),
              pasteboard.changeCount == count else { return false }
        return true
    }

    @discardableResult
    func restoreIfOwned() -> Bool {
        defer { discard() }
        guard stillOwnsClipboard, let savedItems else { return false }
        let count = pasteboard.clearContents()
        // NSPasteboard has no compare-and-swap; check again immediately before
        // writing, as well as before clearing, and never adopt an unknown version.
        guard pasteboard.changeCount == count else { return false }
        if !savedItems.isEmpty { return pasteboard.writeObjects(savedItems) }
        return true
    }

    private func discard() { savedItems = nil; ownedChangeCount = nil }
}

/// Конвертация текста между раскладками
@MainActor
final class TextConverter {
    private var lastConvertedCount = 0
    private var lastBoundaryCount = 0
    private lazy var clipboardSession = ClipboardRestoreSession(pasteboard: .general)
    private var clipboardRestoreWork: DispatchWorkItem?
    private var clipboardRestoreGeneration: UInt64 = 0
    private var isConverting = false
    /// Очередь для инжекта нажатий буферного движка — чтобы usleep не блокировал
    /// main-поток, на котором висит event tap (иначе тап голодает → лаги/потери нажатий).
    nonisolated private let injectQueue = DispatchQueue(label: "com.ruswitcher.inject", qos: .userInteractive)

    // Состояние движка перепечатки (буфер нажатий → юникод-вставка)
    private var lastOriginal = ""
    private var lastConverted = ""
    private var lastWasBuffer = false
    private var lastLayoutContext: CombinedShiftContext?
    private var predictionLayouts: (source: String, target: String)?
    /// Exact layout of the inserted result, also after undo; callers must not toggle active source.
    var lastResultLayoutID: String? { predictionLayouts?.target ?? lastLayoutContext?.targetLayoutID }
    var hasReconversionState: Bool { !lastConverted.isEmpty || lastConvertedCount > 0 }

    /// The only automatic edit entry point. It cannot fall back to clipboard,
    /// a global key queue or deletion based solely on a remembered character count.
    func replaceVerifiedSuffix(original: String, replacement: String, sourceLayoutID: String,
                               resultLayoutID: String, execution: CombinedShiftExecutionContext) -> Bool {
        guard original != replacement, !sourceLayoutID.isEmpty, !resultLayoutID.isEmpty,
              performNativeBufferEdit(original: original, replacement: replacement, execution: execution) else { return false }
        lastOriginal = original
        lastConverted = replacement
        lastWasBuffer = true
        lastConvertedCount = 0
        lastBoundaryCount = 0
        lastLayoutContext = nil
        predictionLayouts = (sourceLayoutID, resultLayoutID)
        return true
    }
    /// Последняя clipboard-конверсия содержала RTL — реконверт стрелками небезопасен.
    private var lastClipboardRTL = false

    /// RTL-скаляры: иврит, арабский + презентационные формы (копипаста из PDF).
    nonisolated static func containsRTL(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            ($0.value >= 0x0590 && $0.value <= 0x06FF)
            || ($0.value >= 0xFB1D && $0.value <= 0xFDFF)
            || ($0.value >= 0xFE70 && $0.value <= 0xFEFF)
        }
    }

    /// NFC-нормализация перед вставкой — но НЕ для иврита/арабского: канонич. композиция
    /// может переставить/слить комбинирующие знаки (никуд/харакат), и число кодпоинтов
    /// разъедется со счётчиком Backspace/Shift-Left. Для RTL оставляем строку как есть.
    nonisolated static func normalizedForInsert(_ s: String) -> String {
        containsRTL(s) ? s : s.precomposedStringWithCanonicalMapping
    }

    /// Создаёт CGEventSource с маркером, чтобы KeyboardMonitor игнорировал наши события
    nonisolated private func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = kRuSwitcherEventMarker
        return source
    }

    /// Проверяет, что текущий фокусированный элемент — редактируемое текстовое поле
    private func isFocusedElementEditable() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Занятое приложение (Electron в GC, IDE в индексации) без таймаута держит main
        // до 6с (дефолт AX) — это и есть «фризы». 0.2с хватает живому ответу; SpotlightAX
        // такой же таймаут уже ставит.
        AXUIElementSetMessagingTimeout(axApp, 0.2)

        var focusedRaw: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
        guard err == .success, let focused = focusedRaw else {
            rslog("editable: no focused element")
            return false
        }

        let element = focused as! AXUIElement

        // Проверяем роль
        var roleRaw: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw)
        let role = (roleRaw as? String) ?? ""

        // Текстовые роли
        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        if textRoles.contains(role) {
            // Дополнительно: не read-only?
            var editableRaw: AnyObject?
            let editErr = AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRaw)
            // Если атрибут отсутствует — считаем editable (у AXWebArea его может не быть)
            if editErr == .success, let editable = editableRaw as? Bool {
                rslog("editable: role=\(role) editable=\(editable)")
                return editable
            }
            rslog("editable: role=\(role) (no AXEditable attr, assuming yes)")
            return true
        }

        rslog("editable: role=\(role) — not a text field")
        return false
    }

    // MARK: - Public API

    /// Read-only selection presence check for empty native doubles. Unknown AX state fails closed:
    /// no Cmd+C, clipboard clearing, fake insertion, or second language switch in an empty field.
    func hasFocusedTextSelection() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRaw) == .success,
              let focused = focusedRaw else { return false }
        let element = focused as! AXUIElement
        var selectedRaw: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRaw) == .success,
           let text = selectedRaw as? String { return !text.isEmpty }
        var rangeRaw: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRaw) == .success,
           let raw = rangeRaw, CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &range) { return range.length > 0 }
        }
        return false
    }

    private func selectionConversion(_ text: String, context: CombinedShiftContext?, normalize: Bool = true) -> String {
        let settings = SettingsManager.shared
        let converted = settings.convertByText ? DynamicKeyMapping.convertBidirectional(text, context: context)
            : settings.smartConversion ? SmartConvert.selection(text, context: context)
            : DynamicKeyMapping.convert(text, context: context)
        return normalize ? TextConverter.normalizedForInsert(converted) : converted
    }

    /// Движок перепечатки: стираем набранное и впечатываем конвертированное через
    /// юникод-вставку — без буфера обмена и без выделения (работает в Atom/Electron).
    /// Падает на clipboard-движок, если буфера нет (текст выделен мышью) или
    /// раскладки не определились.
    /// passthroughSuffix (issue #15): прилипшая к слову пунктуация — стирается вместе со
    /// словом и возвращается в поле как есть, БЕЗ кейкод-конверсии (',' EN ↔ 'б' RU).
    /// typedSuffix (issue #33): суффикс КАК НАБРАН, если passthroughSuffix уже
    /// сконвертирован («?»→«,» на Русской — ПК) — для честного отката реконвертом.
    /// Пустой typedSuffix означает «совпадает с passthroughSuffix».
    func convert(wordKeys: [TypedKey], prevWordKeys: [TypedKey], boundaryCount: Int,
                 passthroughSuffix: String = "", typedSuffix: String = "", context: CombinedShiftContext? = nil,
                 execution: CombinedShiftExecutionContext? = nil) -> Bool {
        guard context == nil || execution != nil else { return false }
        let keys: [TypedKey]
        let trailingSpaces: Int
        if !wordKeys.isEmpty {
            keys = wordKeys; trailingSpaces = 0
        } else if !prevWordKeys.isEmpty && boundaryCount > 0 {
            keys = prevWordKeys; trailingSpaces = boundaryCount
        } else {
            // нет буфера — возможно, выделен мышью старый текст: пусть решает clipboard
            return convertViaClipboard(wordLength: 0, prevWordLength: 0, boundaryCount: 0, context: context, execution: execution)
        }

        guard let pair = DynamicKeyMapping.convertKeys(keys, context: context) else {
            guard context == nil else { return false }  // explicit mapping failure cannot justify count-based deletion
            // Clipboard-путь про суффикс не знает (селекция посчиталась бы неверно) —
            // точность важнее полноты: с суффиксом тихо отказываемся.
            guard passthroughSuffix.isEmpty else {
                rslog("buffer convert: suffix + unresolved layouts — bail")
                return false
            }
            rslog("buffer convert: layouts not resolved — fallback to clipboard")
            return convertViaClipboard(wordLength: wordKeys.count, prevWordLength: prevWordKeys.count, boundaryCount: boundaryCount)
        }

        guard !isConverting else { return false }
        if context != nil {
            guard pair.original != pair.converted, pair.original.count == keys.count else { return false }
        }
        let spaces = String(repeating: " ", count: trailingSpaces)
        let bsCount = keys.count + passthroughSuffix.count + trailingSpaces
        // issue #33 (скептик, HIGH): в lastOriginal — суффикс КАК НАБРАН, иначе реконверт
        // после «tkrb?»→«елки,» восстанавливал бы «tkrb,» вместо «tkrb?».
        let originalSuffix = typedSuffix.isEmpty ? passthroughSuffix : typedSuffix
        let insert = pair.converted + passthroughSuffix + spaces
        let original = pair.original + originalSuffix + spaces
        if let execution {
            guard performNativeBufferEdit(original: original, replacement: insert, execution: execution) else { return false }
            lastOriginal = original
            lastConverted = insert
            lastWasBuffer = true
            predictionLayouts = nil
            lastLayoutContext = context.map { DynamicKeyMapping.resultContext(for: insert, requested: $0) }
            return true  // native history is committed only after the bounded batch was posted
        }
        isConverting = true
        lastOriginal = pair.original + originalSuffix + spaces
        lastConverted = pair.converted + passthroughSuffix + spaces
        lastWasBuffer = true
        predictionLayouts = nil
        lastLayoutContext = context
        rslog("buffer convert: \(keys.count) keys (+\(passthroughSuffix.count) punct, +\(trailingSpaces) sp)")

        // Инжект — вне main, чтобы usleep не голодал event tap.
        injectQueue.async { [weak self] in
            guard let self else { return }
            self.backspace(bsCount)
            usleep(8_000)   // короткий зазор стирание→вставка: порядок и так гарантирован очередью HID
            self.insertText(insert)
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    /// issue #24: конвертировать всю набранную строку (от курсора до начала строки) без
    /// выделения мышью. Сами выделяем Shift+Cmd+← и прогоняем через путь выделения (умная
    /// конверсия починит только слова не в той раскладке, верные — оставит). При no-op/сбое
    /// снимаем выделение (иначе строка осталась бы подсвеченной). Реконверт восстановит через
    /// сохранённый оригинал (см. convertViaClipboard/reconvertViaClipboard).
    func convertLine(context: CombinedShiftContext? = nil, execution: CombinedShiftExecutionContext? = nil) -> Bool {
        guard context == nil || execution != nil else { return false }
        guard execution?.isValid() != false else { return false }
        guard !isConverting else { return false }
        // Скептик 3.2.0: не шлём Shift+Cmd+← вне текстового поля — иначе аккорд сработает как
        // ярлык приложения (напр. выделит не то). В поле — работаем.
        guard isFocusedElementEditable() else { rslog("convertLine: non-editable focus — bail"); return false }

        // Выделяем до начала строки влево (обычный LTR). Проверяем через AX, реально ли что-то
        // выделилось: только тогда конвертим и (при no-op) безопасно снимаем стрелкой.
        guard operationKey(keyCode: KC.left, flags: [.maskShift, .maskCommand], execution: execution) else { return false }
        usleep(60_000)
        guard execution?.isValid() != false else { return false }
        if !focusedSelectionIsEmpty() {
            let ok = convertViaClipboard(wordLength: 0, prevWordLength: 0, boundaryCount: 0, context: context, execution: execution)
            if !ok { operationKey(keyCode: KC.right, flags: [], execution: execution) }   // never collapse a different field
            return ok
        }

        // issue #26: влево выделилось ПУСТО → RTL-веб-поле (адресная строка Chrome, WhatsApp Web),
        // где начало строки справа. Пробуем вправо. Стрелку-collapse влево НЕ жали — каретка на месте,
        // так что первый символ не теряется. Пробуем другую сторону ТОЛЬКО при пустом влево — значит
        // LTR-строку «вперёд» мы не трогаем (нет переписывания верного текста, скептик #26).
        guard operationKey(keyCode: KC.right, flags: [.maskShift, .maskCommand], execution: execution) else { return false }
        usleep(60_000)
        guard execution?.isValid() != false else { return false }
        if !focusedSelectionIsEmpty() {
            let ok = convertViaClipboard(wordLength: 0, prevWordLength: 0, boundaryCount: 0, context: context, execution: execution)
            if !ok { operationKey(keyCode: KC.left, flags: [], execution: execution) }
            return ok
        }
        return false   // пусто в обе стороны — пустая строка; каретка не двигалась
    }

    /// true — текущее выделение фокус-элемента ПУСТО (по AX). На любой неопределённости (нет фокуса,
    /// атрибут недоступен) возвращаем false = «выделение есть» — безопасно для LTR: не пробуем вторую
    /// сторону и не переписываем текст «вперёд». RTL-фикс сработает лишь там, где AX надёжно отдаёт пусто.
    private func focusedSelectionIsEmpty() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRaw) == .success,
              let focused = focusedRaw else { return false }
        let element = focused as! AXUIElement
        var selRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRaw) == .success,
              let sel = selRaw as? String else { return false }
        return sel.isEmpty
    }

    /// issue #24 (терминал): конвертирует всю набранную строку по БУФЕРУ нажатий — backspace на
    /// длину строки + перепечатка сконвертированного. Без OS-выделения (работает в терминалах и
    /// для иврита). Только для свежей непрерывной строки (буфер сбрасывается на пунктуации/Enter/
    /// сдвиге курсора → вызывающий откатывается на последнее слово). Реконверт — через lastOriginal.
    func convertLineBuffer(_ lineKeys: [TypedKey], context: CombinedShiftContext? = nil,
                           execution: CombinedShiftExecutionContext? = nil) -> Bool {
        guard context == nil || execution != nil else { return false }
        guard !isConverting, !lineKeys.isEmpty else { return false }
        guard let original = DynamicKeyMapping.lineString(from: lineKeys, sourceLayoutID: context?.sourceLayoutID), !original.isEmpty else { return false }
        let converted = selectionConversion(original, context: context, normalize: false)
        guard converted != original else { return false }   // строка уже верная — no-op
        if let execution {
            guard performNativeBufferEdit(original: original, replacement: converted, execution: execution) else { return false }
            lastWasBuffer = true
            lastOriginal = original
            lastConverted = converted
            predictionLayouts = nil
            lastLayoutContext = context.map { DynamicKeyMapping.resultContext(for: converted, requested: $0) }
            return true
        }
        isConverting = true
        lastWasBuffer = true
        lastOriginal = original
        lastConverted = converted
        predictionLayouts = nil
        lastLayoutContext = context
        let bsCount = original.count
        rslog("line convert (terminal buffer): \(original.count)→\(converted.count) chars")
        injectQueue.async { [weak self] in
            guard let self else { return }
            self.backspace(bsCount)
            usleep(8_000)   // короткий зазор стирание→вставка: порядок и так гарантирован очередью HID
            self.insertText(converted)
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    // MARK: - issue #29: смена регистра (как Alt+Break в Punto)

    private var caseWord: String?   // слово/строка, по которой сейчас циклим регистр (буферный путь)
    private var caseIndex = 0
    private var caseOnScreen = ""   // ТЕКУЩИЙ экранный текст цикла — его длину и стираем (не original.count:
                                    // регистр не всегда сохраняет длину, напр. немецкое ß→SS, скептик #29)

    /// Общий движок цикла регистра по буферу (слово или строка). original — как набрано. Стирает
    /// реальную экранную длину и пропускает варианты, не дающие видимого изменения (односимвольные
    /// слова, каузлес-скрипты вроде иврита → просто no-op вместо мигания). Возвращает true при инжекте.
    private func cycleCaseByBuffer(_ original: String) -> Bool {
        if original != caseWord {
            caseWord = original
            caseIndex = TextConverter.caseVariant(original, 0) == original ? 1 : 0
            caseOnScreen = original                       // на экране — набранный оригинал
        } else {
            caseIndex = (caseIndex + 1) % 3
        }
        // Пропускаем варианты, совпадающие с тем, что уже на экране (иначе мёртвый тап / миганиe).
        var idx = caseIndex, changed = TextConverter.caseVariant(original, idx), tries = 0
        while changed == caseOnScreen && tries < 3 {
            idx = (idx + 1) % 3; changed = TextConverter.caseVariant(original, idx); tries += 1
        }
        guard changed != caseOnScreen else { return false }   // все варианты равны (иврит и т.п.) → пропуск
        caseIndex = idx
        let bs = caseOnScreen.count                           // стираем РЕАЛЬНУЮ экранную длину
        caseOnScreen = changed
        let insert = changed  // freeze the chosen variant before crossing the inject queue
        isConverting = true
        rslog("case: buffer \(original.count) chars → variant \(idx), bs \(bs)")
        injectQueue.async { [weak self] in
            guard let self else { return }
            self.backspace(bs)
            usleep(20_000)
            self.insertText(insert)
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    /// Вариант регистра по индексу цикла: 0 — ВЕРХНИЙ, 1 — нижний, 2 — Заглавный (Title).
    private static func caseVariant(_ s: String, _ i: Int) -> String {
        switch ((i % 3) + 3) % 3 {
        case 0:  return s.uppercased()
        case 1:  return s.lowercased()
        default: return s.capitalized
        }
    }

    /// Сменить регистр последнего набранного слова (буфер) или выделения (clipboard). Раскладку
    /// НЕ трогает. По повторным нажатиям на то же слово циклит ВЕРХНИЙ → нижний → Заглавный.
    func changeCase(wordKeys: [TypedKey]) -> Bool {
        guard !isConverting else { return false }
        if !wordKeys.isEmpty { return changeCaseWord(wordKeys) }
        return changeCaseSelection()
    }

    private func changeCaseWord(_ keys: [TypedKey]) -> Bool {
        guard let pair = DynamicKeyMapping.convertKeys(keys),
              !pair.original.isEmpty, pair.original.contains(where: { $0.isLetter }) else { return false }
        return cycleCaseByBuffer(pair.original)
    }

    private func changeCaseSelection() -> Bool {
        caseWord = nil   // выделение сбрасывает буферный цикл
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        guard clipboardSession.begin() else { return false }
        isConverting = true
        var ok = false
        defer { if !ok { restoreClipboardNow() }; isConverting = false }

        guard let text = tryCopy(pasteboard), !text.isEmpty,
              text.contains(where: { $0.isLetter }) else { return false }
        let changed = TextConverter.nextCaseFromCurrent(text)
        guard changed != text else { return false }
        guard pasteText(changed, pasteboard: pasteboard) else { return false }
        // Скептик #29: НЕ выставляем reconvert-состояние (lastConverted/lastConvertedCount) — смена
        // регистра не должна попадать в путь реконверта (см. clearState() в onCaseHotkey).
        ok = true
        scheduleClipboardRestore()
        return true
    }

    /// Для выделения (без состояния): следующий регистр из текущего — нижний→ВЕРХНИЙ→Заглавный→нижний.
    private static func nextCaseFromCurrent(_ s: String) -> String {
        let letters = s.filter { $0.isLetter }
        if letters.allSatisfy({ $0.isLowercase }) { return s.uppercased() }
        if letters.allSatisfy({ $0.isUppercase }) {
            let cap = s.capitalized
            return cap == s ? s.lowercased() : cap   // односимвольные слова: capitalized==s → идём в нижний
        }
        return s.lowercased()
    }

    /// issue #29: смена регистра ВСЕЙ строки (когда включён «Convert whole line»). Обычные
    /// приложения — тем же AX-гейтом выделения строки, что и convertLine (#26). Повторные тапы
    /// циклят регистр: changeCaseSelection перечитывает текущую строку → nextCaseFromCurrent.
    func changeCaseLine() -> Bool {
        guard !isConverting else { return false }
        guard isFocusedElementEditable() else { rslog("changeCaseLine: non-editable — bail"); return false }
        simKey(keyCode: KC.left, flags: [.maskShift, .maskCommand]); usleep(60_000)
        if !focusedSelectionIsEmpty() {
            let ok = changeCaseSelection()
            if !ok { simKey(keyCode: KC.right, flags: []) }
            return ok
        }
        simKey(keyCode: KC.right, flags: [.maskShift, .maskCommand]); usleep(60_000)   // RTL: начало строки справа
        if !focusedSelectionIsEmpty() {
            let ok = changeCaseSelection()
            if !ok { simKey(keyCode: KC.left, flags: []) }
            return ok
        }
        return false
    }

    /// issue #29 (терминал): смена регистра всей строки по БУФЕРУ нажатий (нет OS-выделения).
    /// Циклит регистр как changeCaseWord, ключ — строка целиком (буфер живёт между тапами).
    func changeCaseLineBuffer(_ lineKeys: [TypedKey]) -> Bool {
        guard !isConverting, !lineKeys.isEmpty,
              let original = DynamicKeyMapping.lineString(from: lineKeys),
              !original.isEmpty, original.contains(where: { $0.isLetter }) else { return false }
        return cycleCaseByBuffer(original)
    }

    /// issue #16: конверсия в Spotlight. Обычный путь оставляет лишнюю букву, потому что
    /// Spotlight «съедает» первый Backspace серого автодополнения — счётчик нажатий (и даже
    /// стирание по РЕАЛЬНОЙ длине) расходится с полем. AX-элемент Spotlight к тому же флейкует.
    /// Надёжный путь БЕЗ Backspace и БЕЗ AX: выделить всё поле (Cmd+A), прочитать реальный
    /// текст через буфер (Cmd+C), сконвертировать и вставить поверх выделения (Cmd+A+Cmd+V) —
    /// selection-replace не задействует Backspace вовсе (проверено живым захватом 2026-08-01:
    /// «ghbdtn»→«привет» без лишних букв). Конвертит ВСЮ строку поиска (для однострочного поля
    /// Spotlight это ожидаемо). Реверсивно: повторный вызов конвертит назад. Буфер обмена
    /// сохраняется/восстанавливается. false → вызывающий падает на обычный путь.
    @MainActor
    func convertSpotlight(context: CombinedShiftContext? = nil, restorePrevious: Bool = false,
                          execution: CombinedShiftExecutionContext? = nil) -> Bool {
        guard context == nil || execution != nil else { return false }
        guard execution?.isValid() != false else { return false }
        guard !isConverting else { return false }
        isConverting = true
        let previousBufferMode = lastWasBuffer
        lastWasBuffer = false
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        guard clipboardSession.begin() else {
            lastWasBuffer = previousBufferMode
            isConverting = false
            return false
        }
        var conversionSucceeded = false
        defer {
            if !conversionSucceeded {
                restoreClipboardNow()
                if execution != nil { lastWasBuffer = previousBufferMode }
            }
            isConverting = false
        }

        // 1. Выделить всё поле и прочитать реальный текст (Cmd+A → Cmd+C).
        guard operationKey(keyCode: KC.letterA, flags: .maskCommand, execution: execution) else { return false }
        usleep(30_000)
        guard let text = tryCopy(pasteboard, execution: execution), !text.isEmpty else {
            rslog("spotlight convert: read failed")
            operationKey(keyCode: KC.right, flags: [], execution: execution)
            return false
        }

        // 2. Конверсия (char-level, авто-направление).
        let restoring = restorePrevious && !lastOriginal.isEmpty && text == lastConverted
        let converted = restoring ? lastOriginal
            : TextConverter.normalizedForInsert(execution != nil && SettingsManager.shared.convertByText
                ? DynamicKeyMapping.convertBidirectional(text, context: context)
                : DynamicKeyMapping.convert(text, context: context))
        guard converted != text else {
            rslog("spotlight convert: no-op — bail")
            operationKey(keyCode: KC.right, flags: [], execution: execution)
            return false
        }

        // 3. Заменить выделение вставкой (Cmd+A → Cmd+V) — без Backspace.
        guard operationKey(keyCode: KC.letterA, flags: .maskCommand, execution: execution) else { return false }
        usleep(30_000)
        guard pasteText(converted, pasteboard: pasteboard, execution: execution, replacing: text) else { return false }

        rslog("spotlight convert: \(text.count)→\(converted.count) chars (Cmd+A + clipboard)")
        lastConvertedCount = converted.count
        lastBoundaryCount = 0
        lastClipboardRTL = TextConverter.containsRTL(text) || TextConverter.containsRTL(converted)
        if context != nil {
            predictionLayouts = nil
            lastLayoutContext = restoring ? (lastLayoutContext?.reversed ?? context)
                : context.map { DynamicKeyMapping.resultContext(for: converted, requested: $0) }
            lastOriginal = text
            lastConverted = converted
        }
        conversionSucceeded = true
        scheduleClipboardRestore()
        return true
    }

    /// issue #16 (авто): замена последнего слова в Spotlight без Backspace. Автоконверсия
    /// решает по буферу верно, ломается лишь СТИРАНИЕ по счётчику (Spotlight ест Backspace
    /// серого автодополнения). Здесь выделяем слово по ГРАНИЦЕ (Shift+Option+Left — не по
    /// счётчику, поэтому расхождение не бьёт) и печатаем `converted` поверх выделения. Курсор
    /// стоит после слова + `boundaryCount` пробелов; уходим за пробелы, выделяем слово,
    /// заменяем, возвращаем курсор. Clipboard не нужен (печать поверх выделения, без Cmd+V).
    @MainActor
    func convertSpotlightWord(converted: String, boundaryCount: Int) -> Bool {
        guard !isConverting, !converted.isEmpty else { return false }
        isConverting = true
        lastWasBuffer = false   // реконверт авто-слова в Spotlight не поддерживаем
        rslog("spotlight auto: word-select replace (bc=\(boundaryCount))")
        injectQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<boundaryCount { self.simKey(keyCode: KC.left, flags: []) }   // за пробелы к концу слова
            usleep(15_000)
            self.simKey(keyCode: KC.left, flags: [.maskShift, .maskAlternate])        // выделить слово (по границе)
            usleep(15_000)
            self.insertText(converted)                                                // печать поверх выделения = замена
            usleep(15_000)
            for _ in 0..<boundaryCount { self.simKey(keyCode: KC.right, flags: []) }   // вернуть курсор за пробелы
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    /// Повторная конвертация (второй триггер) — на тот движок, которым делали последнюю.
    func reconvert(context: CombinedShiftContext? = nil, execution: CombinedShiftExecutionContext? = nil) -> Bool {
        guard context == nil || execution != nil else { return false }
        guard !isConverting else { return false }
        if lastWasBuffer {
            guard !lastConverted.isEmpty else { return false }
            if let execution {
                guard performNativeBufferEdit(original: lastConverted, replacement: lastOriginal, execution: execution) else { return false }
                swap(&lastOriginal, &lastConverted)
                if let layouts = predictionLayouts {
                    predictionLayouts = (layouts.target, layouts.source)
                } else { lastLayoutContext = lastLayoutContext?.reversed ?? context }
                return true
            }
            isConverting = true
            rslog("buffer reconvert")
            let bsCount = lastConverted.count
            let insert = lastOriginal
            let tmp = lastOriginal; lastOriginal = lastConverted; lastConverted = tmp
            lastLayoutContext = lastLayoutContext?.reversed ?? context
            injectQueue.async { [weak self] in
                guard let self else { return }
                self.backspace(bsCount)
                usleep(20_000)
                self.insertText(insert)
                Task { @MainActor in self.isConverting = false }
            }
            return true
        }
        return reconvertViaClipboard(context: context, execution: execution)
    }

    /// Конвертация через буфер обмена (фолбэк: выделенный мышью текст и т.п.).
    /// Сначала проверяет выделение, потом пробует слово по счётчику.
    func convertViaClipboard(wordLength: Int, prevWordLength: Int, boundaryCount: Int, context: CombinedShiftContext? = nil,
                             execution: CombinedShiftExecutionContext? = nil) -> Bool {
        guard context == nil || execution != nil else { return false }
        guard execution?.isValid() != false else { return false }
        if context != nil && wordLength == 0 && prevWordLength == 0 && !hasFocusedTextSelection() { return false }
        guard !isConverting else {
            rslog("convert: skipped — already converting")
            return false
        }
        isConverting = true
        let previousBufferMode = lastWasBuffer
        lastWasBuffer = false
        defer { isConverting = false }

        if !isFocusedElementEditable() {
            rslog("convert: element may not be editable, trying anyway")
        }
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        // Retain the original only while we still own its temporary replacement.
        guard clipboardSession.begin() else { lastWasBuffer = previousBufferMode; return false }

        var conversionSucceeded = false
        defer {
            // Любой ранний выход без успеха обязан вернуть буфер пользователю —
            // иначе clipboard остаётся пустым или с конвертированным текстом.
            if !conversionSucceeded {
                restoreClipboardNow()
                if execution != nil { lastWasBuffer = previousBufferMode }
            }
        }

        // --- Попытка 1: уже есть выделенный текст? ---
        if let text = tryCopy(pasteboard, execution: execution) {
            rslog("convert: selection len=\(text.count)")
            // issue #22: A «по тексту» (тотальный флип) → B «умная» по-словная (по умолч.) →
            // классика (одностороннее по раскладке, если умная выключена).
            let converted = selectionConversion(text, context: context)
            // Конверсия не изменила текст (пара не разрешилась / комбинирующие знаки —
            // см. bail'ы в DynamicKeyMapping) — не гоняем вставку впустую.
            if converted == text {
                rslog("convert: no-op conversion — bail")
                return false
            }
            guard pasteText(converted, pasteboard: pasteboard, execution: execution, replacing: text) else { return false }
            // Курсор остаётся в конце вставленного текста — не пере-выделяем,
            // чтобы следующий ввод не затёр результат. Для reconvert используется
            // унифицированный путь через selectBack(lastConvertedCount).
            lastConvertedCount = converted.count
            lastBoundaryCount = 0
            // issue #22: сохраняем пару до/после — реконверт восстанавливает ТОЧНО,
            // а не пере-конвертирует (умный/тотальный флип односторонней convert не
            // инвертируется, особенно смешанный результат).
            lastOriginal = text
            lastConverted = converted
            predictionLayouts = nil
            lastLayoutContext = context.map { DynamicKeyMapping.resultContext(for: converted, requested: $0) }
            // RTL: реконверт этого результата шёл бы стрелочной селекцией, а стрелки
            // двигают каретку ВИЗУАЛЬНО — в RTL выделился бы не тот диапазон и
            // конверсия заменила бы чужой текст (ревью-находка). Помечаем, чтобы
            // reconvertViaClipboard отказался.
            lastClipboardRTL = TextConverter.containsRTL(text) || TextConverter.containsRTL(converted)
            conversionSucceeded = true
            scheduleClipboardRestore()
            return true
        }
        guard execution?.isValid() != false else { return false }

        // RTL-пара: счётчиковый путь выделяет Shift+Left'ами, а в RTL «влево» —
        // логически вперёд: выделили бы не то и заменили чужой текст. Точность
        // важнее полноты — отказ (буферный движок ивриту не нужен только при
        // выделении мышью, а это Попытка 1 выше).
        if let l = LayoutSwitcher.currentAndOppositeLanguage(context: context),
           LayoutDetector.isHebrew(l.current) || LayoutDetector.isHebrew(l.opposite) {
            rslog("convert: hebrew pair — count-based clipboard path unsafe, bail")
            return false
        }

        // --- Попытка 2: выделяем слово по счётчику ---
        let charCount: Int
        let usedBoundary: Int

        if wordLength > 0 {
            charCount = wordLength
            usedBoundary = 0
        } else if prevWordLength > 0 && boundaryCount > 0 {
            guard moveLeft(boundaryCount, execution: execution) else { return false }
            charCount = prevWordLength
            usedBoundary = boundaryCount
        } else {
            rslog("convert: nothing to convert (wordLen=\(wordLength) prevLen=\(prevWordLength))")
            return false
        }

        rslog("convert: selecting \(charCount) chars (boundary=\(usedBoundary))")
        guard selectBack(charCount, execution: execution) else { return false }
        usleep(50_000)

        guard let text = tryCopy(pasteboard, execution: execution) else {
            rslog("convert: copy failed")
            operationKey(keyCode: KC.right, flags: [], execution: execution)
            moveRight(usedBoundary, execution: execution)
            return false
        }

        rslog("convert: word len=\(text.count)")
        // Счётчиковый путь — одно последнее слово; направление по раскладке (как раньше),
        // либо тотальный флип при тумблере «по тексту» (A). Умный путь — только для выделения.
        let converted = TextConverter.normalizedForInsert(
            SettingsManager.shared.convertByText
                ? DynamicKeyMapping.convertBidirectional(text, context: context)
                : DynamicKeyMapping.convert(text, context: context))
        if context != nil && converted == text {
            operationKey(keyCode: KC.right, flags: [], execution: execution)
            moveRight(usedBoundary, execution: execution)
            return false
        }
        guard pasteText(converted, pasteboard: pasteboard, execution: execution, replacing: text) else { return false }

        guard moveRight(usedBoundary, execution: execution) else { return false }

        lastConvertedCount = converted.count
        lastBoundaryCount = usedBoundary
        lastOriginal = text          // issue #22: точное восстановление в reconvert
        lastConverted = converted
        predictionLayouts = nil
        lastLayoutContext = context.map { DynamicKeyMapping.resultContext(for: converted, requested: $0) }
        // Симметрично Попытке 1: актуализируем флаг, чтобы прошлое RTL-выделение
        // не блокировало реконверт свежей LTR-конверсии (залипший флаг).
        lastClipboardRTL = TextConverter.containsRTL(text) || TextConverter.containsRTL(converted)
        conversionSucceeded = true
        scheduleClipboardRestore()
        return true
    }

    /// Повторная конвертация через буфер обмена (фолбэк).
    private func reconvertViaClipboard(context: CombinedShiftContext? = nil, execution: CombinedShiftExecutionContext? = nil) -> Bool {
        guard execution?.isValid() != false else { return false }
        guard !isConverting else {
            rslog("reconvert: skipped — already converting")
            return false
        }
        isConverting = true
        defer { isConverting = false }

        rslog("reconvert: lastCount=\(lastConvertedCount) boundary=\(lastBoundaryCount)")
        guard lastConvertedCount > 0 else { return false }
        // RTL-результат: стрелочная селекция в RTL выделит не тот диапазон (см. convert).
        guard !lastClipboardRTL else {
            rslog("reconvert: RTL selection — arrow-based path unsafe, bail")
            return false
        }

        let pasteboard = NSPasteboard.general
        // Отменяем отложенное восстановление clipboard — мы ещё работаем
        cancelClipboardRestore()
        // A new user copy starts a fresh restore transaction, even during reconvert.
        guard clipboardSession.begin() else { return false }

        var conversionSucceeded = false
        defer { if !conversionSucceeded { restoreClipboardNow() } }

        guard moveLeft(lastBoundaryCount, execution: execution) else { return false }

        guard selectBack(lastConvertedCount, execution: execution) else { return false }
        usleep(80_000)  // дать приложению обработать выделение

        guard let text = tryCopy(pasteboard, execution: execution) else {
            rslog("reconvert: copy failed, count=\(lastConvertedCount)")
            operationKey(keyCode: KC.right, flags: [], execution: execution)
            moveRight(lastBoundaryCount, execution: execution)
            scheduleClipboardRestore()
            return false
        }

        guard CombinedShiftExecutionPolicy.permitsClipboardUndo(copiedText: text,
            lastConverted: lastConverted, native: execution != nil) else {
            operationKey(keyCode: KC.right, flags: [], execution: execution)
            moveRight(lastBoundaryCount, execution: execution)
            return false  // native defer restores clipboard; history remains untouched
        }

        // issue #22: если выделенное совпадает с прошлым результатом — ВОССТАНАВЛИВАЕМ
        // исходник точно (умный/тотальный флип односторонней convert не инвертируется).
        // Иначе (текст изменился) — безопасный фолбэк на обычную одностороннюю конверсию.
        let converted: String
        let reverseContext = lastLayoutContext?.reversed ?? context
        let restoring = text == lastConverted && !lastOriginal.isEmpty
        if restoring {
            converted = lastOriginal
            rslog("reconvert: restored original (len=\(converted.count))")
        } else {
            converted = TextConverter.normalizedForInsert(DynamicKeyMapping.convert(text, context: reverseContext))
            rslog("reconvert: len=\(text.count) → converting (fallback)")
        }
        guard pasteText(converted, pasteboard: pasteboard, execution: execution, replacing: text) else { return false }

        guard moveRight(lastBoundaryCount, execution: execution) else { return false }

        if restoring { swap(&lastOriginal, &lastConverted) }
        predictionLayouts = nil
        lastLayoutContext = !restoring && execution != nil
            ? reverseContext.map { DynamicKeyMapping.resultContext(for: converted, requested: $0) } : reverseContext
        lastConvertedCount = converted.count
        conversionSucceeded = true
        scheduleClipboardRestore()
        return true
    }

    func clearState() {
        lastConvertedCount = 0
        lastBoundaryCount = 0
        lastOriginal = ""
        lastConverted = ""
        lastWasBuffer = false
        lastClipboardRTL = false
        lastLayoutContext = nil
        predictionLayouts = nil
    }

    // MARK: - Private

    /// Native mode prepares a bounded batch, checks revision, exact AX field, caret and original
    /// suffix immediately before the first Backspace, then posts synchronously without sleeps.
    /// There is no queued job that can delete a subsequently typed character or another field.
    private func performNativeBufferEdit(original: String, replacement: String,
                                         execution: CombinedShiftExecutionContext) -> Bool {
        guard !isConverting, !original.isEmpty, original.count <= 512,
              !replacement.isEmpty, replacement.utf16.count <= 4096, let source = makeSource() else { return false }
        isConverting = true
        defer { isConverting = false }
        var events: [CGEvent] = []
        for _ in 0..<original.count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: KC.backspace, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: KC.backspace, keyDown: false) else { return false }
            down.flags = []; up.flags = []
            events.append(contentsOf: [down, up])
        }
        let packets = CombinedShiftUnicode.chunks(replacement)
        guard packets.flatMap({ $0 }) == Array(replacement.utf16) else { return false }
        for units in packets {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.flags = []; up.flags = []
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            guard CombinedShiftUnicode.payloadMatches(down, expected: units),
                  CombinedShiftUnicode.payloadMatches(up, expected: units) else { return false }
            events.append(contentsOf: [down, up])
        }
        guard execution.canReplaceBuffer(original: original) else { return false }
        for event in events { event.postToPid(execution.focus.processID) }
        return true
    }

    /// Стирает n символов (Backspace × n) — для движка перепечатки.
    /// Пауза минимальная: порядок доставки гарантирует системная очередь HID, а при
    /// прежних 3мс/клавишу стирание длинного слова растягивалось на кадры отрисовки —
    /// пользователь видел «стёрли-и-перепечатали» вместо мгновенной замены.
    nonisolated private func backspace(_ n: Int, destinationProcessID: Int32? = nil) {
        for _ in 0..<n {
            simKey(keyCode: KC.backspace, flags: [], destinationProcessID: destinationProcessID)
            usleep(500)
        }
    }

    /// Впечатывает строку напрямую (юникод-вставка), без буфера обмена.
    nonisolated private func insertText(_ text: String, destinationProcessID: Int32? = nil) {
        guard !text.isEmpty, let source = makeSource() else { return }
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        if let processID = destinationProcessID {
            down.postToPid(processID)
            up.postToPid(processID)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Вставляет текст через Cmd+V и ждёт завершения
    @discardableResult
    private func pasteText(_ text: String, pasteboard: NSPasteboard, execution: CombinedShiftExecutionContext? = nil,
                           replacing original: String? = nil) -> Bool {
        guard execution?.isValid() != false else { return false }
        if let execution, let original, !execution.focus.selectedTextMatches(original) { return false }
        guard clipboardSession.writeTemporaryText(text) else { return false }
        guard clipboardSession.permitsPaste() else { return false }
        guard operationKey(keyCode: KC.letterV, flags: .maskCommand, execution: execution) else { return false }
        usleep(150_000) // 150мс — дать приложению вставить текст и обновить курсор
        return execution?.isValid() != false
    }

    /// Canceling also invalidates already-enqueued work from an earlier transaction.
    private func cancelClipboardRestore() {
        clipboardRestoreGeneration &+= 1
        clipboardRestoreWork?.cancel()
        clipboardRestoreWork = nil
    }

    private func restoreClipboardNow() {
        cancelClipboardRestore()
        clipboardSession.restoreIfOwned()
    }

    /// Quit/update follows the same ownership check as an ordinary timer.
    func flushPendingClipboardRestore() {
        restoreClipboardNow()
    }

    private func scheduleClipboardRestore() {
        cancelClipboardRestore()
        guard clipboardSession.hasSnapshot else { return }
        let generation = clipboardRestoreGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.clipboardRestoreGeneration == generation else { return }
            self.restoreClipboardNow()
        }
        clipboardRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Копирует выделенный текст. Делает до 3 попыток (Cmd+C не всегда срабатывает с первого раза)
    private func tryCopy(_ pasteboard: NSPasteboard, execution: CombinedShiftExecutionContext? = nil) -> String? {
        for attempt in 0..<3 {
            guard execution?.isValid() != false else { return nil }
            let focus = execution?.focus ?? NSWorkspace.shared.frontmostApplication.flatMap {
                CombinedShiftFocus.capture(processID: $0.processIdentifier)
            }
            guard let focus, focus.isCurrent(),
                  let oldCount = clipboardSession.clearForCopy() else { return nil }

            guard operationKey(keyCode: KC.letterC, flags: .maskCommand, execution: execution) else { return nil }
            usleep(attempt == 0 ? 80_000 : 120_000)
            guard execution?.isValid() != false else { return nil }

            let copyCount = pasteboard.changeCount
            if copyCount != oldCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty {
                guard focus.isCurrent(), focus.selectedTextMatches(text), execution?.isValid() != false,
                      clipboardSession.claimVerifiedCopy(changeCount: copyCount) else { return nil }
                return text
            }
            usleep(50_000) // пауза перед retry
        }
        return nil
    }

    /// Выделяет N символов влево (Shift+Left × N)
    @discardableResult
    private func selectBack(_ count: Int, execution: CombinedShiftExecutionContext? = nil) -> Bool {
        for _ in 0..<count {
            guard operationKey(keyCode: KC.left, flags: .maskShift, execution: execution) else { return false }
            usleep(1_000)
        }
        return true
    }

    /// Сдвигает курсор влево на N символов
    @discardableResult
    private func moveLeft(_ count: Int, execution: CombinedShiftExecutionContext? = nil) -> Bool {
        for _ in 0..<count {
            guard operationKey(keyCode: KC.left, flags: [], execution: execution) else { return false }
            usleep(1_000)
        }
        return true
    }

    /// Сдвигает курсор вправо на N символов (восстановление границ-пробелов)
    @discardableResult
    private func moveRight(_ count: Int, execution: CombinedShiftExecutionContext? = nil) -> Bool {
        for _ in 0..<count {
            guard operationKey(keyCode: KC.right, flags: [], execution: execution) else { return false }
            usleep(1_000)
        }
        return true
    }

    @discardableResult
    private func operationKey(keyCode: UInt16, flags: CGEventFlags,
                               execution: CombinedShiftExecutionContext? = nil) -> Bool {
        guard execution?.isValid() != false else { return false }
        simKey(keyCode: keyCode, flags: flags, destinationProcessID: execution?.focus.processID)
        return true
    }

    /// Симулирует нажатие клавиши с маркером (чтобы наш monitor игнорировал)
    nonisolated private func simKey(keyCode: UInt16, flags: CGEventFlags, destinationProcessID: Int32? = nil) {
        guard let source = makeSource() else { return }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        keyDown.flags = flags
        keyUp.flags = flags

        if let processID = destinationProcessID {
            keyDown.postToPid(processID)
            keyUp.postToPid(processID)
        } else {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
