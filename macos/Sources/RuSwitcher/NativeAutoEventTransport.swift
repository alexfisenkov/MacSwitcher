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
                       selectedTextSettable: NativeFieldBooleanSignal,
                       valueSettable: NativeFieldBooleanSignal = .unavailable) -> Bool {
        guard enabled != .value(false), enabled != .invalid,
              readOnly != .value(true), readOnly != .invalid,
              editable != .value(false), editable != .invalid else { return false }
        if editable == .value(true) { return true }
        if selectedTextSettable == .value(true) { return true }
        guard selectedTextSettable != .invalid else { return false }
        return valueSettable == .value(true)
    }
}

struct NativeProjectedReadContract {
    let rawStart: Int
    let formattedStart: Int
    let original: String
    let replacement: String
    let replacingSelection: Bool
    let requiresEndpointWitness: Bool
}

enum NativeCollapsedCoordinateResolution {
    case ordinary
    case projected(Int, requiresStartWitness: Bool)
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
        let securePermit = SecureFlagFieldPermit(focus: focus)
        func cheapGate() -> Bool {
            ProcessInfo.processInfo.systemUptime < deadline && inputBarrierIsActive()
                && execution.inputRevision == execution.currentInputRevision()
                && focus.currentTargetProcessID() == focus.processID
                && securePermit.allows()
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
                guard focus.allowsTextRead(),
                      AXUIElementCopyAttributeValue(focus.element, kAXValueAttribute as CFString, &raw) == .success,
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
                                onTextQueued: () -> Void = {},
                                formattedStart: Int? = nil,
                                requiresEndpointWitness: Bool = false,
                                allowCoordinateResolution: Bool = false,
                                onResolvedFormattedStart: @escaping (Int) -> Void = { _ in }) -> VerifiedNativeFieldEditResult {
        let deadline = ProcessInfo.processInfo.systemUptime + VerifiedNativeFieldEditor.maximumDuration
        guard let transport = NativeAutoEventTransport(original: original, replacement: replacement) else { return .refused }
        return executeBounded(original: original, replacement: replacement, start: start,
            replacingSelection: false, execution: execution, deadline: deadline,
            inputBarrierIsActive: inputBarrierIsActive, onPrepared: onPrepared,
            onTextQueued: onTextQueued, formattedStart: formattedStart,
            requiresEndpointWitness: requiresEndpointWitness,
            allowCoordinateResolution: allowCoordinateResolution,
            onResolvedFormattedStart: onResolvedFormattedStart,
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
                                onTextQueued: () -> Void = {},
                                formattedStart: Int? = nil,
                                requiresEndpointWitness: Bool = false) -> VerifiedNativeFieldEditResult {
        let deadline = ProcessInfo.processInfo.systemUptime + VerifiedNativeFieldEditor.maximumDuration
        guard let transport = NativeSelectedTextEventTransport(replacement: replacement) else { return .refused }
        return executeBounded(original: original, replacement: replacement, start: start,
            replacingSelection: true, execution: execution, deadline: deadline,
            inputBarrierIsActive: inputBarrierIsActive, onPrepared: onPrepared,
            onTextQueued: onTextQueued,
            formattedStart: formattedStart,
            requiresEndpointWitness: requiresEndpointWitness,
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
                                       formattedStart: Int? = nil,
                                       requiresEndpointWitness: Bool = false,
                                       allowCoordinateResolution: Bool = false,
                                       onResolvedFormattedStart: @escaping (Int) -> Void = { _ in },
                                       postBatch: @escaping ([NativeFieldEditOperation], () -> Bool) -> Bool,
                                       cancelSelection: ((() -> Bool) -> Bool)? = nil)
        -> VerifiedNativeFieldEditResult {
        let focus = execution.focus
        let configuredTimeout = NativeAXMessagingPolicy.configuredTimeout(arguments: CommandLine.arguments)
        defer { AXUIElementSetMessagingTimeout(focus.element, 0.05) }
        var textBatchQueued = false
        var preparedObservation: NativeFieldObservation?
        var activeFormattedStart = formattedStart
        var activeRequiresEndpointWitness = requiresEndpointWitness
        var coordinateResolved = formattedStart != nil || replacingSelection
            || !allowCoordinateResolution
        func projectedContract() -> NativeProjectedReadContract? {
            activeFormattedStart.map {
                NativeProjectedReadContract(rawStart: start, formattedStart: $0,
                    original: original, replacement: replacement,
                    replacingSelection: replacingSelection,
                    requiresEndpointWitness: activeRequiresEndpointWitness)
            }
        }
        var reportedAckFailures = Set<String>()

        func recordAfterTextQueue(_ event: RuntimeDiagnosticEvent) {
            guard textBatchQueued, RuntimeDiagnostics.enabled,
                  reportedAckFailures.insert(event.rawValue).inserted else { return }
            RuntimeDiagnostics.record(event)
        }

        let securePermit = SecureFlagFieldPermit(focus: focus)
        func cheapGate() -> Bool {
            ProcessInfo.processInfo.systemUptime < deadline && inputBarrierIsActive()
                && execution.inputRevision == execution.currentInputRevision()
                && focus.currentTargetProcessID() == focus.processID
                && securePermit.allows()
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
                        recordAfterTextQueue(.ackFocusUnavailable)
                        return .focusUnavailable
                    }
                    let failure = execution.validationFailure(timeout: timeout)
                    switch failure {
                    case .focusUnavailable: recordAfterTextQueue(.ackFocusUnavailable)
                    case .focusChanged: recordAfterTextQueue(.ackFocusChanged)
                    case .revisionChanged: recordAfterTextQueue(.ackRevisionChanged)
                    case .wrongProcess: recordAfterTextQueue(.ackWrongProcess)
                    case .secureInput: recordAfterTextQueue(.ackSecureInput)
                    case nil: break
                    }
                    return failure
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
                if !coordinateResolved {
                    guard let resolution = focus.nativeCollapsedCoordinateResolution(observed,
                        rawStart: start, original: original,
                        prepareRead: { prepareRead(until: phaseDeadline) }) else { return nil }
                    coordinateResolved = true
                    if case .projected(let mapped, let needsStartWitness) = resolution {
                        activeFormattedStart = mapped
                        activeRequiresEndpointWitness = needsStartWitness
                        onResolvedFormattedStart(mapped)
                    }
                }
                guard let contract = projectedContract() else { return observed }
                return focus.nativeProjectedObservation(observed, contract: contract,
                    textBatchQueued: textBatchQueued, phaseDeadline: phaseDeadline,
                    prepareRead: { prepareRead(until: phaseDeadline) })
            },
            postBatch: { operations in
                if activeRequiresEndpointWitness && operations.contains(.insertReplacement) {
                    guard cheapGate(), validateFocus(until: deadline),
                          let preparedObservation,
                          let contract = projectedContract(),
                          focus.nativeProjectedPrequeueProof(prepared: preparedObservation,
                              contract: contract, phaseDeadline: deadline,
                              prepareRead: { prepareRead(until: deadline) }),
                          validateFocus(until: deadline), cheapGate() else { return false }
                }
                // Core has just checked the whole field and exact identity.
                // The bridge admits once, then queues the complete fixed batch.
                let posted = postBatch(operations, cheapGate)
                if posted && operations.contains(.insertReplacement) {
                    textBatchQueued = true
                    RuntimeDiagnostics.record(.nativeAutoInsertPosted)
                }
                return posted
            },
            cancelPreparedSelection: { phaseDeadline in
                guard let cancelSelection else { return false }
                return cancelSelection {
                    let limit = min(deadline, phaseDeadline)
                    return ProcessInfo.processInfo.systemUptime < limit && cheapGate()
                        && validateFocus(until: limit)
                        && ProcessInfo.processInfo.systemUptime < limit && cheapGate()
                }
            },
            now: { ProcessInfo.processInfo.systemUptime },
            pause: { seconds in usleep(useconds_t(max(0, seconds) * 1_000_000)) })
        if replacingSelection {
            return VerifiedNativeFieldEditor.executeSelection(original: original, replacement: replacement,
                start: start, access: access, absoluteDeadline: deadline,
                onPrepared: { observed in
                    preparedObservation = observed
                    onPrepared(observed)
                },
                onTextQueued: onTextQueued, formattedStart: formattedStart)
        }
        return VerifiedNativeFieldEditor.execute(original: original, replacement: replacement,
            start: start, access: access, absoluteDeadline: deadline,
            onPrepared: { observed in
                preparedObservation = observed
                onPrepared(observed)
            },
            onTextQueued: onTextQueued, formattedStart: formattedStart,
            resolvedFormattedStart: { activeFormattedStart })
    }
}

extension CombinedShiftFocus {
    /// Secure text fields are refused before any whole-value read, including
    /// applications that do not enable macOS Secure Event Input. Missing optional
    /// subroles are allowed; a failed supported read is not an eligibility signal.
    func nativeFieldHasNoSecureSubrole(prepareRead: () -> Bool) -> Bool {
        prepareRead() && allowsTextRead()
    }

    /// Capability queries only. An absent explicit editable signal requires a
    /// settable text capability; no setter is called by this native transport.
    func nativeFieldIsEditable(prepareRead: () -> Bool) -> Bool {
        if let fieldBoundary {
            return prepareRead() && fieldBoundary.nativeEditability?() != false
                && nativeFieldHasNoSecureSubrole(prepareRead: prepareRead)
        }
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
        var valueSettable = NativeFieldBooleanSignal.unavailable
        if editable == .unavailable,
           selectedTextSettable == .value(false) || selectedTextSettable == .unavailable,
           enabled != .value(false), enabled != .invalid,
           readOnly != .value(true), readOnly != .invalid {
            guard prepareRead() else { return false }
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            valueSettable = .capability(status: status, settable: settable.boolValue)
        }
        return NativeFieldEditabilityPolicy.allows(enabled: enabled, readOnly: readOnly,
            editable: editable, selectedTextSettable: selectedTextSettable,
            valueSettable: valueSettable)
    }

    /// Whole bounded raw UTF-16 read from the original AX object. Checking the
    /// raw CFString first avoids silently repairing malformed surrogate units.
    func nativeWholeFieldObservation(prepareRead: () -> Bool) -> NativeFieldObservation? {
        guard nativeFieldHasNoSecureSubrole(prepareRead: prepareRead), secureFlagPermits(),
              prepareRead() else { return nil }
        if let fieldBoundary {
            return prepareRead() ? fieldBoundary.nativeWholeObservation?() : nil
        }
        guard prepareRead(),
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

    /// Shared proof used by live AX transport and synthetic native boundaries.
    func nativeProjectedObservation(_ observed: NativeFieldObservation,
                                    contract: NativeProjectedReadContract,
                                    textBatchQueued: Bool, phaseDeadline: TimeInterval,
                                    prepareRead: @escaping () -> Bool) -> NativeFieldObservation? {
        guard contract.rawStart >= 0,
              contract.formattedStart >= 0,
              contract.formattedStart <= NativeFieldEditPlan.maximumFieldUnits,
              observed.caretUTF16Location >= 0,
              observed.caretUTF16Location <= NativeFieldEditPlan.maximumFieldUnits,
              observed.selectionLength >= 0,
              observed.selectionLength <= NativeFieldEditPlan.maximumSelectedReplacementUnits,
              prepareRead(), nativeFieldIsEditable(prepareRead: prepareRead),
              case .available(let flat) = nativeFullTextContent(prepareRead: prepareRead),
              let projection = NativeSelectedTextProjection(formatted: observed.text, flat: flat),
              prepareRead() else { return nil }
        if observed.selectionLength > 0 {
            let range = CFRange(location: observed.caretUTF16Location,
                                length: observed.selectionLength)
            let expectedStart = contract.replacingSelection ? contract.formattedStart
                : contract.formattedStart + observed.caretUTF16Location - contract.rawStart
            guard let byRange = text(in: range, allowValueFallback: false,
                      prepareRead: prepareRead),
                  let byAttribute = nativeSelectedTextAttribute(prepareRead: prepareRead),
                  projection.selectedFormattedStart(rawRange: range,
                      byRange: byRange, byAttribute: byAttribute) == expectedStart else { return nil }
        } else if projection.unambiguousFormattedCaret(
            rawLocation: observed.caretUTF16Location) == nil {
            guard contract.requiresEndpointWitness,
                  nativeParagraphBoundaryProof(rawRange: CFRange(
                      location: observed.caretUTF16Location, length: 0),
                      expectedFlat: flat,
                      expectedLeafText: textBatchQueued ? contract.replacement : contract.original,
                      expectedSide: .collapsedLeafEnd,
                      phaseDeadline: phaseDeadline, prepareRead: prepareRead) else { return nil }
        }
        guard let stable = selectionRange(prepareRead: prepareRead),
              stable.location == observed.caretUTF16Location,
              stable.length == observed.selectionLength,
              let value = nativeValueText(prepareRead: prepareRead),
              value.utf16.elementsEqual(observed.text.utf16), prepareRead() else { return nil }
        return observed
    }

    func nativeProjectedPrequeueProof(prepared: NativeFieldObservation,
                                      contract: NativeProjectedReadContract,
                                      phaseDeadline: TimeInterval,
                                      prepareRead: @escaping () -> Bool) -> Bool {
        guard contract.requiresEndpointWitness,
              prepareRead(), nativeFieldIsEditable(prepareRead: prepareRead),
              let current = nativeWholeFieldObservation(prepareRead: prepareRead),
              current.text.utf16.elementsEqual(prepared.text.utf16),
              current.caretUTF16Location == contract.rawStart,
              current.selectionLength == contract.original.utf16.count,
              case .available(let flat) = nativeFullTextContent(prepareRead: prepareRead),
              let projection = NativeSelectedTextProjection(formatted: current.text, flat: flat) else { return false }
        let range = CFRange(location: contract.rawStart, length: contract.original.utf16.count)
        guard let byRange = text(in: range, allowValueFallback: false,
                  prepareRead: prepareRead),
              let byAttribute = nativeSelectedTextAttribute(prepareRead: prepareRead),
              projection.selectedFormattedStart(rawRange: range,
                  byRange: byRange, byAttribute: byAttribute) == contract.formattedStart,
              nativeProjectedSelectionEndpointProof(projection: projection,
                  rawRange: range, selectedText: contract.original,
                  phaseDeadline: phaseDeadline, prepareRead: prepareRead),
              let stable = selectionRange(prepareRead: prepareRead),
              stable.location == range.location, stable.length == range.length,
              nativeValueText(prepareRead: prepareRead)?
                  .utf16.elementsEqual(prepared.text.utf16) == true,
              prepareRead() else { return false }
        return true
    }

    func nativeProjectedSelectionEndpointProof(projection: NativeSelectedTextProjection,
                                               rawRange: CFRange, selectedText: String,
                                               phaseDeadline: TimeInterval,
                                               prepareRead: @escaping () -> Bool) -> Bool {
        guard rawRange.location >= 0, rawRange.length > 0,
              rawRange.location <= Int.max - rawRange.length else { return false }
        let startAmbiguous = projection.unambiguousFormattedCaret(
            rawLocation: rawRange.location) == nil
        let endAmbiguous = projection.unambiguousFormattedCaret(
            rawLocation: rawRange.location + rawRange.length) == nil
        guard startAmbiguous || endAmbiguous else { return true }
        if endAmbiguous {
            return nativeParagraphBoundaryProof(rawRange: rawRange,
                expectedFlat: projection.flat, expectedLeafText: selectedText,
                expectedSide: .selectedWholeLeaf, phaseDeadline: phaseDeadline,
                prepareRead: prepareRead)
        }
        guard let start = projection.formattedStart(rawRange: rawRange,
                  byRange: selectedText),
              let paragraph = projection.paragraphText(startingAt: start) else { return false }
        return nativeParagraphBoundaryProof(rawRange: rawRange,
            expectedFlat: projection.flat, expectedLeafText: paragraph,
            expectedSide: .selectedLeafStart, phaseDeadline: phaseDeadline,
            prepareRead: prepareRead)
    }

    /// Resolve a typed buffer only from the first, pre-write whole observation.
    /// Ordinary single-line fields require no additional AX query.
    func nativeCollapsedCoordinateResolution(_ observed: NativeFieldObservation,
                                             rawStart: Int, original: String,
                                             prepareRead: @escaping () -> Bool)
        -> NativeCollapsedCoordinateResolution? {
        let count = original.utf16.count
        guard rawStart >= 0, count > 0,
              rawStart <= Int.max - count,
              observed.caretUTF16Location == rawStart + count,
              observed.selectionLength == 0 else { return nil }
        guard observed.text.utf16.contains(0x000A) else { return .ordinary }
        guard nativeFieldIsEditable(prepareRead: prepareRead) else { return nil }
        switch nativeFullTextContent(prepareRead: prepareRead) {
        case .available(let flat) where !flat.utf16.elementsEqual(observed.text.utf16):
            guard let projection = NativeSelectedTextProjection(formatted: observed.text, flat: flat),
                  projection.unambiguousFormattedCaret(rawLocation: observed.caretUTF16Location) != nil,
                  let byRange = text(in: CFRange(location: rawStart, length: count),
                      allowValueFallback: false, prepareRead: prepareRead),
                  byRange.utf16.elementsEqual(original.utf16),
                  let mapped = projection.formattedStart(rawRange: CFRange(
                      location: rawStart, length: count), byRange: byRange),
                  let stable = selectionRange(prepareRead: prepareRead),
                  stable.location == observed.caretUTF16Location, stable.length == 0,
                  nativeValueText(prepareRead: prepareRead)?
                      .utf16.elementsEqual(observed.text.utf16) == true else { return nil }
            return .projected(mapped,
                requiresStartWitness: projection.unambiguousFormattedCaret(
                    rawLocation: rawStart) == nil)
        case .available:
            return .ordinary
        case .unsupported, .failed:
            guard let fullByRange = text(in: CFRange(location: 0,
                length: observed.text.utf16.count), allowValueFallback: false,
                prepareRead: prepareRead),
                  fullByRange.utf16.elementsEqual(observed.text.utf16) else { return nil }
            return .ordinary
        }
    }
}
