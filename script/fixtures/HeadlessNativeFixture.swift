import AppKit
import ApplicationServices

// Fixed synthetic cases only. This executable never activates an application,
// creates a document/window, changes the input source, or posts global events.
// AppKit may create its own invisible text-input helper window.
let kRuSwitcherEventMarker: Int64 = 0x52555300
private let fixtureMarker = kRuSwitcherEventMarker

// Value-only dependency for the shared production focus-retry helper.
enum CombinedShiftExecutionFailure {
    case revisionChanged, wrongProcess, secureInput, focusUnavailable, focusChanged
}

private enum FixtureCase: String, CaseIterable {
    case word, word6, word12, word24, continuation, neighbours, selection, longSelection, selection8192
    case delayed5, delayed20, delayed50, delayed150, delayed250, delayed350
    case programmaticFocusChange, droppedReplacement

    var original: String {
        switch self {
        case .longSelection: return String(repeating: "ghbdtn ", count: 100)
        case .selection8192: return String(repeating: "a", count: 8192)
        case .word6, .selection: return "ghbdtn"
        case .word12: return String(repeating: "ghbd", count: 3)
        case .word24: return String(repeating: "ghbd", count: 6)
        default: return "ghbd"
        }
    }
    var replacement: String {
        switch self {
        case .longSelection: return String(repeating: "привет ", count: 100)
        case .selection8192: return String(repeating: "ф", count: 8192)
        case .word6, .selection: return "привет"
        case .word12: return String(repeating: "прив", count: 3)
        case .word24: return String(repeating: "прив", count: 6)
        default: return "прив"
        }
    }
    var prefix: String { self == .neighbours ? "START 😀 e\u{301} " : "" }
    var suffix: String { self == .neighbours ? " END 🧑🏽‍💻" : "" }
    var selected: Bool { self == .selection || self == .longSelection || self == .selection8192 }
    var delay: TimeInterval {
        switch self {
        case .delayed5: return 0.005
        case .delayed20: return 0.020
        case .delayed50: return 0.050
        case .delayed150: return 0.150
        case .delayed250: return 0.250
        case .delayed350: return 0.350
        default: return 0
        }
    }
    var hasContinuation: Bool { self == .continuation || self == .delayed250 || self == .delayed350 }
    var start: Int { prefix.utf16.count }
    var expected: String { prefix + replacement + (hasContinuation ? "ет" : "") + suffix }
}

@MainActor
private final class HeadlessFixtureApplication: NSApplication {
    var fixtureCase = FixtureCase.word
    var expectedSender: Int32 = -1
    var originalFrontmost: Int32?
    var environmentalFailure = false
    var markedEvents = 0
    private(set) var focusMoved = false
    private(set) var droppedReplacement = false
    var activeField: NSTextView { focusMoved ? otherField : field }
    private var pending: [(NSEvent, TimeInterval)] = []
    var hasPendingDelivery: Bool { !pending.isEmpty }
    lazy var field: NSTextView = {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 250))
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.setAccessibilityElement(true)
        return view
    }()

    lazy var otherField: NSTextView = {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 250))
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.string = "SECOND_FIELD_SENTINEL"
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.setAccessibilityElement(true)
        return view
    }()

    // NSApplication has no modern focusedUIElement override. This fixture-only
    // compatibility entry publishes just our unattached synthetic text view.
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        super.accessibilityAttributeNames() + [
            NSAccessibility.Attribute(rawValue: "AXFixtureMarkedEventCount"),
            NSAccessibility.Attribute(rawValue: "AXFixtureHasPendingDelivery")]
    }
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if attribute == .focusedUIElement { return MainActor.assumeIsolated { activeField } }
        if attribute.rawValue == "AXFixtureMarkedEventCount" {
            return MainActor.assumeIsolated { NSNumber(value: markedEvents) }
        }
        if attribute.rawValue == "AXFixtureHasPendingDelivery" {
            return MainActor.assumeIsolated { NSNumber(value: hasPendingDelivery) }
        }
        return super.accessibilityAttributeValue(attribute)
    }
    override func accessibilityChildren() -> [Any]? { [field, otherField] }

    var screenUnchanged: Bool {
        activationPolicy() == .prohibited && !windows.contains(where: \.isVisible)
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmost
    }

    override func sendEvent(_ event: NSEvent) {
        guard let raw = event.cgEvent,
              raw.getIntegerValueField(.eventSourceUserData) == fixtureMarker,
              raw.getIntegerValueField(.eventSourceUnixProcessID) == Int64(expectedSender),
              event.type == .keyDown || event.type == .keyUp else { return }
        guard screenUnchanged else { environmentalFailure = true; return }
        markedEvents += 1
        pending.append((event, ProcessInfo.processInfo.systemUptime + fixtureCase.delay))
        flushReady()
    }

    func flushReady() {
        guard screenUnchanged else { environmentalFailure = true; pending.removeAll(); return }
        while let first = pending.first, first.1 <= ProcessInfo.processInfo.systemUptime {
            pending.removeFirst()
            if first.0.type == .keyDown {
                if fixtureCase == .droppedReplacement, !droppedReplacement, first.0.keyCode == 0 {
                    droppedReplacement = true // Simulate one undelivered Unicode key-down only.
                } else { activeField.keyDown(with: first.0) }
                // Deterministic adversarial field switch inside the same PID.
                // Already queued PID-addressed events follow the new responder.
                if fixtureCase == .programmaticFocusChange, !focusMoved, first.0.keyCode == 123 {
                    _ = otherField
                    focusMoved = true
                }
            }
        }
    }
}

@main
private struct HeadlessNativeFixture {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 3, args[0] == "--driver", let fixtureCase = FixtureCase(rawValue: args[1]),
           let target = Int32(args[2]), target == getppid() {
            exit(runDriver(fixtureCase, target: target))
        }
        if args.count == 2, args[0] == "--fixture", let fixtureCase = FixtureCase(rawValue: args[1]) {
            exit(runFixture(fixtureCase))
        }
        guard args.isEmpty else { emit(["error": "No arbitrary PID, text, or action is accepted."]); exit(2) }
        var failed = false
        // The adversarial focus-change reproducer intentionally fails if it
        // changes B. Run it explicitly; never count unsupported routing as PASS.
        for fixtureCase in FixtureCase.allCases where fixtureCase != .programmaticFocusChange && fixtureCase != .droppedReplacement {
            let child = Process()
            child.executableURL = executable
            child.arguments = ["--fixture", fixtureCase.rawValue]
            do {
                try child.run()
                child.waitUntilExit()
                failed = failed || child.terminationStatus != 0
            } catch { emit(["case": fixtureCase.rawValue, "error": "fixtureLaunchFailed"]); failed = true }
        }
        exit(failed ? 1 : 0)
    }

    private static var executable: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL }
    private static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
    }

    @MainActor
    private static func runFixture(_ fixtureCase: FixtureCase) -> Int32 {
        let app = HeadlessFixtureApplication.shared as! HeadlessFixtureApplication
        app.setActivationPolicy(.prohibited)
        app.originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        app.fixtureCase = fixtureCase
        app.finishLaunching()
        app.field.string = fixtureCase.prefix + fixtureCase.original + fixtureCase.suffix
        app.field.setSelectedRange(NSRange(location: fixtureCase.start + (fixtureCase.selected ? 0 : fixtureCase.original.utf16.count),
                                            length: fixtureCase.selected ? fixtureCase.original.utf16.count : 0))
        guard app.screenUnchanged else { emit(["case": fixtureCase.rawValue, "error": "environmentChanged"]); return 1 }
        let child = Process()
        let output = Pipe()
        child.executableURL = executable
        child.arguments = ["--driver", fixtureCase.rawValue, String(ProcessInfo.processInfo.processIdentifier)]
        child.standardOutput = output
        do { try child.run() }
        catch { emit(["case": fixtureCase.rawValue, "error": "driverLaunchFailed"]); return 1 }
        app.expectedSender = child.processIdentifier
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline && !app.environmentalFailure {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.002), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            app.flushReady()
        }
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        let driverData = output.fileHandleForReading.readDataToEndOfFile()
        let driver = (try? JSONSerialization.jsonObject(with: driverData)) as? [String: Any] ?? [:]
        let expectedEvents = (driver["postedEvents"] as? Int ?? 0) + ((driver["continuationQueued"] as? Bool ?? false) ? 2 : 0)
        // An original-looking read may precede the selection phase in the OS
        // queue. Drain every already queued pair before final fixture verdict.
        let drainDeadline = ProcessInfo.processInfo.systemUptime + fixtureCase.delay + 0.300
        while (app.markedEvents < expectedEvents || app.hasPendingDelivery),
              ProcessInfo.processInfo.systemUptime < drainDeadline, !app.environmentalFailure {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.002), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            app.flushReady()
        }
        let textQueued = driver["textQueued"] as? Bool ?? false
        let expectsOriginal = !textQueued || fixtureCase == .droppedReplacement
        let expectedBase = expectsOriginal ? fixtureCase.original : fixtureCase.replacement
        let expectedTail = fixtureCase.hasContinuation ? (textQueued ? "ет" : "tn") : ""
        let expectedText = fixtureCase.prefix + expectedBase + expectedTail + fixtureCase.suffix
        let expectedCaret = fixtureCase.start + expectedBase.utf16.count + expectedTail.utf16.count
        let exact = app.field.string.utf16.elementsEqual(expectedText.utf16)
            && app.field.selectedRange() == NSRange(location: expectedCaret, length: 0)
        let bothTextsUntouched = app.field.string == fixtureCase.prefix + fixtureCase.original + fixtureCase.suffix
            && app.otherField.string == "SECOND_FIELD_SENTINEL"
        let focusAbort = fixtureCase == .programmaticFocusChange && app.focusMoved && !textQueued && bothTextsUntouched
        let passed = child.terminationStatus == 0 && (exact || focusAbort) && app.screenUnchanged && !app.environmentalFailure
            && app.otherField.string == "SECOND_FIELD_SENTINEL"
        emit(["case": fixtureCase.rawValue, "passed": passed, "driver": driver,
              "programmaticFocusMoved": app.focusMoved, "simulatedUnicodeDrop": app.droppedReplacement,
              "outcomeKind": expectsOriginal ? "abortIntegrity" : "conversion",
              "originalFieldTextUnchanged": app.field.string == fixtureCase.prefix + fixtureCase.original + fixtureCase.suffix,
              "otherFieldUnchanged": app.otherField.string == "SECOND_FIELD_SENTINEL",
              "otherFieldReplacedBySyntheticText": app.otherField.string == fixtureCase.replacement,
              "textAndCaretExact": exact, "markedEvents": app.markedEvents,
              "visibleWindows": app.windows.filter(\.isVisible).count,
              "frontmostUnchanged": NSWorkspace.shared.frontmostApplication?.processIdentifier == app.originalFrontmost,
              "scope": "owned-background-AppKit-and-cross-process-AX-only"])
        return passed ? 0 : 1
    }

    @MainActor
    private static func runDriver(_ fixtureCase: FixtureCase, target: Int32) -> Int32 {
        guard AXIsProcessTrusted() else { emit(["error": "accessibilityUnavailableNoPrompt"]); return 1 }
        let application = AXUIElementCreateApplication(target)
        AXUIElementSetMessagingTimeout(application, 0.020)
        var raw: CFTypeRef?
        var discoveryStatus = AXError.cannotComplete
        let discoveryDeadline = ProcessInfo.processInfo.systemUptime + 0.500
        repeat {
            discoveryStatus = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &raw)
            if discoveryStatus == .success { break }
            usleep(1000)
        } while ProcessInfo.processInfo.systemUptime < discoveryDeadline
        guard discoveryStatus == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            emit(["error": "fixtureAXUnavailable", "status": discoveryStatus.rawValue]); return 1
        }
        let field = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(field, 0.003)
        let ordinary = fixtureCase.selected ? nil : NativeAutoEventTransport(
            original: fixtureCase.original, replacement: fixtureCase.replacement)
        let selected = fixtureCase.selected ? NativeSelectedTextEventTransport(replacement: fixtureCase.replacement) : nil
        guard ordinary != nil || selected != nil else { emit(["error": "eventPreparationFailed"]); return 1 }
        var observations = 0
        var posted = 0
        var textQueued = false
        var cancellationQueued = false
        var continuationQueued = false
        var identityReadFailures: [String: Int] = [:]
        var nilObservations = 0
        var observedStates: [String: Int] = [:]
        var observedSelections: [String: Int] = [:]
        let started = ProcessInfo.processInfo.systemUptime
        let editDeadline = started + VerifiedNativeFieldEditor.maximumDuration
        func valid(until deadline: TimeInterval) -> Bool {
            NativeFocusRevalidation.validate(until: deadline, now: { ProcessInfo.processInfo.systemUptime },
                mayContinue: { target == getppid() }, read: {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { return .focusUnavailable }
                    AXUIElementSetMessagingTimeout(application, Float(min(0.020, remaining)))
                    var focused: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
                    if status != .success { identityReadFailures[String(status.rawValue), default: 0] += 1 }
                    if status == .cannotComplete || status == .noValue { return .focusUnavailable }
                    guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
                          CFEqual(focused, field) else { return .focusChanged }
                    return nil
                }, pause: { usleep(useconds_t($0 * 1_000_000)) })
        }
        let access = NativeFieldAccess(validateOriginalIdentity: { valid(until: $0) }, cheapGate: { target == getppid() },
            isEditable: { deadline in
                guard boundTimeout(field, deadline: deadline) else { return false }
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
            }, observe: { deadline in
                observations += 1
                let value = observe(field, deadline: deadline)
                if let value {
                    let originalText = fixtureCase.prefix + fixtureCase.original + fixtureCase.suffix
                    let finalText = fixtureCase.prefix + fixtureCase.replacement + fixtureCase.suffix
                    let finalCaret = fixtureCase.start + fixtureCase.replacement.utf16.count
                    let kind: String
                    if value.text == originalText && value.selectionLength == 0 && value.caretUTF16Location == finalCaret && fixtureCase.selected {
                        kind = "oldTextNewCaret"
                    } else if value.text == finalText && value.selectionLength != 0 { kind = "newTextOldSelection" }
                    else { kind = "ordinaryObservation" }
                    observedStates[kind, default: 0] += 1
                    let textKind = value.text == originalText ? "original"
                        : value.text == finalText ? "replacement" : "other"
                    let position = "\(textKind):\(value.caretUTF16Location):\(value.selectionLength)"
                    observedSelections[position, default: 0] += 1
                } else { nilObservations += 1 }
                return value
            }, postBatch: { requested in
                let sent: Bool
                if let ordinary {
                    sent = ordinary.postBatch(requested, to: target, whileCurrent: { valid(until: editDeadline) })
                    if sent {
                        posted += requested == ordinary.preparedSelection.operations
                            ? ordinary.preparedSelection.events.count : ordinary.preparedReplacement.events.count
                    }
                } else if let selected {
                    guard requested == [.insertReplacement] else { return false }
                    sent = selected.post(to: target, whileCurrent: { valid(until: editDeadline) })
                    if sent { posted += selected.events.count }
                } else { return false }
                return sent
            }, cancelPreparedSelection: { deadline in
                guard let ordinary, target == getppid(), ProcessInfo.processInfo.systemUptime < deadline else { return false }
                let sent = ordinary.cancelPreparedSelection(to: target, whileCurrent: {
                    target == getppid() && ProcessInfo.processInfo.systemUptime < deadline
                })
                if sent { posted += ordinary.preparedCancellation.events.count; cancellationQueued = true }
                return sent
            }, now: { ProcessInfo.processInfo.systemUptime }, pause: { usleep(useconds_t($0 * 1_000_000)) })
        let result = fixtureCase.selected
            ? VerifiedNativeFieldEditor.executeSelection(original: fixtureCase.original, replacement: fixtureCase.replacement,
                                                         start: fixtureCase.start, access: access, onTextQueued: { textQueued = true })
            : VerifiedNativeFieldEditor.execute(original: fixtureCase.original, replacement: fixtureCase.replacement,
                                                start: fixtureCase.start, access: access, onTextQueued: { textQueued = true })
        let executorCompletedAt = ProcessInfo.processInfo.systemUptime
        let executorMilliseconds = (executorCompletedAt - started) * 1000
        let confirmed = result == .confirmed
        var uncertain = false
        if case .uncertain = result { uncertain = true }
        var preparationUncertain = false
        if case .preparationUncertain = result { preparationUncertain = true }
        let aborted = !textQueued && (result == .refused || uncertain)
        // The fixture parent independently checks both field values before PASS.
        let focusAbort = fixtureCase == .programmaticFocusChange && !textQueued
            && (aborted || preparationUncertain)
        let dropDetected = fixtureCase == .droppedReplacement && textQueued && uncertain
        // Parent requires exact original text/caret and unchanged second field.
        let delayedSafeAbort = fixtureCase.delay >= 0.050
            && (aborted || uncertain || (!textQueued && preparationUncertain))
        let expectedOutcome = focusAbort || dropDetected || confirmed ||
            delayedSafeAbort
        let expectsOriginal = !textQueued || fixtureCase == .droppedReplacement
        let expectedBase = expectsOriginal ? fixtureCase.original : fixtureCase.replacement
        let expectedTail = fixtureCase.hasContinuation ? (textQueued ? "ет" : "tn") : ""
        let expectedText = fixtureCase.prefix + expectedBase + expectedTail + fixtureCase.suffix
        let continuationDeadline = min(editDeadline, ProcessInfo.processInfo.systemUptime + 0.020)
        if expectedOutcome && fixtureCase.hasContinuation,
           let tail = NativeSelectedTextEventTransport(replacement: expectedTail),
           valid(until: continuationDeadline) {
            // Fixed synthetic continuation is queued only after the executor
            // returns; it must follow the already queued complete edit batch.
            continuationQueued = tail.post(to: target, whileCurrent: { valid(until: continuationDeadline) })
        }
        // Wait for our parent fixture to receive and deliver every posted pair.
        // An early AX snapshot must not let the sender exit with queued events.
        let expectedEvents = posted + (continuationQueued ? 2 : 0)
        let postExecutorStarted = executorCompletedAt
        let postExecutorDeadline = postExecutorStarted + 1.500
        var receiptCount: Int?
        var receiptPending: Bool?
        var receiptComplete = false
        var receiptReadFailures: [String: Int] = [:]
        while ProcessInfo.processInfo.systemUptime < postExecutorDeadline, target == getppid() {
            let remaining = postExecutorDeadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  AXUIElementSetMessagingTimeout(application, Float(min(0.020, remaining / 2))) == .success else { break }
            var countRaw: CFTypeRef?
            var pendingRaw: CFTypeRef?
            let countStatus = AXUIElementCopyAttributeValue(application,
                "AXFixtureMarkedEventCount" as CFString, &countRaw)
            let pendingStatus = AXUIElementCopyAttributeValue(application,
                "AXFixtureHasPendingDelivery" as CFString, &pendingRaw)
            if countStatus == .success, pendingStatus == .success,
               let count = (countRaw as? NSNumber)?.intValue,
               let pending = (pendingRaw as? NSNumber)?.boolValue {
                receiptCount = count
                receiptPending = pending
                if count == expectedEvents && !pending { receiptComplete = true; break }
                if count > expectedEvents { break }
            } else {
                receiptReadFailures["\(countStatus.rawValue):\(pendingStatus.rawValue)", default: 0] += 1
            }
            usleep(useconds_t(min(0.001, max(0, postExecutorDeadline - ProcessInfo.processInfo.systemUptime)) * 1_000_000))
        }
        var finalExact = false
        if receiptComplete {
            while ProcessInfo.processInfo.systemUptime < postExecutorDeadline {
                if let observation = observe(field, deadline: postExecutorDeadline), observation.text.utf16.elementsEqual(expectedText.utf16),
                   observation.caretUTF16Location == fixtureCase.start + expectedBase.utf16.count + expectedTail.utf16.count,
                   observation.selectionLength == 0 { finalExact = true; break }
                usleep(useconds_t(min(0.001, max(0, postExecutorDeadline - ProcessInfo.processInfo.systemUptime)) * 1_000_000))
            }
        }
        emit(["confirmed": confirmed, "resultKind": confirmed ? "confirmed" : uncertain ? "uncertain" : preparationUncertain ? "preparationUncertain" : "refused",
              "textQueued": textQueued, "cancellationQueued": cancellationQueued, "continuationQueued": continuationQueued, "expectedOutcome": expectedOutcome, "finalDeliveryConfirmed": finalExact, "postedEvents": posted,
              "receiptExpectedEvents": expectedEvents, "receiptObservedEvents": receiptCount ?? -1,
              "receiptPendingDelivery": receiptPending ?? true, "receiptComplete": receiptComplete,
              "receiptAttributesAvailable": receiptCount != nil && receiptPending != nil,
              "receiptReadFailures": receiptReadFailures, "executorMilliseconds": executorMilliseconds,
              "postExecutorDrainMilliseconds": (ProcessInfo.processInfo.systemUptime - postExecutorStarted) * 1000,
              "observations": observations, "nilObservations": nilObservations,
              "identityReadFailures": identityReadFailures, "observedStates": observedStates,
              "observedSelections": observedSelections,
              "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000])
        return expectedOutcome && receiptComplete && (finalExact || focusAbort) ? 0 : 1
    }

    private static func boundTimeout(_ field: AXUIElement, deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        return remaining > 0 && AXUIElementSetMessagingTimeout(field, Float(min(0.003, remaining))) == .success
    }

    private static func observe(_ field: AXUIElement, deadline: TimeInterval? = nil) -> NativeFieldObservation? {
        let deadline = deadline ?? ProcessInfo.processInfo.systemUptime + 0.020
        var value: CFTypeRef?
        var selection: CFTypeRef?
        guard boundTimeout(field, deadline: deadline),
              AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              boundTimeout(field, deadline: deadline),
              AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range) else { return nil }
        return NativeFieldObservation(text: text, caretUTF16Location: range.location, selectionLength: range.length)
    }

}
