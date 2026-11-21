import AppKit
import ApplicationServices

/// What AX says about one concrete field. Never carries field text.
enum SecureFieldVerdict: Equatable, Sendable {
    case ordinary, secure, unknown
}

/// Secure Input is decided per field, not by the session-wide flag alone.
/// The idea of asking the focused field itself (password → refuse, ordinary →
/// work, no AX answer → refuse) follows Keyboop's SecureInputPolicy (MIT);
/// no code is copied. A key that reached the tap was not hidden by macOS,
/// but a password field is never read, buffered or written.
enum SecureFieldPolicy {
    /// `focus == nil` means the field was not asked: allowed only when the
    /// flag is down (the unchanged hot path). Anything but a positively
    /// ordinary answer refuses, with or without the flag.
    static func mayUse(focus: SecureFieldVerdict?, flagRaised: Bool) -> Bool {
        guard let focus else { return !flagRaised }
        return focus == .ordinary
    }

    /// One `AXSubrole` answer. A missing optional subrole is ordinary (AX
    /// answered); a malformed answer or any AX failure is uncertainty.
    static func verdict(subroleStatus: AXError, subrole: AnyObject?) -> SecureFieldVerdict {
        switch subroleStatus {
        case .success:
            guard let subrole = subrole as? String else { return .unknown }
            return subrole == kAXSecureTextFieldSubrole ? .secure : .ordinary
        case .attributeUnsupported, .noValue:
            return .ordinary
        default:
            return .unknown
        }
    }

    /// Under the raised flag the holder's own protection is genuine: its
    /// fields are treated as secure; an unknown holder or PID is uncertainty.
    static func flaggedVerdict(_ field: SecureFieldVerdict, fieldProcessID: Int32,
                               holderProcessID: Int32?) -> SecureFieldVerdict {
        guard field == .ordinary else { return field }
        guard fieldProcessID > 0, let holderProcessID, holderProcessID > 0 else { return .unknown }
        return holderProcessID == fieldProcessID ? .secure : .ordinary
    }

    /// The verdict that applies right now: the raw field answer when the flag
    /// is down, the holder-aware answer when it is raised.
    static func effectiveVerdict(_ field: SecureFieldVerdict, fieldProcessID: Int32,
                                 flagRaised: Bool = AutoSwitchPolicy.secureInputActive) -> SecureFieldVerdict {
        guard flagRaised else { return field }
        return flaggedVerdict(field, fieldProcessID: fieldProcessID,
            holderProcessID: AutoSwitchPolicy.secureInputHolderProcessID())
    }

    /// Subrole of one live element, bounded by the element's messaging timeout.
    static func liveVerdict(of element: AXUIElement) -> SecureFieldVerdict {
        var raw: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &raw)
        return verdict(subroleStatus: status, subrole: raw)
    }

    /// Event-tap probe, asked only while the flag is raised: the system-wide
    /// focused element, its PID and subrole, each under a short AX timeout.
    /// No text, value or selection is requested. Any failure is `.unknown`.
    static func liveFocusedFieldVerdict(timeout: Float = 0.02) -> SecureFieldVerdict {
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, timeout) == .success else { return .unknown }
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .unknown }
        let element = raw as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success,
              AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return .unknown }
        return effectiveVerdict(liveVerdict(of: element), fieldProcessID: pid, flagRaised: true)
    }
}

/// Memoized field answer for one edit's repeated cheap gates. A field's
/// subrole does not change for the same AX element, so it is asked at most
/// once; the flag and its holder are re-read on every call.
@MainActor
final class SecureFlagFieldPermit {
    private let focus: CombinedShiftFocus
    private let flagRaised: () -> Bool
    private var fieldVerdict: SecureFieldVerdict?

    init(focus: CombinedShiftFocus, flagRaised: @escaping () -> Bool = { AutoSwitchPolicy.secureInputActive }) {
        self.focus = focus
        self.flagRaised = flagRaised
    }

    func allows() -> Bool {
        guard flagRaised() else { return true }
        let verdict = fieldVerdict ?? focus.secureFieldVerdict()
        fieldVerdict = verdict
        return SecureFieldPolicy.mayUse(focus: SecureFieldPolicy.flaggedVerdict(verdict,
            fieldProcessID: focus.processID,
            holderProcessID: AutoSwitchPolicy.secureInputHolderProcessID()), flagRaised: true)
    }
}

/// Entry check of a Shift gesture while the flag is raised. Shift itself
/// reaches the tap even under genuine Secure Input, so the gesture counts only
/// after a character key reached us in the same target, which is not the holder.
@MainActor
enum SecureFlagGestureGate {
    enum Decision: Equatable { case flagDown, admitted, refused }

    static func evaluate(isDouble: Bool, targetProcessID: Int32, deliveredProcessID: Int32?,
                         flagRaised: Bool, holderProcessID: Int32?,
                         record: (RuntimeDiagnosticEvent) -> Void = RuntimeDiagnostics.record) -> Decision {
        guard flagRaised else { return .flagDown }
        guard targetProcessID > 0, deliveredProcessID == targetProcessID,
              let holderProcessID, holderProcessID > 0, holderProcessID != targetProcessID else { return .refused }
        if isDouble { record(.secureFlagWithEvents) }
        return .admitted
    }
}
