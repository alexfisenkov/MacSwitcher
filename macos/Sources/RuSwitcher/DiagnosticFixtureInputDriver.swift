import AppKit
import Carbon

// Fixed synthetic fixture only. This driver never accepts a PID, text, arbitrary
// keys or another bundle: it must never type into Codex or any other application.
let diagnosticFixtureBundleID = "com.alexfisenkov.macswitcher.inputfixture"
let diagnosticFixtureEventMarker: Int64 = 0x4D534658

enum DiagnosticFixtureLocation {
    static func matches(actual: URL?, expectedURL: URL = URL(fileURLWithPath:
        "/private/tmp/MacSwitcherInputFixture.app/Contents/MacOS/InputFixture")) -> Bool {
        guard let actual else { return false }
        return actual.resolvingSymlinksInPath().standardizedFileURL.path
            == expectedURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// A local diagnostic scope guard, not a signature/security trust boundary.
func diagnosticFixtureProcessIsKnown(_ processID: Int32) -> Bool {
    guard processID > 0, let app = NSRunningApplication(processIdentifier: processID),
          app.bundleIdentifier == diagnosticFixtureBundleID else { return false }
    return DiagnosticFixtureLocation.matches(actual: app.executableURL)
}

/// HIToolbox requires its input-source state on Main. Only immutable strings
/// cross back to the worker; every event requests a fresh source snapshot.
enum DiagnosticFixtureInputSource {
    struct Snapshot: Sendable {
        let sourceID: String?
        let payload: String?
    }

    static func snapshot(keyCode: UInt16? = nil) -> Snapshot {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { readOnMain(keyCode: keyCode) }
        }
        return DispatchQueue.main.sync { readOnMain(keyCode: keyCode) }
    }

    @MainActor
    private static func readOnMain(keyCode: UInt16?) -> Snapshot {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return Snapshot(sourceID: nil, payload: nil)
        }
        let sourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
        guard let keyCode,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return Snapshot(sourceID: sourceID, payload: nil)
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                  UInt32(kUCKeyTranslateNoDeadKeysMask), &deadState,
                                  characters.count, &length, &characters)
        }
        guard status == noErr, length > 0, length <= characters.count else {
            return Snapshot(sourceID: sourceID, payload: nil)
        }
        let payload = String(utf16CodeUnits: characters, count: length)
        return Snapshot(sourceID: sourceID, payload: payload.allSatisfy(\.isLetter) ? payload : nil)
    }
}

struct DiagnosticFixtureEdge: Equatable, Sendable {
    let atMilliseconds: Int
    let keyCode: UInt16
    let isDown: Bool
    let isShift: Bool
}

enum DiagnosticFixturePlan: String, CaseIterable, Sendable {
    case fast, continuation, tab, doubleShift, twoSingles

    var edges: [DiagnosticFixtureEdge] {
        let prefix: [(Int, UInt16)] = [(0, 5), (15, 4), (30, 11), (45, 2)]
        switch self {
        case .fast: return Self.keys(prefix + [(60, 17), (75, 45)])
        case .continuation: return Self.keys(prefix + [(225, 17), (240, 45)])
        case .tab: return Self.keys(prefix + [(110, 48), (150, 7)])
        case .doubleShift: return Self.shifts(secondDown: 60)
        case .twoSingles: return Self.shifts(secondDown: 270)
        }
    }

    private static func keys(_ keys: [(Int, UInt16)]) -> [DiagnosticFixtureEdge] {
        keys.flatMap { time, code in
            [DiagnosticFixtureEdge(atMilliseconds: time, keyCode: code, isDown: true, isShift: false),
             DiagnosticFixtureEdge(atMilliseconds: time + 3, keyCode: code, isDown: false, isShift: false)]
        }
    }

    private static func shifts(secondDown: Int) -> [DiagnosticFixtureEdge] {
        [DiagnosticFixtureEdge(atMilliseconds: 0, keyCode: 56, isDown: true, isShift: true),
         DiagnosticFixtureEdge(atMilliseconds: 20, keyCode: 56, isDown: false, isShift: true),
         DiagnosticFixtureEdge(atMilliseconds: secondDown, keyCode: 60, isDown: true, isShift: true),
         DiagnosticFixtureEdge(atMilliseconds: secondDown + 20, keyCode: 60, isDown: false, isShift: true)]
    }
}

enum DiagnosticFixtureFocus {
    static func matches(expectedPID: Int32, expectedWindowID: UInt32, frontmostPID: Int32?,
                        frontWindowPID: Int32?, frontWindowID: UInt32?) -> Bool {
        expectedPID > 0 && expectedWindowID > 0 && frontmostPID == expectedPID
            && frontWindowPID == expectedPID && frontWindowID == expectedWindowID
    }
}

enum DiagnosticFixtureOutcome: String, Sendable {
    case completed, postingPermissionUnavailable, fixtureUnavailable, focusLost
    case sourceUnavailable, eventUnavailable, cancelled
}

struct DiagnosticFixtureReport: Sendable {
    let plan: DiagnosticFixturePlan
    let outcome: DiagnosticFixtureOutcome
    let postedEvents: Int
}

@MainActor
final class DiagnosticFixtureInputDriver {
    typealias Plan = DiagnosticFixturePlan
    typealias Outcome = DiagnosticFixtureOutcome
    typealias Report = DiagnosticFixtureReport
    private let processEvent: (@Sendable (CGEvent) -> Bool)?
    private var worker: DiagnosticFixtureWorker?
    private(set) var isRunning = false

    init(processEvent: (@Sendable (CGEvent) -> Bool)? = nil) {
        self.processEvent = processEvent
    }

    /// False means already running. Every accepted request completes once; a
    /// completed report means events were posted, not that text edits succeeded.
    @discardableResult
    func run(plan: Plan, completion: @escaping @MainActor @Sendable (Report) -> Void) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        let finish: @Sendable (Report) -> Void = { [weak self] report in
            Task { @MainActor in
                self?.worker = nil
                self?.isRunning = false
                completion(report)
            }
        }
        guard let processEvent else {
            finish(Report(plan: plan, outcome: .eventUnavailable, postedEvents: 0))
            return true
        }
        guard CGPreflightPostEventAccess() else {
            finish(Report(plan: plan, outcome: .postingPermissionUnavailable, postedEvents: 0))
            return true
        }
        let fixtures = NSRunningApplication.runningApplications(withBundleIdentifier: diagnosticFixtureBundleID)
        guard fixtures.count == 1, let fixture = fixtures.first,
              diagnosticFixtureProcessIsKnown(fixture.processIdentifier),
              fixture.activate(options: []) else {
            finish(Report(plan: plan, outcome: .fixtureUnavailable, postedEvents: 0))
            return true
        }
        let worker = DiagnosticFixtureWorker(plan: plan, processID: fixture.processIdentifier,
                                             processEvent: processEvent, completion: finish)
        self.worker = worker
        worker.start()
        return true
    }

    func cancel() { worker?.cancel() }
    deinit { worker?.cancel() }
}

private final class DiagnosticFixtureWorker: @unchecked Sendable {
    private let plan: DiagnosticFixturePlan
    private let processID: Int32
    private let processEvent: @Sendable (CGEvent) -> Bool
    private let completion: @Sendable (DiagnosticFixtureReport) -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(plan: DiagnosticFixturePlan, processID: Int32, processEvent: @escaping @Sendable (CGEvent) -> Bool,
         completion: @escaping @Sendable (DiagnosticFixtureReport) -> Void) {
        self.plan = plan
        self.processID = processID
        self.processEvent = processEvent
        self.completion = completion
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "MacSwitcher fixed fixture input"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func run() {
        var count = 0
        var held: DiagnosticFixtureEdge?
        var outcome = DiagnosticFixtureOutcome.completed
        let source = CGEventSource(stateID: .privateState)
        defer {
            // Releasing a posted down is unconditional, including focus loss.
            if let held, isKnownFixture() {
                if let up = makeEvent(held, keyDown: false, source: source) {
                    _ = processEvent(up)
                    up.postToPid(processID)
                    count += 1
                } else { outcome = .eventUnavailable }
            }
            completion(DiagnosticFixtureReport(plan: plan, outcome: outcome, postedEvents: count))
        }
        guard let windowID = waitForReadyWindow() else {
            outcome = isCancelled ? .cancelled : .fixtureUnavailable
            return
        }
        let sourceDeadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while currentSourceID() != "com.apple.keylayout.US" {
            if let failure = wait(until: min(sourceDeadline, DispatchTime.now().uptimeNanoseconds + 5_000_000),
                                  windowID: windowID) { outcome = failure; return }
            if DispatchTime.now().uptimeNanoseconds >= sourceDeadline { outcome = .sourceUnavailable; return }
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds + 50_000_000
        for edge in plan.edges {
            let deadline = startedAt + UInt64(edge.atMilliseconds) * 1_000_000
            if let failure = wait(until: deadline, windowID: windowID) { outcome = failure; return }
            guard let event = makeEvent(edge, keyDown: edge.isDown, source: source) else {
                outcome = .eventUnavailable
                return
            }
            // Exercise the monitor explicitly; PID posting bypasses its global tap.
            if edge.isDown, !hasExpectedFocus(windowID: windowID) { outcome = .focusLost; return }
            let forwarded = processEvent(event)
            if edge.isDown, !forwarded { outcome = .eventUnavailable; return }
            if edge.isDown, !hasExpectedFocus(windowID: windowID) { outcome = .focusLost; return }
            guard isKnownFixture() else { outcome = .fixtureUnavailable; return }
            event.postToPid(processID)
            count += 1
            held = edge.isDown ? edge : nil
            if !forwarded { outcome = .eventUnavailable; return }
        }
        if let failure = wait(until: startedAt + 600_000_000, windowID: windowID) { outcome = failure }
    }

    private func waitForReadyWindow() -> UInt32? {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
            if isKnownFixture(), NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
               let front = frontWindow(), front.pid == processID, front.id > 0 { return front.id }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    private func wait(until deadline: UInt64, windowID: UInt32) -> DiagnosticFixtureOutcome? {
        while true {
            if isCancelled { return .cancelled }
            if !hasExpectedFocus(windowID: windowID) { return .focusLost }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return nil }
            Thread.sleep(forTimeInterval: Double(min(deadline - now, 5_000_000)) / 1_000_000_000)
        }
    }

    private func isKnownFixture() -> Bool {
        diagnosticFixtureProcessIsKnown(processID)
    }

    private func hasExpectedFocus(windowID: UInt32) -> Bool {
        guard isKnownFixture(), let front = frontWindow() else { return false }
        return DiagnosticFixtureFocus.matches(expectedPID: processID, expectedWindowID: windowID,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            frontWindowPID: front.pid, frontWindowID: front.id)
    }

    private func frontWindow() -> (pid: Int32, id: UInt32)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = window[kCGWindowNumber as String] as? NSNumber else { continue }
            return (pid.int32Value, number.uint32Value)
        }
        return nil
    }

    private func currentSourceID() -> String? {
        DiagnosticFixtureInputSource.snapshot().sourceID
    }

    private func makeEvent(_ edge: DiagnosticFixtureEdge, keyDown: Bool, source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: edge.keyCode, keyDown: keyDown) else { return nil }
        event.flags = edge.isShift && keyDown ? .maskShift : []
        if edge.isShift {
            event.type = .flagsChanged
        } else if edge.keyCode == 48 {
            var tab: UniChar = 9
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &tab)
        } else if let payload = currentPayload(for: edge.keyCode) {
            let utf16 = Array(payload.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
        } else if keyDown { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: diagnosticFixtureEventMarker)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(processID))
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        return event
    }

    private func currentPayload(for keyCode: UInt16) -> String? {
        DiagnosticFixtureInputSource.snapshot(keyCode: keyCode).payload
    }
}
