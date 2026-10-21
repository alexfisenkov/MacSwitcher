import ApplicationServices
import AppKit
import Foundation

/// An optional AX Boolean may be absent, but a failed or malformed supported
/// read must not be mistaken for absence.
enum NativeFieldBooleanSignal: Equatable {
    case value(Bool)
    case unavailable
    case invalid

    static func attribute(status: AXError, raw: AnyObject?) -> Self {
        switch status {
        case .success:
            guard let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return .invalid }
            return .value(CFBooleanGetValue((raw as! CFBoolean)))
        case .attributeUnsupported, .noValue:
            return .unavailable
        default:
            return .invalid
        }
    }

    static func capability(status: AXError, settable: Bool) -> Self {
        switch status {
        case .success: return .value(settable)
        case .attributeUnsupported, .noValue: return .unavailable
        default: return .invalid
        }
    }
}

enum NativeFieldEditabilityPolicy {
    static func allows(enabled: NativeFieldBooleanSignal, readOnly: NativeFieldBooleanSignal,
                       editable: NativeFieldBooleanSignal,
                       selectedTextSettable: NativeFieldBooleanSignal) -> Bool {
        guard enabled != .value(false), enabled != .invalid,
              readOnly != .value(true), readOnly != .invalid,
              editable != .value(false), editable != .invalid else { return false }
        if editable == .value(true) { return true }
        return selectedTextSettable == .value(true)
    }
}

/// Preallocated, marked, PID-only events. Construction never posts input.
/// No AX selection, clipboard, global event destination, or asynchronous job.
@MainActor
struct NativeAutoEventTransport {
    private let insertion: [CGEvent]
    private let removal: [CGEvent]
    private let left: [CGEvent]
    private let backspace: [CGEvent]
    private let right: [CGEvent]

    init?(original: String, replacement: String) {
        guard !original.isEmpty, original.count == replacement.count,
              original.utf16.count == original.count, replacement.utf16.count == replacement.count,
              replacement.utf16.count <= NativeFieldEditPlan.maximumEditUnits,
              let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = kRuSwitcherEventMarker
        source.localEventsSuppressionInterval = 0
        func pair(_ code: CGKeyCode) -> [CGEvent]? {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: kRuSwitcherEventMarker)
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            }
            return [down, up]
        }
        guard let unicode = pair(0) else { return nil }
        let units = Array(replacement.utf16)
        for event in unicode {
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            guard CombinedShiftUnicode.payloadMatches(event, expected: units) else { return nil }
        }
        guard let leftPair = pair(123), let backspacePair = pair(51), let rightPair = pair(124) else { return nil }
        left = leftPair
        backspace = backspacePair
        right = rightPair
        var navigation: [CGEvent] = []
        for code in [CGKeyCode(123), 51, 124] { // Left, Backspace, Right
            for _ in 0..<original.count {
                guard let events = pair(code) else { return nil }
                navigation.append(contentsOf: events)
            }
        }
        insertion = unicode
        removal = navigation
    }

    func postInsertion(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        post(insertion, to: processID, whileCurrent: whileCurrent)
    }

    func postRemoval(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        post(removal, to: processID, whileCurrent: whileCurrent)
    }

    /// The verified executor calls this once, then waits for this exact pair's
    /// whole-field/caret acknowledgement before requesting another operation.
    func post(_ operation: NativeFieldEditOperation, to processID: Int32,
              whileCurrent: () -> Bool) -> Bool {
        let events: [CGEvent]
        switch operation {
        case .insertReplacement: events = insertion
        case .left: events = left
        case .backspace: events = backspace
        case .right: events = right
        }
        return post(events, to: processID, whileCurrent: whileCurrent)
    }

    private func post(_ events: [CGEvent], to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        guard processID > 0 else { return false }
        for offset in stride(from: 0, to: events.count, by: 2) {
            guard NativeFieldKeyPairPoster.post(mayContinue: whileCurrent,
                keyDown: { events[offset].postToPid(processID) },
                keyUp: { events[offset + 1].postToPid(processID) }) else { return false }
        }
        return true // queued, never interpreted as delivery confirmation
    }
}

/// Prepared-only selection transport. One Unicode key pair carries the entire
/// replacement; constructing or inspecting it never posts input. The CGEvent
/// payload round-trip is preparation evidence, not target-delivery evidence.
@MainActor
struct NativeSelectedTextEventTransport {
    let events: [CGEvent]

    init?(replacement: String) {
        guard !replacement.isEmpty,
              replacement.utf16.count <= NativeFieldEditPlan.maximumSelectedReplacementUnits else { return nil }
        let units = Array(replacement.utf16)
        guard NativeFieldEditPlan.isWellFormedUTF16(units),
              let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = kRuSwitcherEventMarker
        source.localEventsSuppressionInterval = 0
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: kRuSwitcherEventMarker)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
            }
            guard CombinedShiftUnicode.payloadMatches(event, expected: units) else { return nil }
        }
        events = [down, up]
    }

    func post(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        guard processID > 0 else { return false }
        return NativeFieldKeyPairPoster.post(mayContinue: whileCurrent,
            keyDown: { events[0].postToPid(processID) },
            keyUp: { events[1].postToPid(processID) })
    }
}

@MainActor
extension NativeAutoEventTransport {
    static func execute(original: String, replacement: String, start: Int,
                        execution: CombinedShiftExecutionContext,
                        inputBarrierIsActive: @escaping () -> Bool) -> NativeAutomaticTextEditResult {
        guard start == 0, let transport = NativeAutoEventTransport(original: original, replacement: replacement) else { return .refused }
        let deadline = ProcessInfo.processInfo.systemUptime + NativeAutomaticTextEditor.maximumDuration
        let focus = execution.focus
        AXUIElementSetMessagingTimeout(focus.element, 0.003)
        defer { AXUIElementSetMessagingTimeout(focus.element, 0.05) }
        func cheapGate() -> Bool {
            ProcessInfo.processInfo.systemUptime < deadline && inputBarrierIsActive()
                && execution.inputRevision == execution.currentInputRevision()
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID
                && !AutoSwitchPolicy.secureInputActive
        }
        func validateFocus() -> Bool {
            var wasUnavailable = false
            let valid = NativeFocusRevalidation.validate(until: deadline,
                now: { ProcessInfo.processInfo.systemUptime }, mayContinue: cheapGate,
                read: {
                    let failure = execution.validationFailure(timeout: 0.003)
                    switch failure {
                    case .focusUnavailable:
                        wasUnavailable = true
                        RuntimeDiagnostics.record(.nativeAutoFocusRetry)
                    case .focusChanged: RuntimeDiagnostics.record(.executionFocusChanged)
                    case .wrongProcess: RuntimeDiagnostics.record(.executionWrongProcess)
                    case .revisionChanged: RuntimeDiagnostics.record(.executionRevisionChanged)
                    case .secureInput: RuntimeDiagnostics.record(.executionSecureInput)
                    case nil: break
                    }
                    return failure
                }, pause: { seconds in usleep(useconds_t(max(0, seconds) * 1_000_000)) })
            if wasUnavailable {
                RuntimeDiagnostics.record(valid ? .nativeAutoFocusRecovered : .nativeAutoFocusRecheckFailed)
            }
            return valid
        }
        let access = NativeAutomaticTextAccess(
            isValid: validateFocus,
            inputBarrierIsActive: inputBarrierIsActive,
            observe: { length in
                guard cheapGate(), length > 0, length <= NativeAutomaticTextEditor.maximumUnits * 2,
                      let range = focus.selectionRange(),
                      let text = focus.text(in: CFRange(location: start, length: length), allowValueFallback: false) else { return nil }
                var raw: AnyObject?
                guard AXUIElementCopyAttributeValue(focus.element, kAXValueAttribute as CFString, &raw) == .success,
                      let whole = raw as? String, whole.utf16.count == length, whole == text else { return nil }
                return NativeAutomaticTextObservation(textFromOriginalStart: text,
                    caretUTF16Location: range.location, selectionLength: range.length)
            },
            insertReplacement: {
                let posted = transport.postInsertion(to: focus.processID, whileCurrent: cheapGate)
                if posted { RuntimeDiagnostics.record(.nativeAutoInsertPosted) }
                return posted
            },
            deleteOriginal: {
                let posted = transport.postRemoval(to: focus.processID, whileCurrent: cheapGate)
                if posted { RuntimeDiagnostics.record(.nativeAutoRemovalPosted) }
                return posted
            },
            pause: { seconds in usleep(useconds_t(max(0, seconds) * 1_000_000)) },
            now: { ProcessInfo.processInfo.systemUptime })
        return NativeAutomaticTextEditor.replace(original: original, replacement: replacement,
            originalStartUTF16: start, access: access)
    }
}

@MainActor
extension NativeAutoEventTransport {
    /// Ordinary bounded suffix replacement, retaining the exact captured field.
    /// The caller owns the independent input-fence lease through source commit.
    static func executeVerified(original: String, replacement: String, start: Int,
                                execution: CombinedShiftExecutionContext,
                                inputBarrierIsActive: @escaping () -> Bool,
                                onPrepared: (NativeFieldObservation) -> Void = { _ in }) -> VerifiedNativeFieldEditResult {
        let deadline = ProcessInfo.processInfo.systemUptime + VerifiedNativeFieldEditor.maximumDuration
        guard let transport = NativeAutoEventTransport(original: original, replacement: replacement) else { return .refused }
        return executeBounded(original: original, replacement: replacement, start: start,
            replacingSelection: false, execution: execution, deadline: deadline,
            inputBarrierIsActive: inputBarrierIsActive, onPrepared: onPrepared,
            postOperation: { operation, current in
                transport.post(operation, to: execution.focus.processID, whileCurrent: current)
            })
    }

    /// Replace only the user's existing exact selection. No selection setter,
    /// clipboard, navigation or deletion key is used by this path.
    static func executeSelected(original: String, replacement: String, start: Int,
                                execution: CombinedShiftExecutionContext,
                                inputBarrierIsActive: @escaping () -> Bool,
                                onPrepared: (NativeFieldObservation) -> Void = { _ in }) -> VerifiedNativeFieldEditResult {
        let deadline = ProcessInfo.processInfo.systemUptime + VerifiedNativeFieldEditor.maximumDuration
        guard let transport = NativeSelectedTextEventTransport(replacement: replacement) else { return .refused }
        return executeBounded(original: original, replacement: replacement, start: start,
            replacingSelection: true, execution: execution, deadline: deadline,
            inputBarrierIsActive: inputBarrierIsActive, onPrepared: onPrepared,
            postOperation: { operation, current in
                guard operation == .insertReplacement else { return false }
                return transport.post(to: execution.focus.processID, whileCurrent: current)
            })
    }

    private static func executeBounded(original: String, replacement: String, start: Int,
                                       replacingSelection: Bool, execution: CombinedShiftExecutionContext,
                                       deadline: TimeInterval, inputBarrierIsActive: @escaping () -> Bool,
                                       onPrepared: (NativeFieldObservation) -> Void,
                                       postOperation: @escaping (NativeFieldEditOperation, () -> Bool) -> Bool)
        -> VerifiedNativeFieldEditResult {
        let focus = execution.focus
        AXUIElementSetMessagingTimeout(focus.element, 0.003)
        defer { AXUIElementSetMessagingTimeout(focus.element, 0.05) }

        func cheapGate() -> Bool {
            ProcessInfo.processInfo.systemUptime < deadline && inputBarrierIsActive()
                && execution.inputRevision == execution.currentInputRevision()
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID
                && !AutoSwitchPolicy.secureInputActive
        }
        func validateFocus(until sharedDeadline: TimeInterval) -> Bool {
            NativeFocusRevalidation.validate(until: min(deadline, sharedDeadline),
                now: { ProcessInfo.processInfo.systemUptime }, mayContinue: cheapGate,
                read: { execution.validationFailure(timeout: 0.003) },
                pause: { seconds in usleep(useconds_t(max(0, seconds) * 1_000_000)) })
        }
        let access = NativeFieldAccess(
            validateOriginalIdentity: validateFocus,
            cheapGate: cheapGate,
            isEditable: { cheapGate() && focus.nativeFieldIsEditable() && cheapGate() },
            observe: {
                guard cheapGate(), let observed = focus.nativeWholeFieldObservation(), cheapGate() else { return nil }
                return observed
            },
            post: { operation in
                // Full focus/whole-state validation lives in the core; this
                // cheap lease/PID/revision/secure/deadline gate runs per pair.
                let posted = postOperation(operation, cheapGate)
                if posted && operation == .insertReplacement { RuntimeDiagnostics.record(.nativeAutoInsertPosted) }
                return posted
            },
            now: { ProcessInfo.processInfo.systemUptime },
            pause: { seconds in usleep(useconds_t(max(0, seconds) * 1_000_000)) })
        if replacingSelection {
            return VerifiedNativeFieldEditor.executeSelection(original: original, replacement: replacement,
                start: start, access: access, absoluteDeadline: deadline, onPrepared: onPrepared)
        }
        return VerifiedNativeFieldEditor.execute(original: original, replacement: replacement,
            start: start, access: access, absoluteDeadline: deadline, onPrepared: onPrepared)
    }
}

private extension CombinedShiftFocus {
    /// Secure text fields are refused before any whole-value read, including
    /// applications that do not enable macOS Secure Event Input. Missing optional
    /// subroles are allowed; a failed supported read is not an eligibility signal.
    func nativeFieldHasNoSecureSubrole() -> Bool {
        var raw: AnyObject?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &raw) {
        case .success:
            guard let subrole = raw as? String else { return false }
            return subrole != kAXSecureTextFieldSubrole
        case .attributeUnsupported, .noValue:
            return true
        default:
            return false
        }
    }

    /// Capability queries only. An absent explicit editable signal requires a
    /// settable text capability; no setter is called by this native transport.
    func nativeFieldIsEditable() -> Bool {
        guard nativeFieldHasNoSecureSubrole() else { return false }
        var rawRole: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
              let role = rawRole as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return false }
        func flag(_ name: String) -> NativeFieldBooleanSignal {
            var raw: AnyObject?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
            return NativeFieldBooleanSignal.attribute(status: status, raw: raw)
        }
        let enabled = flag(kAXEnabledAttribute)
        let readOnly = flag("AXReadOnly")
        let editable = flag("AXEditable")
        var selectedTextSettable = NativeFieldBooleanSignal.unavailable
        if editable == .unavailable {
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
            selectedTextSettable = .capability(status: status, settable: settable.boolValue)
        }
        return NativeFieldEditabilityPolicy.allows(enabled: enabled, readOnly: readOnly,
            editable: editable, selectedTextSettable: selectedTextSettable)
    }

    /// Whole bounded raw UTF-16 read from the original AX object. Checking the
    /// raw CFString first avoids silently repairing malformed surrogate units.
    func nativeWholeFieldObservation() -> NativeFieldObservation? {
        guard nativeFieldHasNoSecureSubrole(), !AutoSwitchPolicy.secureInputActive,
              let before = selectionRange() else { return nil }
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        let value = raw as! CFString
        let count = CFStringGetLength(value)
        guard count <= NativeFieldEditPlan.maximumFieldUnits,
              before.location <= count, before.length <= count - before.location else { return nil }
        var units = [UInt16](repeating: 0, count: count)
        if count > 0 {
            units.withUnsafeMutableBufferPointer {
                CFStringGetCharacters(value, CFRange(location: 0, length: count), $0.baseAddress!)
            }
        }
        guard NativeFieldEditPlan.isWellFormedUTF16(units),
              let after = selectionRange(), before.location == after.location,
              before.length == after.length else { return nil }
        return NativeFieldObservation(text: String(decoding: units, as: UTF16.self),
            caretUTF16Location: after.location, selectionLength: after.length)
    }
}
