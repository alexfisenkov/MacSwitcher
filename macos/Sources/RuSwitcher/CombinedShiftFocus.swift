import AppKit
import ApplicationServices

/// Fail-closed native edit policy; a missing PID is never a global-injection fallback.
enum CombinedShiftExecutionPolicy {
    static func permitsClipboardUndo(copiedText: String, lastConverted: String, native: Bool) -> Bool {
        !native || (!lastConverted.isEmpty && copiedText == lastConverted)
    }
    static func permits(originalPID: Int32?, currentPID: Int32?, expectedRevision: UInt64,
                        currentRevision: UInt64, sameFocus: Bool, secureInput: Bool) -> Bool {
        guard let originalPID, let currentPID else { return false }
        return originalPID > 0 && originalPID == currentPID && expectedRevision == currentRevision
            && sameFocus && !secureInput
    }

    static func matchesBuffer(original: String, initialSelection: CFRange?, currentSelection: CFRange?,
                              observedSuffix: String?) -> Bool {
        guard !original.isEmpty, let initialSelection, let currentSelection,
              initialSelection.length == 0, currentSelection.length == 0,
              initialSelection.location == currentSelection.location,
              currentSelection.location >= original.utf16.count else { return false }
        return observedSuffix == original
    }
}

/// A selection is identified by both its UTF-16 range and its exact AX text.
/// Equal text selected elsewhere in the same field is a different operation.
struct CombinedShiftSelectionSnapshot {
    let range: CFRange
    let text: String

    init?(range: CFRange, text: String) {
        guard range.location >= 0, range.length > 0, range.length == text.utf16.count,
              range.location <= Int.max - range.length else { return nil }
        self.range = range
        self.text = text
    }

    func matches(range: CFRange, text: String) -> Bool {
        self.range.location == range.location && self.range.length == range.length && self.text == text
    }

    /// AX undo is based on the exact result range, independent of the native
    /// typed-word executor's 512-character deletion limit.
    func resultSnapshot(replacement: String, selection: CFRange?, observedText: String?) -> CombinedShiftSelectionSnapshot? {
        let length = replacement.utf16.count
        guard let selection, !replacement.isEmpty, observedText == replacement,
              range.location <= Int.max - length,
              (selection.location == range.location + length && selection.length == 0)
                || (selection.location == range.location && selection.length == length) else { return nil }
        return CombinedShiftSelectionSnapshot(range: CFRange(location: range.location, length: length), text: replacement)
    }
}

enum CombinedShiftExecutionFailure {
    case revisionChanged, wrongProcess, secureInput, focusUnavailable, focusChanged
}

/// Identity of the actual AX field at the first tap, not merely its application.
struct CombinedShiftFocus: @unchecked Sendable {
    let processID: Int32
    let element: AXUIElement
    let initialSelection: CFRange?

    init(processID: Int32, element: AXUIElement, initialSelection: CFRange? = nil) {
        self.processID = processID
        self.element = element
        self.initialSelection = initialSelection
    }

    static func capture(processID: Int32, timeout: Float = 0.05, includeSelection: Bool = true) -> CombinedShiftFocus? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, timeout)
        var raw: AnyObject?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw)
        guard error == .success else {
            switch error {
            case .cannotComplete: RuntimeDiagnostics.record(.focusReadCannotComplete)
            case .noValue: RuntimeDiagnostics.record(.focusReadNoValue)
            case .invalidUIElement: RuntimeDiagnostics.record(.focusReadInvalidElement)
            default: RuntimeDiagnostics.record(.focusReadOtherError)
            }
            return nil
        }
        guard let raw else { RuntimeDiagnostics.record(.focusReadMissingValue); return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            RuntimeDiagnostics.record(.focusReadUnexpectedType); return nil
        }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        let focus = CombinedShiftFocus(processID: processID, element: element)
        return CombinedShiftFocus(processID: processID, element: element,
            initialSelection: includeSelection ? focus.selectionRange() : nil)
    }

    func isCurrent() -> Bool {
        guard let current = Self.capture(processID: processID) else { return false }
        return CFEqual(element, current.element)
    }

    /// A first-tap selection may not drift while the second tap is recognized.
    func selectionSnapshot() -> CombinedShiftSelectionSnapshot? {
        guard let initialSelection, let range = selectionRange(),
              initialSelection.location == range.location, initialSelection.length == range.length,
              let text = text(in: range) else { return nil }
        return CombinedShiftSelectionSnapshot(range: range, text: text)
    }

    /// nil means unsupported. A failed supported write never permits another
    /// mutation through a different mechanism: AX errors can be ambiguous.
    func writeSelectedText(_ replacement: String) -> Bool? {
        guard canWriteSelectedText() else { return nil }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            replacement as CFString) == .success
    }

    func canWriteSelectedText() -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    func select(range: CFRange) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var requested = range
        guard let value = AXValueCreate(.cfRange, &requested),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
              let current = selectionRange() else { return false }
        return current.location == range.location && current.length == range.length
    }

    func currentSelectionSnapshot() -> CombinedShiftSelectionSnapshot? {
        guard let range = selectionRange(), let text = text(in: range) else { return nil }
        return CombinedShiftSelectionSnapshot(range: range, text: text)
    }

    func replacementIsCurrent(original: CombinedShiftSelectionSnapshot, replacement: String) -> Bool {
        let replacementLength = replacement.utf16.count
        guard original.range.location <= Int.max - replacementLength,
              let range = selectionRange(),
              text(in: CFRange(location: original.range.location, length: replacementLength)) == replacement else { return false }
        let end = original.range.location + replacementLength
        if range.length == 0 { return range.location == end }
        // Some AX setters preserve the replacement's selection. Collapse only
        // that exact verified range so subsequent typing cannot replace it.
        guard range.location == original.range.location, range.length == replacementLength else { return false }
        var caret = CFRange(location: end, length: 0)
        guard let value = AXValueCreate(.cfRange, &caret),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
              let current = selectionRange() else { return false }
        return current.location == end && current.length == 0
    }

    func selectionRange() -> CFRange? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    func selectedTextMatches(_ expected: String) -> Bool {
        guard let range = selectionRange(), range.length > 0 else { return false }
        return text(in: range) == expected
    }

    func hasOriginalSuffixBeforeCaret(_ expected: String) -> Bool {
        guard !expected.isEmpty, let range = selectionRange(), range.location >= expected.utf16.count else { return false }
        let observed = text(in: CFRange(location: range.location - expected.utf16.count, length: expected.utf16.count))
        return CombinedShiftExecutionPolicy.matchesBuffer(original: expected, initialSelection: initialSelection,
            currentSelection: range, observedSuffix: observed)
    }

    func text(in range: CFRange, allowValueFallback: Bool = true) -> String? {
        guard !AutoSwitchPolicy.secureInputActive else { return nil }
        var requestedRange = range
        var raw: AnyObject?
        if let value = AXValueCreate(.cfRange, &requestedRange),
           AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                       value, &raw) == .success,
           let text = raw as? String { return text }
        guard allowValueFallback else { return nil }
        raw = nil
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let value = raw as? String else { return nil }
        let units = Array(value.utf16)
        guard range.location <= units.count, range.length <= units.count - range.location else { return nil }
        return String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
    }
}

@MainActor
struct CombinedShiftExecutionContext {
    let focus: CombinedShiftFocus
    let inputRevision: UInt64
    let currentInputRevision: () -> UInt64

    func validationFailure(timeout: Float = 0.05) -> CombinedShiftExecutionFailure? {
        guard inputRevision == currentInputRevision() else { return .revisionChanged }
        guard focus.processID > 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else { return .wrongProcess }
        guard !AutoSwitchPolicy.secureInputActive else { return .secureInput }
        guard let current = CombinedShiftFocus.capture(processID: focus.processID, timeout: timeout, includeSelection: false) else { return .focusUnavailable }
        guard CFEqual(focus.element, current.element) else { return .focusChanged }
        // AX calls are synchronous and may take time; repeat inexpensive checks
        // immediately before allowing a caller to edit.
        guard inputRevision == currentInputRevision() else { return .revisionChanged }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else { return .wrongProcess }
        guard !AutoSwitchPolicy.secureInputActive else { return .secureInput }
        return nil
    }

    func isValid(timeout: Float = 0.05) -> Bool {
        guard let failure = validationFailure(timeout: timeout) else { return true }
        switch failure {
        case .revisionChanged: RuntimeDiagnostics.record(.executionRevisionChanged)
        case .wrongProcess: RuntimeDiagnostics.record(.executionWrongProcess)
        case .secureInput: RuntimeDiagnostics.record(.executionSecureInput)
        case .focusUnavailable: RuntimeDiagnostics.record(.executionFocusUnavailable)
        case .focusChanged: RuntimeDiagnostics.record(.executionFocusChanged)
        }
        return false
    }

    func canReplaceBuffer(original: String) -> Bool {
        isValid() && focus.hasOriginalSuffixBeforeCaret(original) && isValid()
    }
}
