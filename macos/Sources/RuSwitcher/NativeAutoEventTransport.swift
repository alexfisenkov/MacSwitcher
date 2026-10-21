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

@MainActor
extension NativeAutoEventTransport {
    static func execute(original: String, replacement: String, start: Int,
                        execution: CombinedShiftExecutionContext,
                        inputBarrierIsActive: @escaping () -> Bool) -> NativeAutomaticTextEditResult {
        guard start == 0, let transport = NativeAutoEventTransport(original: original, replacement: replacement, prepareLegacyRemoval: true) else { return .refused }
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
                                onPrepared: (NativeFieldObservation) -> Void = { _ in },
                                onTextQueued: () -> Void = {}) -> VerifiedNativeFieldEditResult {
        let deadline = ProcessInfo.processInfo.systemUptime + VerifiedNativeFieldEditor.maximumDuration
        guard let transport = NativeAutoEventTransport(original: original, replacement: replacement) else { return .refused }
        return executeBounded(original: original, replacement: replacement, start: start,
            replacingSelection: false, execution: execution, deadline: deadline,
            inputBarrierIsActive: inputBarrierIsActive, onPrepared: onPrepared,
            onTextQueued: onTextQueued,
            postBatch: { operations, current in
                transport.postBatch(operations, to: execution.focus.processID, whileCurrent: current)
            }, cancelSelection: { current in
                transport.cancelPreparedSelection(to: execution.focus.processID, whileCurrent: current)
            })
    }

    /// Replace only the user's existing exact selection. No selection setter,
    /// clipboard, navigation or deletion key is used by this path.
    static func executeSelected(original: String, replacement: String, start: Int,
                                execution: CombinedShiftExecutionContext,
                                inputBarrierIsActive: @escaping () -> Bool,
                                onPrepared: (NativeFieldObservation) -> Void = { _ in },
                                onTextQueued: () -> Void = {}) -> VerifiedNativeFieldEditResult {
        let deadline = ProcessInfo.processInfo.systemUptime + VerifiedNativeFieldEditor.maximumDuration
        guard let transport = NativeSelectedTextEventTransport(replacement: replacement) else { return .refused }
        return executeBounded(original: original, replacement: replacement, start: start,
            replacingSelection: true, execution: execution, deadline: deadline,
            inputBarrierIsActive: inputBarrierIsActive, onPrepared: onPrepared,
            onTextQueued: onTextQueued,
            postBatch: { operations, current in
                guard operations == [.insertReplacement] else { return false }
                return transport.post(to: execution.focus.processID, whileCurrent: current)
            })
    }

    private static func executeBounded(original: String, replacement: String, start: Int,
                                       replacingSelection: Bool, execution: CombinedShiftExecutionContext,
                                       deadline: TimeInterval, inputBarrierIsActive: @escaping () -> Bool,
                                       onPrepared: (NativeFieldObservation) -> Void,
                                       onTextQueued: () -> Void,
                                       postBatch: @escaping ([NativeFieldEditOperation], () -> Bool) -> Bool,
                                       cancelSelection: ((() -> Bool) -> Bool)? = nil)
        -> VerifiedNativeFieldEditResult {
        let focus = execution.focus
        let configuredTimeout = NativeAXMessagingPolicy.configuredTimeout(arguments: CommandLine.arguments)
        defer { AXUIElementSetMessagingTimeout(focus.element, 0.05) }

        func cheapGate() -> Bool {
            ProcessInfo.processInfo.systemUptime < deadline && inputBarrierIsActive()
                && execution.inputRevision == execution.currentInputRevision()
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID
                && !AutoSwitchPolicy.secureInputActive
        }
        func prepareRead(until phaseDeadline: TimeInterval) -> Bool {
            let limit = min(deadline, phaseDeadline)
            guard cheapGate(), let timeout = NativeAXMessagingPolicy.remainingTimeout(until: limit,
                now: ProcessInfo.processInfo.systemUptime, configuredTimeout: configuredTimeout) else { return false }
            return AXUIElementSetMessagingTimeout(focus.element, timeout) == .success
                && ProcessInfo.processInfo.systemUptime < limit && cheapGate()
        }
        func validateFocus(until sharedDeadline: TimeInterval) -> Bool {
            NativeFocusRevalidation.validate(until: min(deadline, sharedDeadline),
                now: { ProcessInfo.processInfo.systemUptime }, mayContinue: cheapGate,
                read: {
                    guard let timeout = NativeAXMessagingPolicy.remainingTimeout(until: min(deadline, sharedDeadline),
                        now: ProcessInfo.processInfo.systemUptime, configuredTimeout: configuredTimeout) else {
                        return .focusUnavailable
                    }
                    return execution.validationFailure(timeout: timeout)
                },
                pause: { seconds in usleep(useconds_t(max(0, seconds) * 1_000_000)) })
        }
        let access = NativeFieldAccess(
            validateOriginalIdentity: validateFocus,
            cheapGate: cheapGate,
            isEditable: { phaseDeadline in
                cheapGate() && focus.nativeFieldIsEditable(prepareRead: { prepareRead(until: phaseDeadline) })
                    && ProcessInfo.processInfo.systemUptime < phaseDeadline && cheapGate()
            },
            observe: { phaseDeadline in
                guard cheapGate(), let observed = focus.nativeWholeFieldObservation(
                    prepareRead: { prepareRead(until: phaseDeadline) }),
                    ProcessInfo.processInfo.systemUptime < phaseDeadline, cheapGate() else { return nil }
                return observed
            },
            postBatch: { operations in
                // Core has just checked the whole field and exact identity.
                // The bridge admits once, then queues the complete fixed batch.
                let posted = postBatch(operations, cheapGate)
                if posted && operations.contains(.insertReplacement) { RuntimeDiagnostics.record(.nativeAutoInsertPosted) }
                return posted
            },
            cancelPreparedSelection: { phaseDeadline in
                guard let cancelSelection else { return false }
                return cancelSelection {
                    ProcessInfo.processInfo.systemUptime < min(deadline, phaseDeadline)
                        && inputBarrierIsActive()
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID
                        && !AutoSwitchPolicy.secureInputActive
                }
            },
            now: { ProcessInfo.processInfo.systemUptime },
            pause: { seconds in usleep(useconds_t(max(0, seconds) * 1_000_000)) })
        if replacingSelection {
            return VerifiedNativeFieldEditor.executeSelection(original: original, replacement: replacement,
                start: start, access: access, absoluteDeadline: deadline, onPrepared: onPrepared, onTextQueued: onTextQueued)
        }
        return VerifiedNativeFieldEditor.execute(original: original, replacement: replacement,
            start: start, access: access, absoluteDeadline: deadline, onPrepared: onPrepared, onTextQueued: onTextQueued)
    }
}

private extension CombinedShiftFocus {
    /// Secure text fields are refused before any whole-value read, including
    /// applications that do not enable macOS Secure Event Input. Missing optional
    /// subroles are allowed; a failed supported read is not an eligibility signal.
    func nativeFieldHasNoSecureSubrole(prepareRead: () -> Bool) -> Bool {
        guard prepareRead() else { return false }
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
    func nativeFieldIsEditable(prepareRead: () -> Bool) -> Bool {
        guard nativeFieldHasNoSecureSubrole(prepareRead: prepareRead), prepareRead() else { return false }
        var rawRole: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
              let role = rawRole as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return false }
        func flag(_ name: String) -> NativeFieldBooleanSignal {
            guard prepareRead() else { return .invalid }
            var raw: AnyObject?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
            return NativeFieldBooleanSignal.attribute(status: status, raw: raw)
        }
        let enabled = flag(kAXEnabledAttribute)
        let readOnly = flag("AXReadOnly")
        let editable = flag("AXEditable")
        var selectedTextSettable = NativeFieldBooleanSignal.unavailable
        if editable == .unavailable {
            guard prepareRead() else { return false }
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
            selectedTextSettable = .capability(status: status, settable: settable.boolValue)
        }
        return NativeFieldEditabilityPolicy.allows(enabled: enabled, readOnly: readOnly,
            editable: editable, selectedTextSettable: selectedTextSettable)
    }

    /// Whole bounded raw UTF-16 read from the original AX object. Checking the
    /// raw CFString first avoids silently repairing malformed surrogate units.
    func nativeWholeFieldObservation(prepareRead: () -> Bool) -> NativeFieldObservation? {
        guard nativeFieldHasNoSecureSubrole(prepareRead: prepareRead), !AutoSwitchPolicy.secureInputActive,
              prepareRead(),
              let before = selectionRange() else { return nil }
        var raw: AnyObject?
        guard prepareRead(), AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
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
        guard NativeFieldEditPlan.isWellFormedUTF16(units), prepareRead(),
              let after = selectionRange(), before.location == after.location,
              before.length == after.length else { return nil }
        return NativeFieldObservation(text: String(decoding: units, as: UTF16.self),
            caretUTF16Location: after.location, selectionLength: after.length)
    }
}
