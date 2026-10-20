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

    static func capture(processID: Int32) -> CombinedShiftFocus? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        let focus = CombinedShiftFocus(processID: processID, element: element)
        return CombinedShiftFocus(processID: processID, element: element, initialSelection: focus.selectionRange())
    }

    func isCurrent() -> Bool {
        guard let current = Self.capture(processID: processID) else { return false }
        return CFEqual(element, current.element)
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

    private func text(in range: CFRange) -> String? {
        guard !AutoSwitchPolicy.secureInputActive else { return nil }
        var requestedRange = range
        var raw: AnyObject?
        if let value = AXValueCreate(.cfRange, &requestedRange),
           AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                       value, &raw) == .success,
           let text = raw as? String { return text }
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

    func isValid() -> Bool {
        let currentRevision = currentInputRevision()
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let secure = AutoSwitchPolicy.secureInputActive
        guard CombinedShiftExecutionPolicy.permits(originalPID: focus.processID, currentPID: currentPID,
            expectedRevision: inputRevision, currentRevision: currentRevision, sameFocus: true, secureInput: secure) else { return false }
        return CombinedShiftExecutionPolicy.permits(originalPID: focus.processID, currentPID: currentPID,
            expectedRevision: inputRevision, currentRevision: currentRevision, sameFocus: focus.isCurrent(), secureInput: secure)
    }

    func canReplaceBuffer(original: String) -> Bool {
        isValid() && focus.hasOriginalSuffixBeforeCaret(original) && isValid()
    }
}
