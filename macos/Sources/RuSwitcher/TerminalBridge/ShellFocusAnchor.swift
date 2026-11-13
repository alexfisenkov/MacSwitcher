import ApplicationServices

/// Exact first-Shift AX field/window identity, without reading their text.
/// A tab or pane switch invalidates preparation even when PID/revision stay.
struct ShellFocusAnchor: @unchecked Sendable {
    let hostPID: Int32
    let field: AXUIElement
    let window: AXUIElement
    let initialSelection: CFRange

    static func capture(_ focus: CombinedShiftFocus, hostPID: Int32) -> Self? {
        guard focus.searchOverlay == nil, focus.processID == hostPID,
              let initialSelection = focus.initialSelection else { return nil }
        let app = AXUIElementCreateApplication(hostPID)
        guard AXUIElementSetMessagingTimeout(app, 0.03) == .success else { return nil }
        var rawField: AnyObject?, rawWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &rawField) == .success,
              AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawField, let rawWindow,
              CFGetTypeID(rawField) == AXUIElementGetTypeID(),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID(),
              CFEqual(rawField, focus.element),
              let current = focus.selectionRange(),
              current.location == initialSelection.location,
              current.length == initialSelection.length else { return nil }
        return Self(hostPID: hostPID, field: focus.element,
            window: rawWindow as! AXUIElement, initialSelection: initialSelection)
    }

    func isCurrent() -> Bool {
        let app = AXUIElementCreateApplication(hostPID)
        guard AXUIElementSetMessagingTimeout(app, 0.03) == .success else { return false }
        var rawField: AnyObject?, rawWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &rawField) == .success,
              AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawField, let rawWindow,
              CFGetTypeID(rawField) == AXUIElementGetTypeID(),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return false }
        let focus = CombinedShiftFocus(processID: hostPID, element: field)
        guard let selection = focus.selectionRange() else { return false }
        return CFEqual(rawField, field) && CFEqual(rawWindow, window)
            && selection.location == initialSelection.location
            && selection.length == initialSelection.length
    }
}
