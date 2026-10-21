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
        RuntimeDiagnostics.record(.clipboardBegin)
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
        guard pasteboard.changeCount == count else { RuntimeDiagnostics.record(.clipboardBeginRefused); return false }
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

/// Only a confirmed read-back may update conversion or prediction history.
/// AX errors after a setter are ambiguous: the caller retains the source for an
/// explicit recovery gesture, and never tries a second delivery mechanism.
enum CombinedShiftAXEditResult: Equatable {
    case refused, confirmed, unknown
}

@MainActor
struct CombinedShiftSelectionAccess {
    let isValid: () -> Bool
    let selection: () -> CombinedShiftSelectionSnapshot?
    let writeSelection: (String) -> Bool?
    let replacementIsCurrent: (CombinedShiftSelectionSnapshot, String) -> Bool
}

@MainActor
enum CombinedShiftSelectionEditor {
    static func replace(original: CombinedShiftSelectionSnapshot, replacement: String,
                        access: CombinedShiftSelectionAccess) -> CombinedShiftAXEditResult {
        guard !replacement.isEmpty, replacement != original.text,
              access.isValid(), let selected = access.selection(),
              original.matches(range: selected.range, text: selected.text), access.isValid() else { return .refused }
        guard let written = access.writeSelection(replacement) else {
            RuntimeDiagnostics.record(.selectionAXUnsupported)
            return .refused
        }
        RuntimeDiagnostics.record(written ? .selectionAXWritePosted : .selectionAXWriteRefused)
        // AX success is not proof of delivery. Conversely, an error does not
        // prove that the receiving editor left the field untouched.
        guard access.isValid(), access.replacementIsCurrent(original, replacement), access.isValid() else {
            RuntimeDiagnostics.record(.selectionAXMutationUnknown)
            return .unknown
        }
        RuntimeDiagnostics.record(.selectionAXWriteVerified)
        return .confirmed
    }
}

/// A suffix edit first verifies the original collapsed caret and exact source,
/// then selects only that fixed range on the captured AX element. No key queue,
/// clipboard transaction or whole-field AXValue setter is involved.
@MainActor
struct CombinedShiftSuffixAccess {
    let isValid: () -> Bool
    let selectionRange: () -> CFRange?
    let text: (CFRange) -> String?
    let canWriteSelection: () -> Bool
    let select: (CFRange) -> Bool
    let selected: CombinedShiftSelectionAccess
}

@MainActor
enum CombinedShiftSuffixEditor {
    static func replace(original: CombinedShiftSelectionSnapshot, replacement: String,
                        expectedSelection: CFRange, access: CombinedShiftSuffixAccess) -> CombinedShiftAXEditResult {
        guard access.isValid(), let selection = access.selectionRange(),
              selection.location == expectedSelection.location, selection.length == expectedSelection.length,
              access.text(original.range) == original.text, access.canWriteSelection(), access.isValid() else { return .refused }
        var attemptedSelection = false
        if selection.location != original.range.location || selection.length != original.range.length {
            attemptedSelection = true
            guard access.select(original.range) else {
                return reconcileRefusedSelection(original: original, expected: expectedSelection, access: access)
            }
        }
        let result = CombinedShiftSelectionEditor.replace(original: original, replacement: replacement, access: access.selected)
        guard result != .confirmed, attemptedSelection else { return result }
        let reconciled = reconcileRefusedSelection(original: original, expected: expectedSelection, access: access)
        // A text setter has already been attempted on UNKNOWN. Even when the
        // unchanged source lets us safely restore its caret, retain that unknown
        // transaction rather than authorizing another automatic write.
        return result == .unknown ? .unknown : reconciled
    }

    /// A failed/unsupported text write must not leave an automatic word selected,
    /// since the next ordinary keystroke could overwrite it. Never roll back a
    /// selection blindly: a changed field, source or revision means UNKNOWN.
    private static func reconcileRefusedSelection(original: CombinedShiftSelectionSnapshot,
                                                   expected: CFRange, access: CombinedShiftSuffixAccess) -> CombinedShiftAXEditResult {
        guard access.isValid(), let current = access.selectionRange(),
              access.text(original.range) == original.text, access.isValid() else { return .unknown }
        if current.location == expected.location && current.length == expected.length { return .refused }
        guard current.location == original.range.location, current.length == original.range.length,
              access.isValid() else { return .unknown }
        _ = access.select(expected) // a false AX response can still have moved the caret
        guard access.isValid(), let restored = access.selectionRange(),
              restored.location == expected.location, restored.length == expected.length,
              access.text(original.range) == original.text, access.isValid() else { return .unknown }
        return .refused
    }
}

/// Recovery keeps the first complete source. Legacy short snapshots are merged
/// into the prepared whole field once; later unknown attempts cannot replace it.
enum NativeWholeFieldRecovery {
    static func originalText(prepared: String, replacedRange: Range<Int>, preservedSource: String? = nil,
                             preservedIsWholeField: Bool = false) -> String? {
        let limit = NativeFieldEditPlan.maximumFieldUnits
        guard !prepared.isEmpty, prepared.utf16.count <= limit else { return nil }
        guard let preservedSource else { return prepared }
        guard !preservedSource.isEmpty, preservedSource.utf16.count <= limit else { return nil }
        if preservedIsWholeField { return preservedSource }
        let units = Array(prepared.utf16)
        guard replacedRange.lowerBound >= 0, replacedRange.upperBound <= units.count else { return nil }
        let merged = Array(units[..<replacedRange.lowerBound]) + Array(preservedSource.utf16)
            + Array(units[replacedRange.upperBound...])
        guard merged.count <= limit, NativeFieldEditPlan.isWellFormedUTF16(merged) else { return nil }
        return String(decoding: merged, as: UTF16.self)
    }
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
    private var lastSelectionOrigin: CombinedShiftFocus?
    private var lastSelectionRange: CFRange?
    private var lastWasAXEdit = false
    private struct UnconfirmedAXEdit {
        let id = UUID()
        let focus: CombinedShiftFocus
        let original: CombinedShiftSelectionSnapshot
        let replacement: String
        let layoutContext: CombinedShiftContext?
        let predictionLayouts: (source: String, target: String)?
        let requiresExplicitSelection: Bool
        let lastNativeObservation: NativeFieldObservation?
        init(focus: CombinedShiftFocus, original: CombinedShiftSelectionSnapshot, replacement: String,
             layoutContext: CombinedShiftContext?, predictionLayouts: (source: String, target: String)?,
             requiresExplicitSelection: Bool = false, lastNativeObservation: NativeFieldObservation? = nil) {
            self.focus = focus; self.original = original; self.replacement = replacement
            self.layoutContext = layoutContext; self.predictionLayouts = predictionLayouts
            self.requiresExplicitSelection = requiresExplicitSelection
            self.lastNativeObservation = lastNativeObservation
        }
    }
    // Kept separately from confirmed history. clearState intentionally does not
    // erase an ambiguous write's source. Only an explicit matching-field manual
    // gesture may reconcile/recover it; automatic editing remains blocked.
    private var unconfirmedAXEdits: [UnconfirmedAXEdit] = []
    struct RecoveryOriginal {
        let id: UUID
        let text: String
    }
    private static let maximumUnconfirmedFields = 8
    private static let maximumRecoveryUTF16Units = 1_048_576
    private func canRetainAXSource(original: String, replacement: String) -> Bool {
        canRetainRecoveryUnits(original.utf16.count + replacement.utf16.count)
    }
    private func canRetainRecoveryUnits(_ proposed: Int, replacing focus: CombinedShiftFocus? = nil) -> Bool {
        let retained = unconfirmedAXEdits.reduce(0) { total, edit in
            if let focus, edit.focus.processID == focus.processID, CFEqual(edit.focus.element, focus.element) { return total }
            return total + edit.original.text.utf16.count + edit.replacement.utf16.count
        }
        return proposed >= 0 && proposed <= Self.maximumRecoveryUTF16Units - retained
    }
    var hasUnconfirmedAXEdit: Bool { !unconfirmedAXEdits.isEmpty }
    /// Available only to an explicit menu action. Never automatically copied,
    /// logged or persisted; survives clearState and oversized native recovery.
    var unconfirmedOriginals: [RecoveryOriginal] { unconfirmedAXEdits.map { RecoveryOriginal(id: $0.id, text: $0.original.text) } }
    func hasUnconfirmedAXEdit(in focus: CombinedShiftFocus) -> Bool {
        unconfirmedAXEdits.contains { $0.focus.processID == focus.processID && CFEqual($0.focus.element, focus.element) }
    }
    private func retainUnconfirmed(_ edit: UnconfirmedAXEdit) {
        removeUnconfirmed(in: edit.focus)
        unconfirmedAXEdits.append(edit)
    }
    private func removeUnconfirmed(in focus: CombinedShiftFocus) {
        unconfirmedAXEdits.removeAll { $0.focus.processID == focus.processID && CFEqual($0.focus.element, focus.element) }
    }
    /// Exact layout of the inserted result, also after undo; callers must not toggle active source.
    var lastResultLayoutID: String? { predictionLayouts?.target ?? lastLayoutContext?.targetLayoutID }
    var hasReconversionState: Bool { hasUnconfirmedAXEdit || !lastConverted.isEmpty || lastConvertedCount > 0 }

    /// The only automatic edit entry point. It cannot fall back to clipboard,
    /// a global key queue or deletion based solely on a remembered character count.
    func replaceVerifiedSuffix(original: String, replacement: String, sourceLayoutID: String,
                               resultLayoutID: String, execution: CombinedShiftExecutionContext,
                               inputBarrierIsActive: (() -> Bool)? = nil, forceNativeFixture: Bool = false) -> Bool {
        let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let route = AutomaticEditorPolicy.route(bundleID: appID, suffix: original, sourceID: sourceLayoutID)
        guard route != .blocked else { RuntimeDiagnostics.record(.nativeAutoBlocked); return false }
        let usesNative = forceNativeFixture || route == .nativeCanary || route == .nativeVerified
        if usesNative {
            RuntimeDiagnostics.beginNativeFocusReadAttempt()
        }
        if forceNativeFixture || route == .nativeCanary {
            AXUIElementSetMessagingTimeout(execution.focus.element, 0.003)
            defer { AXUIElementSetMessagingTimeout(execution.focus.element, 0.05) }
            guard execution.isValid(timeout: 0.003), original == "ghbd", replacement == "прив", sourceLayoutID == "com.apple.keylayout.US",
                  AutomaticEditorPolicy.fieldMatchesFixture(execution.focus),
                  CommandLine.arguments.contains("--diagnostic-native-canary"),
                  (!forceNativeFixture || (appID == "com.apple.TextEdit" && CommandLine.arguments.contains("--diagnostic-panel")))
            else { RuntimeDiagnostics.record(.nativeAutoBlocked); return false }
        }
        guard !hasUnconfirmedAXEdit(in: execution.focus),
              unconfirmedAXEdits.count < Self.maximumUnconfirmedFields else {
            RuntimeDiagnostics.record(.unconfirmedEditBlocked); return false
        }
        guard !isConverting, original != replacement, !sourceLayoutID.isEmpty, !resultLayoutID.isEmpty,
              let caret = execution.focus.initialSelection, caret.length == 0,
              caret.location >= original.utf16.count,
              let snapshot = CombinedShiftSelectionSnapshot(
                  range: CFRange(location: caret.location - original.utf16.count, length: original.utf16.count), text: original)
        else { return false }
        let recoveryUnits = usesNative ? NativeFieldEditPlan.maximumFieldUnits * 2
            : original.utf16.count + replacement.utf16.count
        guard canRetainRecoveryUnits(recoveryUnits) else {
            RuntimeDiagnostics.record(.unconfirmedEditBlocked); return false
        }
        isConverting = true
        defer { isConverting = false }
        let result: CombinedShiftAXEditResult
        if usesNative {
            guard let inputBarrierIsActive, inputBarrierIsActive(),
                  (route != .nativeCanary || AutomaticEditorPolicy.claimCanary()) else { return false }
            result = replaceNativeRange(original: snapshot, replacement: replacement,
                expectedSelection: caret, execution: execution, inputBarrierIsActive: inputBarrierIsActive,
                context: nil, layouts: (sourceLayoutID, resultLayoutID))
            guard result == .confirmed else {
                if result == .unknown { RuntimeDiagnostics.record(.nativeAutoUncertain) }
                return false // the native helper already retained the whole-field source
            }
            RuntimeDiagnostics.record(.nativeAutoVerified)
        } else {
            result = replaceAXRange(original: snapshot, replacement: replacement,
                expectedSelection: caret, execution: execution, inputBarrierIsActive: inputBarrierIsActive)
        }
        guard result == .confirmed else {
            if result == .unknown {
                retainUnconfirmed(UnconfirmedAXEdit(focus: execution.focus, original: snapshot,
                    replacement: replacement, layoutContext: nil, predictionLayouts: (sourceLayoutID, resultLayoutID)))
                RuntimeDiagnostics.record(.autoAXMutationUnknown)
            } else if !execution.focus.canWriteSelectedText() { RuntimeDiagnostics.record(.autoAXUnsupported) }
            return false
        }
        lastOriginal = original
        lastConverted = replacement
        lastWasBuffer = true
        lastWasAXEdit = !usesNative
        lastConvertedCount = 0
        lastBoundaryCount = 0
        lastLayoutContext = nil
        predictionLayouts = (sourceLayoutID, resultLayoutID)
        lastSelectionOrigin = execution.focus
        lastSelectionRange = CFRange(location: snapshot.range.location, length: replacement.utf16.count)
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

    func selectionConversion(_ text: String, context: CombinedShiftContext?, normalize: Bool = true) -> String {
        let settings = SettingsManager.shared
        var converted = settings.convertByText ? DynamicKeyMapping.convertBidirectional(text, context: context)
            : settings.smartConversion ? SmartConvert.selection(text, context: context)
            : DynamicKeyMapping.convert(text, context: context)
        // Pasted selections have no reliable relationship to the active input
        // source. An explicit manual request may flip their actual script when
        // the requested direction leaves every character unchanged.
        if context != nil && converted == text {
            converted = DynamicKeyMapping.convertBidirectional(text, context: context)
        }
        return normalize ? TextConverter.normalizedForInsert(converted) : converted
    }

    /// Explicit selections use their immutable first-tap AX range, without
    /// Cmd+C, Cmd+V, or a delayed clipboard-restore transaction.
    func convertSelection(context: CombinedShiftContext, execution: CombinedShiftExecutionContext,
                          restorePrevious: Bool = false,
                          inputBarrierIsActive: (() -> Bool)? = nil) -> Bool {
        guard !isConverting, inputBarrierIsActive?() ?? true else { return false }
        if inputBarrierIsActive != nil { AXUIElementSetMessagingTimeout(execution.focus.element, 0.003) }
        defer { if inputBarrierIsActive != nil { AXUIElementSetMessagingTimeout(execution.focus.element, 0.05) } }
        if hasUnconfirmedAXEdit(in: execution.focus) {
            return recoverUnconfirmedAXEdit(execution: execution, inputBarrierIsActive: inputBarrierIsActive)
        }
        guard unconfirmedAXEdits.count < Self.maximumUnconfirmedFields else {
            RuntimeDiagnostics.record(.unconfirmedEditBlocked); return false
        }
        if inputBarrierIsActive != nil {
            guard let selection = execution.focus.initialSelection, selection.length > 0,
                  selection.length <= NativeFieldEditPlan.maximumSelectedReplacementUnits else {
                RuntimeDiagnostics.record(.selectionSnapshotUnavailable); return false
            }
        }
        guard execution.isValid(timeout: inputBarrierIsActive == nil ? 0.05 : 0.003), let original = execution.focus.selectionSnapshot() else {
            RuntimeDiagnostics.record(.selectionSnapshotUnavailable); return false
        }
        let restoring = restorePrevious && lastWasAXEdit && !lastOriginal.isEmpty && original.text == lastConverted
            && lastSelectionOrigin.map { $0.processID == execution.focus.processID
                && CFEqual($0.element, execution.focus.element) } == true
            && lastSelectionRange.map { $0.location == original.range.location
                && $0.length == original.range.length } == true
        let replacement = restoring ? lastOriginal : selectionConversion(original.text, context: context)
        guard replacement != original.text, !replacement.isEmpty else { return false }
        guard canRetainAXSource(original: original.text, replacement: replacement) else {
            RuntimeDiagnostics.record(.unconfirmedEditBlocked); return false
        }
        let resultContext = restoring ? (lastLayoutContext?.reversed ?? context)
            : DynamicKeyMapping.resultContext(for: replacement, requested: context)
        isConverting = true
        defer { isConverting = false }
        let result: CombinedShiftAXEditResult
        if let inputBarrierIsActive {
            result = replaceNativeRange(original: original, replacement: replacement,
                expectedSelection: original.range, execution: execution, inputBarrierIsActive: inputBarrierIsActive,
                context: resultContext, layouts: nil)
        } else {
            result = CombinedShiftSelectionEditor.replace(original: original, replacement: replacement,
                access: selectionAccess(execution))
        }
        guard result == .confirmed else {
            if result == .unknown, inputBarrierIsActive == nil {
                retainUnconfirmed(UnconfirmedAXEdit(focus: execution.focus, original: original,
                    replacement: replacement, layoutContext: resultContext, predictionLayouts: nil))
            }
            return false
        }
        commitAXEdit(original: original, replacement: replacement, focus: execution.focus,
            context: resultContext, layouts: nil)
        return true
    }

    private func selectionAccess(_ execution: CombinedShiftExecutionContext,
        inputBarrierIsActive: (() -> Bool)? = nil) -> CombinedShiftSelectionAccess {
        CombinedShiftSelectionAccess(isValid: {
            (inputBarrierIsActive?() ?? true) && execution.isValid() && (inputBarrierIsActive?() ?? true)
        },
            selection: { execution.focus.currentSelectionSnapshot() },
            writeSelection: { execution.focus.writeSelectedText($0) },
            replacementIsCurrent: { execution.focus.replacementIsCurrent(original: $0, replacement: $1) })
    }

    private func replaceAXRange(original: CombinedShiftSelectionSnapshot, replacement: String,
                                expectedSelection: CFRange, execution: CombinedShiftExecutionContext,
                                inputBarrierIsActive: (() -> Bool)? = nil) -> CombinedShiftAXEditResult {
        if NSRunningApplication(processIdentifier: execution.focus.processID)?.bundleIdentifier == AutomaticEditorPolicy.codexBundleID,
           (expectedSelection.location != original.range.location || expectedSelection.length != original.range.length) {
            RuntimeDiagnostics.record(.nativeAutoBlocked)
            return .refused // never request a delayed programmatic selection in Codex
        }
        return CombinedShiftSuffixEditor.replace(original: original, replacement: replacement,
            expectedSelection: expectedSelection,
            access: CombinedShiftSuffixAccess(isValid: {
                (inputBarrierIsActive?() ?? true) && execution.isValid() && (inputBarrierIsActive?() ?? true)
            },
                selectionRange: { execution.focus.selectionRange() },
                text: { execution.focus.text(in: $0) },
                canWriteSelection: { execution.focus.canWriteSelectedText() },
                select: { execution.focus.select(range: $0) },
                selected: selectionAccess(execution, inputBarrierIsActive: inputBarrierIsActive)))
    }

    /// A supplied input lease selects only verified native editing. Refusal or
    /// uncertainty never authorizes an AX setter, clipboard or delete-first batch.
    private func replaceNativeRange(original: CombinedShiftSelectionSnapshot, replacement: String,
                                    expectedSelection: CFRange, execution: CombinedShiftExecutionContext,
                                    inputBarrierIsActive: @escaping () -> Bool,
                                    context: CombinedShiftContext?, layouts: (source: String, target: String)?,
                                    preservedOriginal: UnconfirmedAXEdit? = nil) -> CombinedShiftAXEditResult {
        guard inputBarrierIsActive(), !original.text.isEmpty, !replacement.isEmpty else { return .refused }
        if let preservedOriginal {
            guard preservedOriginal.focus.processID == execution.focus.processID,
                  CFEqual(preservedOriginal.focus.element, execution.focus.element) else { return .refused }
        } else {
            guard !hasUnconfirmedAXEdit(in: execution.focus),
                  unconfirmedAXEdits.count < Self.maximumUnconfirmedFields else {
                RuntimeDiagnostics.record(.unconfirmedEditBlocked); return .refused
            }
        }
        guard canRetainRecoveryUnits(NativeFieldEditPlan.maximumFieldUnits * 2,
            replacing: preservedOriginal?.focus) else {
            RuntimeDiagnostics.record(.unconfirmedEditBlocked); return .refused
        }
        AXUIElementSetMessagingTimeout(execution.focus.element, 0.003)
        defer { AXUIElementSetMessagingTimeout(execution.focus.element, 0.05) }
        guard let current = execution.focus.selectionRange(),
              current.location == expectedSelection.location, current.length == expectedSelection.length,
              inputBarrierIsActive() else { return .refused }
        let selected = current.location == original.range.location && current.length == original.range.length
        let collapsedSuffix = current.length == 0
            && current.location == original.range.location + original.range.length
        guard selected || collapsedSuffix else { return .refused }
        var prepared: NativeFieldObservation?
        var retainedSource: CombinedShiftSelectionSnapshot?
        var sourceCanBeRetained = true
        let leasedGate = { inputBarrierIsActive() && sourceCanBeRetained }
        let prepare: (NativeFieldObservation) -> Void = { observation in
            prepared = observation
            guard let source = NativeWholeFieldRecovery.originalText(prepared: observation.text,
                replacedRange: original.range.location..<(original.range.location + original.range.length),
                preservedSource: preservedOriginal?.original.text,
                preservedIsWholeField: preservedOriginal?.requiresExplicitSelection ?? false),
                  let snapshot = CombinedShiftSelectionSnapshot(
                    range: CFRange(location: 0, length: source.utf16.count), text: source) else {
                sourceCanBeRetained = false
                return
            }
            retainedSource = snapshot
        }
        let result: VerifiedNativeFieldEditResult
        if selected {
            result = NativeAutoEventTransport.executeSelected(original: original.text, replacement: replacement,
                start: original.range.location, execution: execution, inputBarrierIsActive: leasedGate,
                onPrepared: prepare)
        } else {
            result = NativeAutoEventTransport.executeVerified(original: original.text, replacement: replacement,
                start: original.range.location, execution: execution, inputBarrierIsActive: leasedGate,
                onPrepared: prepare)
        }
        switch result {
        case .refused: return .refused
        case .confirmed: return .confirmed
        case .uncertain(let observation):
            guard let prepared, let wholeSource = retainedSource else {
                return .unknown
            }
            let actual = observation ?? prepared
            // Repeated uncertain recovery keeps the first source forever. Only
            // the last actual observation is replaced; predictions are not evidence.
            retainUnconfirmed(UnconfirmedAXEdit(focus: execution.focus, original: wholeSource,
                replacement: actual.text,
                layoutContext: preservedOriginal?.layoutContext ?? context,
                predictionLayouts: preservedOriginal?.predictionLayouts ?? layouts,
                requiresExplicitSelection: true, lastNativeObservation: actual))
            return .unknown
        }
    }

    private func commitAXEdit(original: CombinedShiftSelectionSnapshot, replacement: String,
                              focus: CombinedShiftFocus, context: CombinedShiftContext?,
                              layouts: (source: String, target: String)?) {
        lastOriginal = original.text
        lastConverted = replacement
        lastWasBuffer = true
        lastWasAXEdit = true
        lastConvertedCount = 0
        lastBoundaryCount = 0
        lastClipboardRTL = TextConverter.containsRTL(original.text) || TextConverter.containsRTL(replacement)
        predictionLayouts = layouts
        lastLayoutContext = context
        lastSelectionOrigin = focus
        lastSelectionRange = CFRange(location: original.range.location, length: replacement.utf16.count)
    }

    /// An uncertain source is never discarded or automatically written again.
    /// A new explicit gesture may restore it only at that same exact AX range.
    private func recoverUnconfirmedAXEdit(execution: CombinedShiftExecutionContext,
                                          inputBarrierIsActive: (() -> Bool)? = nil) -> Bool {
        guard !isConverting, inputBarrierIsActive?() ?? true,
              let pending = unconfirmedAXEdits.first(where: {
                $0.focus.processID == execution.focus.processID && CFEqual($0.focus.element, execution.focus.element)
              }) else { return false }
        // A native unknown requires an independent input lease and an explicit
        // whole-result selection. It cannot fall through to an AX writer.
        guard !pending.requiresExplicitSelection || inputBarrierIsActive != nil else { return false }
        if inputBarrierIsActive != nil { AXUIElementSetMessagingTimeout(execution.focus.element, 0.003) }
        defer { if inputBarrierIsActive != nil { AXUIElementSetMessagingTimeout(execution.focus.element, 0.05) } }
        guard execution.isValid(timeout: inputBarrierIsActive == nil ? 0.05 : 0.003),
              let current = execution.focus.selectionRange() else { return false }
        guard !pending.requiresExplicitSelection || current.length > 0 else { return false }
        let resultRange = CFRange(location: pending.original.range.location, length: pending.replacement.utf16.count)
        let observed = execution.focus.text(in: resultRange)
        guard let result = pending.original.resultSnapshot(replacement: pending.replacement,
            selection: current, observedText: observed) else {
            // Only the unchanged legacy source can resolve a refused write.
            // This gesture never follows reconciliation with another mutation.
            if !pending.requiresExplicitSelection,
               pending.original.resultSnapshot(replacement: pending.original.text, selection: current,
                observedText: execution.focus.text(in: pending.original.range)) != nil,
               execution.isValid(timeout: inputBarrierIsActive == nil ? 0.05 : 0.003) {
                removeUnconfirmed(in: execution.focus)
            }
            return false
        }
        isConverting = true
        defer { isConverting = false }
        let outcome: CombinedShiftAXEditResult
        if let inputBarrierIsActive {
            outcome = replaceNativeRange(original: result, replacement: pending.original.text,
                expectedSelection: current, execution: execution, inputBarrierIsActive: inputBarrierIsActive,
                context: pending.layoutContext?.reversed,
                layouts: pending.predictionLayouts.map { ($0.target, $0.source) }, preservedOriginal: pending)
        } else {
            outcome = replaceAXRange(original: result, replacement: pending.original.text,
                expectedSelection: current, execution: execution)
        }
        guard outcome == .confirmed else {
            if outcome == .unknown, inputBarrierIsActive == nil {
                retainUnconfirmed(UnconfirmedAXEdit(focus: execution.focus, original: pending.original,
                    replacement: pending.original.text, layoutContext: pending.layoutContext,
                    predictionLayouts: pending.predictionLayouts,
                    requiresExplicitSelection: pending.requiresExplicitSelection,
                    lastNativeObservation: pending.lastNativeObservation))
            }
            return false
        }
        removeUnconfirmed(in: execution.focus)
        commitAXEdit(original: result, replacement: pending.original.text, focus: execution.focus,
            context: pending.layoutContext?.reversed,
            layouts: pending.predictionLayouts.map { ($0.target, $0.source) })
        return true
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
                 execution: CombinedShiftExecutionContext? = nil,
                 inputBarrierIsActive: (() -> Bool)? = nil) -> Bool {
        guard context == nil || execution != nil else { return false }
        guard inputBarrierIsActive == nil || (execution != nil && inputBarrierIsActive?() == true) else { return false }
        let keys: [TypedKey]
        let trailingSpaces: Int
        if !wordKeys.isEmpty {
            keys = wordKeys; trailingSpaces = 0
        } else if !prevWordKeys.isEmpty && boundaryCount > 0 {
            keys = prevWordKeys; trailingSpaces = boundaryCount
        } else {
            guard inputBarrierIsActive == nil else { return false }
            // нет буфера — возможно, выделен мышью старый текст: пусть решает clipboard
            return convertViaClipboard(wordLength: 0, prevWordLength: 0, boundaryCount: 0, context: context, execution: execution)
        }

        guard let pair = DynamicKeyMapping.convertKeys(keys, context: context) else {
            guard context == nil, inputBarrierIsActive == nil else { return false }  // explicit mapping failure cannot justify count-based deletion
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
            let resultContext = context.map { DynamicKeyMapping.resultContext(for: insert, requested: $0) }
            guard performNativeBufferEdit(original: original, replacement: insert, execution: execution,
                inputBarrierIsActive: inputBarrierIsActive, context: resultContext) else { return false }
            lastOriginal = original
            lastConverted = insert
            lastWasBuffer = true
        lastWasAXEdit = false
            predictionLayouts = nil
            lastLayoutContext = resultContext
            return true
        }
        isConverting = true
        lastOriginal = pair.original + originalSuffix + spaces
        lastConverted = pair.converted + passthroughSuffix + spaces
        lastWasBuffer = true
        lastWasAXEdit = false
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
                           execution: CombinedShiftExecutionContext? = nil,
                           inputBarrierIsActive: (() -> Bool)? = nil) -> Bool {
        guard context == nil || execution != nil else { return false }
        guard inputBarrierIsActive == nil || (execution != nil && inputBarrierIsActive?() == true) else { return false }
        guard !isConverting, !lineKeys.isEmpty else { return false }
        guard let original = DynamicKeyMapping.lineString(from: lineKeys, sourceLayoutID: context?.sourceLayoutID), !original.isEmpty else { return false }
        let converted = selectionConversion(original, context: context, normalize: false)
        guard converted != original else { return false }   // строка уже верная — no-op
        if let execution {
            let resultContext = context.map { DynamicKeyMapping.resultContext(for: converted, requested: $0) }
            guard performNativeBufferEdit(original: original, replacement: converted, execution: execution,
                inputBarrierIsActive: inputBarrierIsActive, context: resultContext) else { return false }
            lastWasBuffer = true
        lastWasAXEdit = false
            lastOriginal = original
            lastConverted = converted
            predictionLayouts = nil
            lastLayoutContext = resultContext
            return true
        }
        isConverting = true
        lastWasBuffer = true
        lastWasAXEdit = false
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
            lastWasAXEdit = false
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
    func reconvert(context: CombinedShiftContext? = nil, execution: CombinedShiftExecutionContext? = nil,
                   inputBarrierIsActive: (() -> Bool)? = nil) -> Bool {
        guard context == nil || execution != nil else { return false }
        guard inputBarrierIsActive == nil || (execution != nil && inputBarrierIsActive?() == true) else { return false }
        if let execution, inputBarrierIsActive != nil { AXUIElementSetMessagingTimeout(execution.focus.element, 0.003) }
        defer { if let execution, inputBarrierIsActive != nil { AXUIElementSetMessagingTimeout(execution.focus.element, 0.05) } }
        guard !isConverting else { return false }
        if let execution, hasUnconfirmedAXEdit(in: execution.focus) {
            return recoverUnconfirmedAXEdit(execution: execution, inputBarrierIsActive: inputBarrierIsActive)
        }
        if lastWasAXEdit {
            guard let execution, let origin = lastSelectionOrigin, let resultRange = lastSelectionRange,
                  origin.processID == execution.focus.processID, CFEqual(origin.element, execution.focus.element),
                  execution.isValid(timeout: inputBarrierIsActive == nil ? 0.05 : 0.003), let current = execution.focus.selectionRange(),
                  let original = CombinedShiftSelectionSnapshot(range: resultRange, text: lastConverted),
                  original.resultSnapshot(replacement: lastConverted, selection: current,
                      observedText: execution.focus.text(in: resultRange)) != nil else { return false }
            isConverting = true
            defer { isConverting = false }
            let replacement = lastOriginal
            let reverseContext = lastLayoutContext?.reversed ?? context
            let reverseLayouts = predictionLayouts.map { ($0.target, $0.source) }
            let result: CombinedShiftAXEditResult
            if let inputBarrierIsActive {
                result = replaceNativeRange(original: original, replacement: replacement,
                    expectedSelection: current, execution: execution, inputBarrierIsActive: inputBarrierIsActive,
                    context: reverseContext, layouts: reverseLayouts)
            } else {
                result = replaceAXRange(original: original, replacement: replacement,
                    expectedSelection: current, execution: execution)
            }
            guard result == .confirmed else {
                if result == .unknown, inputBarrierIsActive == nil {
                    retainUnconfirmed(UnconfirmedAXEdit(focus: execution.focus, original: original,
                        replacement: replacement, layoutContext: reverseContext, predictionLayouts: reverseLayouts))
                }
                return false
            }
            commitAXEdit(original: original, replacement: replacement, focus: execution.focus,
                context: reverseContext, layouts: reverseLayouts)
            return true
        }
        if lastWasBuffer {
            guard !lastConverted.isEmpty else { return false }
            if let execution {
                if inputBarrierIsActive != nil {
                    guard let origin = lastSelectionOrigin, let range = lastSelectionRange,
                          let caret = execution.focus.initialSelection, caret.length == 0,
                          caret.location == range.location + range.length,
                          origin.processID == execution.focus.processID,
                          CFEqual(origin.element, execution.focus.element) else { return false }
                }
                guard performNativeBufferEdit(original: lastConverted, replacement: lastOriginal, execution: execution,
                    inputBarrierIsActive: inputBarrierIsActive, context: lastLayoutContext?.reversed ?? context,
                    layouts: predictionLayouts.map { ($0.target, $0.source) }) else { return false }
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
        guard inputBarrierIsActive == nil else { return false }
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
            lastWasAXEdit = false
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
        lastWasAXEdit = false
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
        lastSelectionOrigin = nil
        lastSelectionRange = nil
        lastWasAXEdit = false
    }

    // MARK: - Private

    /// A supplied lease uses acknowledged whole-field suffix editing. The nil
    /// legacy route retains its existing bounded, synchronous delete-first batch.
    private func performNativeBufferEdit(original: String, replacement: String,
                                         execution: CombinedShiftExecutionContext,
                                         inputBarrierIsActive: (() -> Bool)? = nil,
                                         context: CombinedShiftContext? = nil,
                                         layouts: (source: String, target: String)? = nil) -> Bool {
        if let inputBarrierIsActive {
            guard !isConverting, !hasUnconfirmedAXEdit(in: execution.focus), inputBarrierIsActive(),
                  let caret = execution.focus.initialSelection, caret.length == 0,
                  caret.location >= original.utf16.count,
                  let snapshot = CombinedShiftSelectionSnapshot(
                    range: CFRange(location: caret.location - original.utf16.count, length: original.utf16.count),
                    text: original) else { return false }
            isConverting = true
            defer { isConverting = false }
            guard replaceNativeRange(original: snapshot, replacement: replacement, expectedSelection: caret,
                execution: execution, inputBarrierIsActive: inputBarrierIsActive,
                context: context, layouts: layouts) == .confirmed else { return false }
            lastSelectionOrigin = execution.focus
            lastSelectionRange = CFRange(location: snapshot.range.location, length: replacement.utf16.count)
            return true
        }
        guard !hasUnconfirmedAXEdit(in: execution.focus), !isConverting, !original.isEmpty, original.count <= 512,
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
        guard execution.isValid() else { RuntimeDiagnostics.record(.nativeInvalidExecution); return false }
        guard execution.focus.hasOriginalSuffixBeforeCaret(original) else {
            RuntimeDiagnostics.record(.nativeSuffixMismatch); return false
        }
        guard execution.isValid() else { RuntimeDiagnostics.record(.nativeInvalidExecution); return false }
        for event in events { event.postToPid(execution.focus.processID) }
        RuntimeDiagnostics.record(.nativeEditPosted)
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
        guard execution?.isValid() != false else { RuntimeDiagnostics.record(.pasteInvalidExecution); return false }
        if let execution, let original, !execution.focus.selectedTextMatches(original) {
            RuntimeDiagnostics.record(.pasteAXSelectionMismatch); return false
        }
        guard clipboardSession.writeTemporaryText(text) else {
            RuntimeDiagnostics.record(.pasteClipboardWriteRefused); return false
        }
        RuntimeDiagnostics.record(.pasteClipboardWritten)
        guard clipboardSession.permitsPaste() else { RuntimeDiagnostics.record(.pasteClipboardOwnershipLost); return false }
        guard operationKey(keyCode: KC.letterV, flags: .maskCommand, execution: execution) else {
            RuntimeDiagnostics.record(.pastePostRefused); return false
        }
        usleep(150_000) // 150мс — дать приложению вставить текст и обновить курсор
        let valid = execution?.isValid() != false
        RuntimeDiagnostics.record(valid ? .pasteCompleted : .pasteInvalidAfterPost)
        return valid
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
            guard execution?.isValid() != false else { RuntimeDiagnostics.record(.copyInvalidExecution); return nil }
            let focus = execution?.focus ?? NSWorkspace.shared.frontmostApplication.flatMap {
                CombinedShiftFocus.capture(processID: $0.processIdentifier)
            }
            guard let focus else { RuntimeDiagnostics.record(.copyFocusUnavailable); return nil }
            guard focus.isCurrent() else { RuntimeDiagnostics.record(.copyFocusChanged); return nil }
            guard let oldCount = clipboardSession.clearForCopy() else {
                RuntimeDiagnostics.record(.copyClipboardOwnershipLost); return nil
            }
            RuntimeDiagnostics.record(.copyClipboardPrepared)

            guard operationKey(keyCode: KC.letterC, flags: .maskCommand, execution: execution) else {
                RuntimeDiagnostics.record(.copyPostRefused); return nil
            }
            usleep(attempt == 0 ? 80_000 : 120_000)
            guard execution?.isValid() != false else { RuntimeDiagnostics.record(.copyInvalidExecution); return nil }

            let copyCount = pasteboard.changeCount
            RuntimeDiagnostics.record(copyCount != oldCount ? .copyChanged : .copyUnchanged)
            if copyCount != oldCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty {
                guard focus.isCurrent() else { RuntimeDiagnostics.record(.copyFocusChanged); return nil }
                guard focus.selectedTextMatches(text) else { RuntimeDiagnostics.record(.copyAXSelectionMismatch); return nil }
                guard execution?.isValid() != false else { RuntimeDiagnostics.record(.copyInvalidExecution); return nil }
                guard clipboardSession.claimVerifiedCopy(changeCount: copyCount) else {
                    RuntimeDiagnostics.record(.copyClaimRefused); return nil
                }
                RuntimeDiagnostics.record(.copyVerified)
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
        guard let source = makeSource() else { RuntimeDiagnostics.record(.syntheticEventUnavailable); return }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { RuntimeDiagnostics.record(.syntheticEventUnavailable); return }

        keyDown.flags = flags
        keyUp.flags = flags

        if let processID = destinationProcessID {
            keyDown.postToPid(processID)
            keyUp.postToPid(processID)
        } else {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        if flags.contains(.maskCommand) {
            if keyCode == KC.letterC { RuntimeDiagnostics.record(.copyPosted) }
            if keyCode == KC.letterV { RuntimeDiagnostics.record(.pastePosted) }
        }
    }
}
