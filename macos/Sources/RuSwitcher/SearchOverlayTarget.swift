import AppKit
import ApplicationServices
import CoreGraphics

/// A non-frontmost text field may override the ordinary host only when its
/// system AX focus, direct AX focus, and one concrete visible window agree.
enum SearchOverlayTargetPolicy {
    struct WindowEvidence: Equatable {
        let processID: Int32
        let windowID: UInt32
        let bundleID: String
        let ownerName: String
        let bounds: CGRect?

        init(processID: Int32, windowID: UInt32, bundleID: String,
             ownerName: String, bounds: CGRect? = nil) {
            self.processID = processID
            self.windowID = windowID
            self.bundleID = bundleID
            self.ownerName = ownerName
            self.bounds = bounds
        }
    }

    static func uniqueWindow(focusedPID: Int32, windows: [WindowEvidence],
                             focusedWindowBounds: CGRect? = nil) -> WindowEvidence? {
        guard focusedPID > 0 else { return nil }
        let matching = windows.filter { $0.processID == focusedPID }
        if matching.count == 1 { return matching[0] }
        guard let focusedWindowBounds, matching.count > 1 else { return nil }
        func sameFrame(_ candidate: CGRect?) -> Bool {
            guard let candidate,
                  candidate.origin.x.isFinite, candidate.origin.y.isFinite,
                  candidate.width.isFinite, candidate.height.isFinite,
                  focusedWindowBounds.origin.x.isFinite, focusedWindowBounds.origin.y.isFinite,
                  focusedWindowBounds.width.isFinite, focusedWindowBounds.height.isFinite,
                  candidate.width > 1, candidate.height > 1 else { return false }
            return abs(candidate.origin.x - focusedWindowBounds.origin.x) <= 2
                && abs(candidate.origin.y - focusedWindowBounds.origin.y) <= 2
                && abs(candidate.width - focusedWindowBounds.width) <= 2
                && abs(candidate.height - focusedWindowBounds.height) <= 2
        }
        let byFrame = matching.filter { sameFrame($0.bounds) }
        return byFrame.count == 1 ? byFrame[0] : nil
    }

    static func mayBeNonFrontmost(hostPID: Int32?, systemFocusedPID: Int32?) -> Bool {
        guard let hostPID, let systemFocusedPID else { return true }
        return hostPID != systemFocusedPID
    }

    static func resolve(hostPID: Int32, visibleProviderPIDs: [Int32], systemFocusedPID: Int32?,
                        directFocusedPID: Int32?, sameField: Bool, editableTextField: Bool) -> Int32? {
        guard hostPID > 0, visibleProviderPIDs.count == 1,
              let pid = visibleProviderPIDs.first, pid > 0, pid != hostPID,
              systemFocusedPID == pid, directFocusedPID == pid,
              sameField, editableTextField else { return nil }
        return pid
    }
}

enum SearchOverlayTarget {
    struct Binding: Sendable {
        let hostPID: Int32
        let processID: Int32
        let bundleID: String
        let ownerName: String
        let windowID: UInt32
    }

    enum Capture {
        case absent
        case unverified
        case verified(CombinedShiftFocus)
    }

    struct Budget {
        let deadline: TimeInterval
        let perCall: Float
        let now: () -> TimeInterval

        func timeout() -> Float? {
            let left = deadline - now()
            guard left.isFinite, left > 0 else { return nil }
            return Float(min(Double(perCall), left))
        }
    }

    /// Injectable OS boundary. Tests drive the real capture and revalidation
    /// decisions without opening a user field or relying on the window server.
    struct Probe {
        let now: () -> TimeInterval
        let frontPID: () -> Int32?
        let bundleID: (Int32) -> String?
        let systemFocus: (Budget) -> (pid: Int32, element: AXUIElement)?
        let directFocus: (Int32, Budget) -> CombinedShiftFocus?
        let editable: (CombinedShiftFocus, Budget) -> Bool
        let windows: (Int32) -> [SearchOverlayTargetPolicy.WindowEvidence]?
        let focusedWindowBounds: (CombinedShiftFocus, Budget) -> CGRect?
        let selection: (CombinedShiftFocus, Budget) -> CFRange?

        static var live: Self {
            Self(now: { ProcessInfo.processInfo.systemUptime },
                 frontPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                 bundleID: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
                 systemFocus: { SearchOverlayTarget.systemFocusedElement(budget: $0) },
                 directFocus: { SearchOverlayTarget.directFocusedElement(processID: $0, budget: $1) },
                 editable: { SearchOverlayTarget.isEditableTextField($0, budget: $1) },
                 windows: { SearchOverlayTarget.visibleWindows(for: $0) },
                 focusedWindowBounds: { SearchOverlayTarget.focusedWindowBounds($0, budget: $1) },
                 selection: { SearchOverlayTarget.selectionRange($0, budget: $1) })
        }
    }

    private static func remaining(_ deadline: TimeInterval, probe: Probe,
                                  perCall: Float) -> Float? {
        let left = deadline - probe.now()
        guard left.isFinite, left > 0 else { return nil }
        return Float(min(Double(perCall), left))
    }

    private static func visibleWindows(for processID: Int32) -> [SearchOverlayTargetPolicy.WindowEvidence]? {
        guard processID > 0,
              let bundle = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier,
              !bundle.isEmpty else { return nil }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        var result: [SearchOverlayTargetPolicy.WindowEvidence] = []
        for window in windows {
            guard let number = window[kCGWindowOwnerPID as String] as? NSNumber,
                  number.int32Value == processID,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  !owner.isEmpty,
                  (window[kCGWindowAlpha as String] as? Double ?? 0) > 0.9,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? NSNumber)?.doubleValue ?? 0 > 1,
                  (bounds["Height"] as? NSNumber)?.doubleValue ?? 0 > 1,
                  let identity = window[kCGWindowNumber as String] as? NSNumber,
                  identity.uint32Value > 0 else { continue }
            result.append(.init(processID: processID, windowID: identity.uint32Value,
                                bundleID: bundle, ownerName: owner,
                                bounds: CGRect(x: (bounds["X"] as? NSNumber)?.doubleValue ?? .nan,
                                               y: (bounds["Y"] as? NSNumber)?.doubleValue ?? .nan,
                                               width: (bounds["Width"] as? NSNumber)?.doubleValue ?? .nan,
                                               height: (bounds["Height"] as? NSNumber)?.doubleValue ?? .nan)))
        }
        return result
    }

    /// Prediction has no proved event-to-floating-field PID mapping. A visible
    /// inactive Siri/launcher window does not block the ordinary host.
    static func mayHaveActiveOverlay() -> Bool {
        let host = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = systemFocusedElement(timeout: 0.01)
        return SearchOverlayTargetPolicy.mayBeNonFrontmost(
            hostPID: host, systemFocusedPID: focused?.pid)
    }

    private static func systemFocusedElement(timeout: Float) -> (pid: Int32, element: AXUIElement)? {
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, timeout) == .success else { return nil }
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return (pid, element)
    }

    private static func read(_ element: AXUIElement, _ attribute: CFString,
                             budget: Budget) -> (AXError, AnyObject?)? {
        guard let timeout = budget.timeout(),
              AXUIElementSetMessagingTimeout(element, timeout) == .success,
              let refreshed = budget.timeout(),
              AXUIElementSetMessagingTimeout(element, refreshed) == .success else { return nil }
        var raw: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard budget.timeout() != nil else { return nil }
        return (status, raw)
    }

    private static func settable(_ element: AXUIElement, _ attribute: CFString,
                                 budget: Budget) -> NativeFieldBooleanSignal {
        guard let timeout = budget.timeout(),
              AXUIElementSetMessagingTimeout(element, timeout) == .success,
              let refreshed = budget.timeout(),
              AXUIElementSetMessagingTimeout(element, refreshed) == .success else { return .invalid }
        var value = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &value)
        guard budget.timeout() != nil else { return .invalid }
        return NativeFieldBooleanSignal.capability(status: status, settable: value.boolValue)
    }

    private static func systemFocusedElement(budget: Budget) -> (pid: Int32, element: AXUIElement)? {
        let system = AXUIElementCreateSystemWide()
        guard let (status, raw) = read(system, kAXFocusedUIElementAttribute as CFString,
                                       budget: budget), status == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID(),
              let timeout = budget.timeout() else { return nil }
        let element = raw as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success,
              budget.timeout() != nil,
              AXUIElementGetPid(element, &pid) == .success, pid > 0,
              budget.timeout() != nil else { return nil }
        return (pid, element)
    }

    private static func directFocusedElement(processID: Int32,
                                             budget: Budget) -> CombinedShiftFocus? {
        guard processID > 0 else { return nil }
        let app = AXUIElementCreateApplication(processID)
        guard let (status, raw) = read(app, kAXFocusedUIElementAttribute as CFString,
                                       budget: budget), status == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID(),
              let timeout = budget.timeout() else { return nil }
        let element = raw as! AXUIElement
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success,
              budget.timeout() != nil else { return nil }
        return CombinedShiftFocus(processID: processID, element: element)
    }

    private static func isEditableTextField(_ focus: CombinedShiftFocus,
                                            budget: Budget) -> Bool {
        guard !AutoSwitchPolicy.secureInputActive,
              let (subroleStatus, subroleRaw) = read(focus.element,
                  kAXSubroleAttribute as CFString, budget: budget) else { return false }
        switch subroleStatus {
        case .success:
            guard let subrole = subroleRaw as? String,
                  subrole != kAXSecureTextFieldSubrole else { return false }
        case .attributeUnsupported, .noValue:
            break
        default:
            return false
        }
        guard let (roleStatus, roleRaw) = read(focus.element,
                  kAXRoleAttribute as CFString, budget: budget), roleStatus == .success,
              let role = roleRaw as? String,
              ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) else { return false }
        func signal(_ attribute: CFString) -> NativeFieldBooleanSignal {
            guard let (status, raw) = read(focus.element, attribute, budget: budget) else { return .invalid }
            return NativeFieldBooleanSignal.attribute(status: status, raw: raw)
        }
        func capability(_ attribute: CFString) -> NativeFieldBooleanSignal {
            settable(focus.element, attribute, budget: budget)
        }
        return NativeFieldEditabilityPolicy.allows(
            enabled: signal(kAXEnabledAttribute as CFString),
            readOnly: signal("AXReadOnly" as CFString),
            editable: signal("AXEditable" as CFString),
            selectedTextSettable: capability(kAXSelectedTextAttribute as CFString),
            valueSettable: capability(kAXValueAttribute as CFString))
    }

    /// Public AXWindow geometry disambiguates a search panel from another
    /// window of the same process. No title or field value is requested.
    private static func focusedWindowBounds(_ focus: CombinedShiftFocus,
                                            budget: Budget) -> CGRect? {
        guard let (windowStatus, windowRaw) = read(focus.element,
                  kAXWindowAttribute as CFString, budget: budget), windowStatus == .success,
              let windowRaw, CFGetTypeID(windowRaw) == AXUIElementGetTypeID() else { return nil }
        let window = windowRaw as! AXUIElement
        guard let (pointStatus, pointRaw) = read(window,
                  kAXPositionAttribute as CFString, budget: budget), pointStatus == .success,
              let (sizeStatus, sizeRaw) = read(window,
                  kAXSizeAttribute as CFString, budget: budget), sizeStatus == .success,
              let pointRaw, let sizeRaw,
              CFGetTypeID(pointRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pointRaw as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func selectionRange(_ focus: CombinedShiftFocus,
                                       budget: Budget) -> CFRange? {
        guard let (status, raw) = read(focus.element,
                  kAXSelectedTextRangeAttribute as CFString, budget: budget), status == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0,
              budget.timeout() != nil else { return nil }
        return range
    }

    /// Called only after a qualified first solo Shift. An unknown non-frontmost
    /// AX focus blocks underlay capture; the solo layout switch still runs.
    static func capture(hostPID: Int32, probe: Probe = .live) -> Capture {
        // Soft wall-clock budget: each AX call is bounded separately. The OS
        // window-list RPC itself cannot be interrupted if it stalls.
        let deadline = probe.now() + 0.040
        let budget = Budget(deadline: deadline, perCall: 0.005, now: probe.now)
        guard hostPID > 0, budget.timeout() != nil,
              let system = probe.systemFocus(budget),
              remaining(deadline, probe: probe, perCall: 0.005) != nil else { return .unverified }
        if system.pid == hostPID { return .absent }
        guard let direct = probe.directFocus(system.pid, budget),
              remaining(deadline, probe: probe, perCall: 0.005) != nil,
              CFEqual(system.element, direct.element),
              probe.editable(direct, budget),
              remaining(deadline, probe: probe, perCall: 0.005) != nil,
              let windows = probe.windows(system.pid),
              remaining(deadline, probe: probe, perCall: 0.005) != nil else { return .unverified }
        let frame: CGRect?
        if windows.count > 1 {
            guard budget.timeout() != nil else { return .unverified }
            frame = probe.focusedWindowBounds(direct, budget)
            guard remaining(deadline, probe: probe, perCall: 0.005) != nil else { return .unverified }
        } else { frame = nil }
        guard let candidate = SearchOverlayTargetPolicy.uniqueWindow(
                  focusedPID: system.pid, windows: windows, focusedWindowBounds: frame),
              let selection = probe.selection(direct, budget),
              remaining(deadline, probe: probe, perCall: 0.005) != nil,
              SearchOverlayTargetPolicy.resolve(hostPID: hostPID,
                  visibleProviderPIDs: [candidate.processID], systemFocusedPID: system.pid,
                  directFocusedPID: direct.processID, sameField: true,
                  editableTextField: true) != nil else { return .unverified }
        let binding = Binding(hostPID: hostPID, processID: candidate.processID,
                              bundleID: candidate.bundleID, ownerName: candidate.ownerName,
                              windowID: candidate.windowID)
        return .verified(CombinedShiftFocus(processID: candidate.processID, element: direct.element,
            initialSelection: selection, searchOverlay: binding))
    }

    /// Cheap authorization for a PID-only event batch. Exact AX identity is
    /// separately checked at every edit phase by `isCurrent`.
    static func currentProcessID(for binding: Binding, probe: Probe = .live) -> Int32? {
        // This is called for every prepared event pair. Full window and AX
        // identity checks happen at explicit edit checkpoints below.
        guard probe.frontPID() == binding.hostPID,
              probe.bundleID(binding.processID) == binding.bundleID else { return nil }
        return binding.processID
    }

    static func isCurrent(_ focus: CombinedShiftFocus, binding: Binding,
                          timeout: Float = 0.05, probe: Probe = .live) -> Bool {
        let deadline = probe.now() + min(0.050, max(0.018, Double(timeout) * 8))
        let budget = Budget(deadline: deadline, perCall: timeout, now: probe.now)
        guard currentProcessID(for: binding, probe: probe) == focus.processID,
              budget.timeout() != nil,
              let system = probe.systemFocus(budget), system.pid == focus.processID,
              remaining(deadline, probe: probe, perCall: timeout) != nil,
              let direct = probe.directFocus(focus.processID, budget),
              remaining(deadline, probe: probe, perCall: timeout) != nil,
              CFEqual(system.element, direct.element), CFEqual(focus.element, direct.element),
              probe.editable(direct, budget),
              remaining(deadline, probe: probe, perCall: timeout) != nil,
              let windows = probe.windows(focus.processID),
              remaining(deadline, probe: probe, perCall: timeout) != nil else { return false }
        let frame: CGRect?
        if windows.count > 1 {
            guard budget.timeout() != nil else { return false }
            frame = probe.focusedWindowBounds(direct, budget)
            guard remaining(deadline, probe: probe, perCall: timeout) != nil else { return false }
        } else { frame = nil }
        guard let candidate = SearchOverlayTargetPolicy.uniqueWindow(
                  focusedPID: focus.processID, windows: windows, focusedWindowBounds: frame),
              probe.selection(direct, budget) != nil,
              remaining(deadline, probe: probe, perCall: timeout) != nil,
              candidate.windowID == binding.windowID,
              candidate.ownerName == binding.ownerName,
              candidate.bundleID == binding.bundleID else { return false }
        return true
    }
}
