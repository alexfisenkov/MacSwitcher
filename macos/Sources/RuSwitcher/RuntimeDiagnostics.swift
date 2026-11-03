import AppKit
import ApplicationServices
import OSLog

/// Temporary opt-in instrumentation. The API accepts only this closed vocabulary;
/// text, keycodes, clipboard values, paths and arbitrary descriptions cannot enter it.
enum RuntimeDiagnosticEvent: String, CaseIterable, Sendable {
    case soloReceived, doubleRecognized, doubleFirstSnapshotUnavailable
    case doubleReceived, doubleDisabled, doubleSecureInput, doubleWrongProcess
    case doubleRevisionChanged, doubleRemoteDeferred, doubleMissingFocus, doubleInvalidExecution
    case doubleNoReconversionState, doubleMissingWordContext, doubleNoBufferOrSelection
    case doubleFailed, doubleSucceeded
    case clipboardBegin, clipboardBeginRefused, copyInvalidExecution, copyFocusUnavailable
    case copyClipboardOwnershipLost, copyClipboardPrepared, copyPostRefused, copyPosted, copyUnchanged
    case copyChanged, copyFocusChanged, copyAXSelectionMismatch, copyClaimRefused, copyVerified
    case pasteInvalidExecution, pasteAXSelectionMismatch, pasteClipboardWriteRefused
    case pasteClipboardWritten, pasteClipboardOwnershipLost, pastePostRefused, pastePosted, pasteCompleted, pasteInvalidAfterPost
    case autoInputEligible, autoUnicodeMissing, autoUnicodePresent, autoSnapshotSubmitted
    case autoEngineReady, autoEngineUnavailable, autoAnchorSessionChanged, autoAnchorStale
    case autoAnchorUnavailable, autoAnchorSelectionUnavailable, autoAnchorAccepted
    case autoEvaluationStale, autoMappingUnavailable, autoNoProposal, autoProposal
    case autoProposalRejected, autoTargetUnavailable, autoFocusAnchorUnavailable, autoFocusMismatch
    case autoCaretUnavailable, autoCaretMismatch, autoEditRefused, autoEditPosted
    case nativeInvalidExecution, nativeSuffixMismatch, nativeEditPosted, syntheticEventUnavailable
    case executionRevisionChanged, executionWrongProcess, executionSecureInput
    case executionFocusUnavailable, executionFocusChanged
    case selectionSnapshotUnavailable, selectionAXWriteRefused, selectionAXWritePosted
    case selectionAXWriteVerified, selectionAXReadbackMismatch, selectionClipboardFallback, selectionCancelled
    case selectionAXUnsupported, selectionAXMutationUnknown, autoAXUnsupported, autoAXMutationUnknown, unconfirmedEditBlocked
    case harnessSelectionStarted, harnessSelectionPassed, harnessSelectionFailed
    case harnessAutoStarted, harnessAutoPassed, harnessAutoFailed
    case autoWorkStarted, sourceNotificationPreserved, sourceNotificationInvalidated
    case harnessNativeStarted, harnessNativePassed, harnessNativeFailed
    case nativeAutoBlocked, nativeAutoInsertPosted, nativeAutoRemovalPosted, nativeAutoVerified, nativeAutoUncertain
    case nativePreparationNavigationUncertain
    case nativeAutoFocusRetry, nativeAutoFocusRecovered, nativeAutoFocusRecheckFailed
    case nativeFenceHeldInput, nativeFenceInterrupted, nativeFenceUnavailable
    case fenceGateNotConfigured, fenceTapMissing, fenceTapDisabled, fenceInterrupted, fencePendingSource, fenceBusy
    case tapDisabledTimeout, tapDisabledUserInput
    case ackDeadline, ackGateInvalid, ackObservationLimit
    case ackObservationUnavailable, ackTextMismatch, ackCaretMismatch, ackSelectionMismatch
    case ackFocusUnavailable, ackFocusChanged, ackRevisionChanged, ackWrongProcess, ackSecureInput
    case autoTextConfirmed, autoTextUnconfirmed, autoSourceConfirmed, autoSourceFailed, autoSourceUnconfirmed, heldInputRecoded
    case focusReadCannotComplete, focusReadNoValue, focusReadInvalidElement
    case focusReadOtherError, focusReadMissingValue, focusReadUnexpectedType

    var logOnce: Bool { rawValue.hasPrefix("auto") || rawValue.hasPrefix("native") || rawValue.hasPrefix("focusRead") }
}

/// Failure stages are metadata only. Keep these separate from RuntimeDiagnosticEvent:
/// repeated refusals in the same process must remain observable.
enum RuntimeDiagnosticFailureReason: String, CaseIterable, Sendable {
    case selectionSourceMismatch, selectionStateBlocked, selectionTimeout
    case selectionInvalidExecution, selectionSnapshotMissing, selectionFieldUnavailable
    case selectionFieldMismatch, selectionTextMismatch, selectionPolicyNoChange
    case selectionReplacementRejected, selectionRevalidationFailed
    case transactionCandidateUnavailable, transactionInvalidExecution
    case transactionRevisionChanged, transactionWrongProcess, transactionSecureInput
    case transactionFieldChanged, transactionSourceChanged
    case wordContextUnavailable, wordInputBarrierUnavailable, wordBufferUnavailable
    case wordMappingUnavailable, wordConversionBusy, wordMappingNoChange
    case wordNativeStateBlocked, wordNativeCaretMismatch, wordNativeSnapshotInvalid
    case wordNativeEditRefused
    case verifiedWordStateBlocked, verifiedWordCaretUnavailable, verifiedWordFieldUnavailable
    case verifiedWordFieldMismatch, verifiedWordTrailingSpaceLimit, verifiedWordNoFinalLetter
    case verifiedWordTokenLimit, verifiedWordBoundaryInvalid, verifiedWordTokenInvalid
    case verifiedWordNoConversion, verifiedWordRevalidationFailed
}

enum RuntimeDiagnostics {
    // Local opt-in complements the existing launch flag; no input payload
    // reaches this closed-vocabulary logger.
    static var enabled: Bool {
        isEnabled(arguments: CommandLine.arguments)
            || UserDefaults.standard.bool(forKey: "com.macswitcher.metadataDiagnosticsEnabled")
    }
    private static let logger = Logger(subsystem: "com.alexfisenkov.macswitcher", category: "Diagnostics")
    private static let seen = SeenEvents()

    static func isEnabled(arguments: [String]) -> Bool { arguments.contains("--diagnostic-events") }

    static func record(_ event: RuntimeDiagnosticEvent) {
        guard enabled, !event.logOnce || seen.insert(event) else { return }
        logger.notice("\(event.rawValue, privacy: .public)")
    }

    static func failureIdentifier(_ reason: RuntimeDiagnosticFailureReason, enabled: Bool) -> String? {
        enabled ? "failure.\(reason.rawValue)" : nil
    }

    static func emitFailure(_ reason: RuntimeDiagnosticFailureReason, enabled: Bool,
                            sink: (String) -> Void) {
        guard let identifier = failureIdentifier(reason, enabled: enabled) else { return }
        sink(identifier)
    }

    static func recordFailure(_ reason: RuntimeDiagnosticFailureReason) {
        emitFailure(reason, enabled: enabled) { identifier in
            logger.notice("\(identifier, privacy: .public)")
        }
    }

    /// Opt-in outcome metadata only. All three fields come from closed enums;
    /// no typed text, key, AX value, clipboard content or arbitrary app ID enters OSLog.
    static func record(_ outcome: CombinedShiftDiagnostic) {
        guard enabled else { return }
        logger.notice("combined.\(outcome.application.rawValue, privacy: .public).\(outcome.operation.rawValue, privacy: .public).\(outcome.result.rawValue, privacy: .public)")
    }

    static func beginNativeFocusReadAttempt() {
        seen.beginNativeFocusReadAttempt()
    }

    final class SeenEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var events = Set<RuntimeDiagnosticEvent>()
        func insert(_ event: RuntimeDiagnosticEvent) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return events.insert(event).inserted
        }

        func beginNativeFocusReadAttempt() {
            lock.lock(); defer { lock.unlock() }
            events = events.filter { !$0.rawValue.hasPrefix("focusRead") }
        }
    }
}

/// Read-only capability inspection, except for the separately named experimental
/// --enable-accessibility flag. Never serializes any AX value or range contents.
@MainActor
enum AXCapabilityDiagnostics {
    static func runIfRequested(arguments: [String]) -> Int32? {
        if let index = arguments.firstIndex(of: "--ax-capabilities-metadata") {
            guard !arguments.contains("--enable-accessibility") else {
                emit(["error": "metadataModeDisallowsAccessibilityMutation"]); return 2
            }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                emit(["error": "missingBundleIdentifier"]); return 2
            }
            let targets = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == arguments[index + 1]
            }
            emit(["mode": "metadata", "trusted": AXIsProcessTrusted(),
                  "secureInputActive": AutoSwitchPolicy.secureInputActive,
                  "applicationFound": !targets.isEmpty,
                  "applications": targets.map(inspectMetadata)])
            return targets.isEmpty ? 2 : 0
        }
        guard let index = arguments.firstIndex(of: "--ax-capabilities") else { return nil }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            emit(["error": "missingBundleIdentifier"]); return 2
        }
        let bundleID = arguments[index + 1]
        let targets = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        var result: [String: Any] = ["trusted": AXIsProcessTrusted(), "applicationFound": !targets.isEmpty,
                                     "applications": targets.map { inspect($0, enable: arguments.contains("--enable-accessibility")) }]
        result["enableAccessibilityRequested"] = arguments.contains("--enable-accessibility")
        emit(result)
        return targets.isEmpty ? 2 : 0
    }

    /// The metadata reader deliberately has no operation for reading a text,
    /// selection, range, title, description or other arbitrary AX attribute.
    enum MetadataScalar: String, CaseIterable {
        case role = "AXRole"
        case subrole = "AXSubrole"
        case enabled = "AXEnabled"
        case editable = "AXEditable"
        case readOnly = "AXReadOnly"
    }

    @MainActor
    protocol MetadataReader {
        func attributeNames() -> (AXError, [String])
        func parameterizedAttributeNames() -> (AXError, [String])
        func scalar(_ name: MetadataScalar) -> (AXError, AnyObject?)
        func isSettable(_ name: String) -> (AXError, Bool)
    }

    private struct LiveMetadataReader: MetadataReader {
        let element: AXUIElement

        func attributeNames() -> (AXError, [String]) {
            var raw: CFArray?
            let error = AXUIElementCopyAttributeNames(element, &raw)
            return (error, raw as? [String] ?? [])
        }

        func parameterizedAttributeNames() -> (AXError, [String]) {
            var raw: CFArray?
            let error = AXUIElementCopyParameterizedAttributeNames(element, &raw)
            return (error, raw as? [String] ?? [])
        }

        func scalar(_ name: MetadataScalar) -> (AXError, AnyObject?) {
            var raw: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, name.rawValue as CFString, &raw)
            return (error, raw)
        }

        func isSettable(_ name: String) -> (AXError, Bool) {
            var flag = DarwinBoolean(false)
            let error = AXUIElementIsAttributeSettable(element, name as CFString, &flag)
            return (error, flag.boolValue)
        }
    }

    private static func inspectMetadata(_ target: NSRunningApplication) -> [String: Any] {
        let app = AXUIElementCreateApplication(target.processIdentifier)
        var result: [String: Any] = ["pid": target.processIdentifier,
            "targetIsFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier]
        let appTimeoutError = AXUIElementSetMessagingTimeout(app, 0.25)
        result["applicationTimeoutError"] = appTimeoutError.rawValue
        guard appTimeoutError == .success else {
            result["focusAvailable"] = false; return result
        }
        var focused: AnyObject?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        result["focusError"] = error.rawValue
        if error != .success {
            let system = AXUIElementCreateSystemWide()
            let systemTimeoutError = AXUIElementSetMessagingTimeout(system, 0.25)
            result["systemTimeoutError"] = systemTimeoutError.rawValue
            guard systemTimeoutError == .success else {
                result["focusAvailable"] = false; return result
            }
            var global: AnyObject?
            let globalError = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &global)
            result["systemFocusError"] = globalError.rawValue
            focused = globalError == .success ? global : nil
            if focused != nil { result["focusOrigin"] = "systemWide" }
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            result["focusAvailable"] = false; return result
        }
        let element = focused as! AXUIElement
        let elementTimeoutError = AXUIElementSetMessagingTimeout(element, 0.25)
        result["elementTimeoutError"] = elementTimeoutError.rawValue
        guard elementTimeoutError == .success else {
            result["focusAvailable"] = false; return result
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == target.processIdentifier else {
            result["focusAvailable"] = false; return result
        }
        result["focusAvailable"] = true
        result.merge(metadata(from: LiveMetadataReader(element: element))) { _, new in new }
        return result
    }

    /// Only closed-vocabulary identifiers and scalar Boolean states leave this
    /// function. Attribute names are tested for membership, never serialized.
    static func metadata(from reader: any MetadataReader) -> [String: Any] {
        let (namesError, names) = reader.attributeNames()
        let available = namesError == .success ? Set(names) : []
        var result: [String: Any] = ["attributeNamesError": namesError.rawValue]

        let (roleError, roleRaw) = reader.scalar(.role)
        result["roleError"] = roleError.rawValue
        switch roleError == .success ? roleRaw as? String : nil {
        case kAXTextFieldRole: result["role"] = "AXTextField"
        case kAXTextAreaRole: result["role"] = "AXTextArea"
        case "AXWebArea": result["role"] = "AXWebArea"
        case kAXGroupRole: result["role"] = "AXGroup"
        default: result["role"] = "Other"
        }
        let (subroleError, subroleRaw) = reader.scalar(.subrole)
        result["subroleError"] = subroleError.rawValue
        result["secureTextSubrole"] = subroleError == .success && (subroleRaw as? String) == "AXSecureTextField"

        var editability: [String: Any] = [:]
        for scalar in [MetadataScalar.enabled, .editable, .readOnly] {
            let (error, raw) = reader.scalar(scalar)
            let state: String
            switch NativeFieldBooleanSignal.attribute(status: error, raw: raw) {
            case .value(true): state = "true"
            case .value(false): state = "false"
            case .unavailable: state = "unavailable"
            case .invalid: state = "invalid"
            }
            editability[scalar.rawValue] = ["error": error.rawValue, "state": state]
        }
        result["editability"] = editability

        var attributes: [String: Any] = [:]
        for name in [kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute, kAXValueAttribute,
                     "AXSelectedTextMarkerRange"] {
            let (error, settable) = reader.isSettable(name)
            attributes[name] = ["present": available.contains(name), "settableError": error.rawValue,
                                "settable": error == .success && settable]
        }
        result["attributes"] = attributes

        let (parameterizedError, parameterizedNames) = reader.parameterizedAttributeNames()
        let whitelist: Set<String> = [kAXStringForRangeParameterizedAttribute,
            kAXBoundsForRangeParameterizedAttribute, "AXStringForTextMarkerRange",
            "AXAttributedStringForTextMarkerRange", "AXTextMarkerRangeForUIElement",
            "AXTextMarkerForIndex", "AXIndexForTextMarker", "AXTextOperation",
            "AXStartTextMarkerForTextMarkerRange", "AXEndTextMarkerForTextMarkerRange",
            "AXPreviousTextMarkerForTextMarker", "AXTextMarkerRangeForUnorderedTextMarkers"]
        result["parameterizedAttributesError"] = parameterizedError.rawValue
        result["parameterizedAttributes"] = parameterizedError == .success
            ? Array(Set(parameterizedNames).intersection(whitelist)).sorted() : []
        return result
    }

    private static func inspect(_ target: NSRunningApplication, enable: Bool) -> [String: Any] {
        let app = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var result: [String: Any] = ["pid": target.processIdentifier]
        result["targetIsFrontmost"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        // Chromium can initialize its native AX bridge on this read-only query.
        // Do not enable undocumented app accessibility modes or change TCC.
        var appRole: AnyObject?
        result["applicationRoleError"] = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &appRole).rawValue
        if enable {
            result["enableAccessibilityError"] = AXUIElementSetAttributeValue(app,
                "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue
        }
        var focused: AnyObject?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        result["focusError"] = error.rawValue
        if error != .success {
            focused = nil
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.25)
            var global: AnyObject?
            let globalError = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &global)
            result["systemFocusError"] = globalError.rawValue
            if globalError == .success, let global, CFGetTypeID(global) == AXUIElementGetTypeID() {
                var pid: pid_t = 0
                if AXUIElementGetPid(global as! AXUIElement, &pid) == .success, pid == target.processIdentifier {
                    focused = global
                    result["focusOrigin"] = "systemWide"
                }
            }
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            result["focusAvailable"] = false; return result
        }
        result["focusAvailable"] = true
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var role: AnyObject?
        let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        result["roleError"] = roleError.rawValue
        switch role as? String {
        case kAXTextFieldRole: result["role"] = "AXTextField"
        case kAXTextAreaRole: result["role"] = "AXTextArea"
        case "AXWebArea": result["role"] = "AXWebArea"
        case kAXGroupRole: result["role"] = "AXGroup"
        default: result["role"] = "Other"
        }
        var attributes: [String: Any] = [:]
        for attribute in [kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute, kAXValueAttribute,
                          "AXSelectedTextMarkerRange"] {
            var raw: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
            var settable = DarwinBoolean(false)
            let settableError = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
            attributes[attribute] = ["error": error.rawValue, "present": raw != nil, "type": valueType(raw),
                                     "settableError": settableError.rawValue, "settable": settable.boolValue]
        }
        result["attributes"] = attributes
        var editability: [String: Any] = [:]
        for name in [kAXEnabledAttribute, "AXReadOnly", "AXEditable"] {
            var raw: AnyObject?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
            let signal = NativeFieldBooleanSignal.attribute(status: status, raw: raw)
            let state: String
            switch signal {
            case .value(let value): state = value ? "true" : "false"
            case .unavailable: state = "unavailable"
            case .invalid: state = "invalid"
            }
            editability[name] = ["error": status.rawValue, "state": state]
        }
        result["editability"] = editability
        var names: CFArray?
        let namesError = AXUIElementCopyParameterizedAttributeNames(element, &names)
        let whitelist: Set<String> = [kAXStringForRangeParameterizedAttribute,
            kAXBoundsForRangeParameterizedAttribute, "AXStringForTextMarkerRange",
            "AXAttributedStringForTextMarkerRange", "AXTextMarkerRangeForUIElement",
            "AXTextMarkerForIndex", "AXIndexForTextMarker", "AXTextOperation",
            "AXStartTextMarkerForTextMarkerRange", "AXEndTextMarkerForTextMarkerRange",
            "AXPreviousTextMarkerForTextMarker", "AXTextMarkerRangeForUnorderedTextMarkers"]
        result["parameterizedAttributesError"] = namesError.rawValue
        result["parameterizedAttributes"] = ((names as? [String]) ?? []).filter { whitelist.contains($0) }.sorted()
        return result
    }

    private static func valueType(_ raw: AnyObject?) -> String {
        guard let raw else { return "absent" }
        let type = CFGetTypeID(raw)
        if type == CFStringGetTypeID() { return "string" }
        if type == AXValueGetTypeID() { return "AXValue" }
        if type == CFBooleanGetTypeID() { return "boolean" }
        if type == CFNumberGetTypeID() { return "number" }
        if type == CFArrayGetTypeID() { return "array" }
        if type == AXUIElementGetTypeID() { return "AXUIElement" }
        return "opaque"
    }

    private static func emit(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}
