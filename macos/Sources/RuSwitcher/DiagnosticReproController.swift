import AppKit
import ApplicationServices

/// Opt-in developer integration fixture, confined to exact synthetic TextEdit
/// input. It never writes AXValue. The coordinator fixture supplies only the
/// Latin prefix; the native fixture explicitly tests the converter's transport.
@MainActor
final class DiagnosticReproController: NSObject {
    private let monitor: KeyboardMonitor
    private let converter: TextConverter
    private let window: NSWindow
    private let status = NSTextField(labelWithString:
        "Use a separate TextEdit document. Selection: select ghbdtn. Auto/native: put ghbd in an otherwise empty document, caret at end.")
    private var running = false
    private var runningAuto = false
    private var automaticApplications = 0
    private var fixtureDriver: DiagnosticFixtureInputDriver?

    init(monitor: KeyboardMonitor, converter: TextConverter) {
        self.monitor = monitor
        self.converter = converter
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "MacSwitcher — Internal Integration Test"
        window.isReleasedWhenClosed = false
        let selection = NSButton(title: "Test selected ghbdtn", target: self, action: #selector(testSelection))
        selection.frame = NSRect(x: 20, y: 195, width: 275, height: 32)
        let auto = NSButton(title: "Test early correction of ghbd", target: self, action: #selector(testAuto))
        auto.frame = NSRect(x: 305, y: 195, width: 295, height: 32)
        let native = NSButton(title: "Test native correction of ghbd", target: self, action: #selector(testNative))
        native.frame = NSRect(x: 20, y: 155, width: 275, height: 32)
        let arm = NSButton(title: "Arm one Codex test (30 s)", target: self, action: #selector(armCodexCanary))
        arm.frame = NSRect(x: 305, y: 155, width: 295, height: 32)
        status.frame = NSRect(x: 20, y: 25, width: 580, height: 110)
        status.maximumNumberOfLines = 5
        window.contentView?.addSubview(selection)
        window.contentView?.addSubview(auto)
        window.contentView?.addSubview(native)
        window.contentView?.addSubview(arm)
        let fixturePlans: [(String, DiagnosticFixturePlan)] = [
            ("Fixture: fast", .fast), ("Fixture: continue", .continuation),
            ("Fixture: Tab", .tab), ("Fixture: double Shift", .doubleShift),
            ("Fixture: two singles", .twoSingles)
        ]
        for (offset, entry) in fixturePlans.enumerated() {
            let button = NSButton(title: entry.0, target: self, action: #selector(runOwnedFixture(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(entry.1.rawValue)
            button.frame = NSRect(x: 20 + (offset % 3) * 195, y: 292 - (offset / 3) * 37, width: 190, height: 32)
            window.contentView?.addSubview(button)
        }
        window.contentView?.addSubview(status)
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func noteAutomaticApplication() {
        if runningAuto { automaticApplications += 1 }
    }

    @objc private func runOwnedFixture(_ sender: NSButton) {
        guard !running, fixtureDriver?.isRunning != true,
              CommandLine.arguments.contains("--diagnostic-native-canary"),
              monitor.nativeInputTransportAvailable,
              let raw = sender.identifier?.rawValue,
              let plan = DiagnosticFixturePlan(rawValue: raw),
              let processor = monitor.makeDiagnosticFixtureEventProcessor() else { return }
        running = true
        monitor.resetCombinedShift()
        monitor.resetPredictionContext()
        converter.clearState()
        status.stringValue = "Posting fixed synthetic fixture plan: \(plan.rawValue). Prepare Fixture A and US first."
        let driver = DiagnosticFixtureInputDriver(processEvent: processor)
        fixtureDriver = driver
        driver.run(plan: plan) { [weak self] report in
            guard let self else { return }
            self.running = false
            let focusDetail = report.focusFailure.map { " Focus failure: \($0.rawValue)." } ?? ""
            self.status.stringValue = "Synthetic pipeline \(report.plan.rawValue): \(report.outcome.rawValue), \(report.postedEvents) events. Inspect both fields/source. This is not physical HID acceptance." + focusDetail
            // Keep the fixture frontmost so its final selection/source can be
            // independently observed without another focus transition.
        }
    }

    @objc private func armCodexCanary() {
        guard !running, monitor.nativeInputTransportAvailable, AutomaticEditorPolicy.armCanary() else {
            status.stringValue = "Not armed. Both diagnostic flags and an active tap are required; a claimed attempt cannot be armed again."
            return
        }
        status.stringValue = "One Codex test armed for 30 seconds. In a separate empty Codex draft choose US and type only ghbd. Stop typing; do not send or switch fields until the result is checked. Ordinary Codex auto remains blocked."
    }

    @objc private func testSelection() {
        guard !running else { return }
        running = true
        status.stringValue = "Running internal selection replacement…"
        RuntimeDiagnostics.record(.harnessSelectionStarted)
        Task { @MainActor in
            defer { self.running = false }
            guard let target = await self.activateTextEdit(),
                  let focus = CombinedShiftFocus.capture(processID: target.processIdentifier),
                  focus.selectedTextMatches("ghbdtn"),
                  self.readValue(focus.element) == "ghbdtn",
                  let context = LayoutSwitcher.combinedShiftContext(sourceLayoutID: "com.apple.keylayout.US") else {
                self.finish(false, automatic: false, reason: "Prepare a separate TextEdit document containing only ghbdtn and select it.")
                return
            }
            self.monitor.resetCombinedShift()
            let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: self.monitor.inputRevision,
                currentInputRevision: { [weak monitor = self.monitor] in monitor?.inputRevision ?? UInt64.max })
            LayoutSwitcher.switchTo(layoutID: context.targetLayoutID)
            guard let lease = self.monitor.beginNativeInputTransaction(processID: focus.processID) else {
                self.finish(false, automatic: false, reason: "Native input fence unavailable.")
                return
            }
            var replayLayoutID: String?
            defer { self.monitor.finishNativeInputTransaction(lease, replayLayoutID: replayLayoutID) }
            let success = self.converter.convertSelection(context: context, execution: execution,
                inputBarrierIsActive: { self.monitor.nativeInputTransactionIsCurrent(lease) })
            if success {
                self.monitor.markConverted()
                if let result = self.converter.lastResultLayoutID, LayoutSwitcher.switchTo(layoutID: result) {
                    replayLayoutID = result
                }
            }
            self.finish(success && self.readValue(focus.element) == "привет", automatic: false)
        }
    }

    @objc private func testAuto() {
        guard !running else { return }
        guard SettingsManager.shared.autoSwitchEnabled && SettingsManager.shared.autoConvert else {
            finish(false, automatic: true, reason: "Enable MacSwitcher and automatic correction in its menu first.")
            return
        }
        running = true
        runningAuto = true
        automaticApplications = 0
        status.stringValue = "Running coordinator fixture on the prepared prefix; no Space is sent…"
        RuntimeDiagnostics.record(.harnessAutoStarted)
        Task { @MainActor in
            defer { self.running = false; self.runningAuto = false }
            guard let target = await self.activateTextEdit(),
                  let original = CombinedShiftFocus.capture(processID: target.processIdentifier),
                  self.readValue(original.element) == "ghbd",
                  let range = original.initialSelection, range.length == 0, range.location == 4 else {
                self.finish(false, automatic: true, reason: "Prepare only ghbd in a separate TextEdit document, caret at end.")
                return
            }
            LayoutSwitcher.switchTo(layoutID: "com.apple.keylayout.US")
            guard LayoutSwitcher.currentLayoutID() == "com.apple.keylayout.US" else {
                self.finish(false, automatic: true, reason: "US input source could not be selected.")
                return
            }
            self.monitor.resetCombinedShift()
            self.monitor.resetPredictionContext()
            self.converter.clearState()
            guard original.isCurrent(), self.readValue(original.element) == "ghbd",
                  self.monitor.diagnosticReplayTextEditPrefix() else {
                self.finish(false, automatic: true, reason: "Original test field changed before submission.")
                return
            }
            for _ in 0..<40 {
                guard original.isCurrent() else {
                    self.finish(false, automatic: true, reason: "Focus changed during the test.")
                    return
                }
                if self.automaticApplications == 1, self.readValue(original.element) == "прив" {
                    self.finish(true, automatic: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            self.finish(false, automatic: true)
        }
    }

    /// Transport-only fixture: no coordinator replay or physical-HID claim.
    @objc private func testNative() {
        guard !running else { return }
        guard CommandLine.arguments.contains("--diagnostic-native-canary"),
              monitor.nativeInputTransportAvailable else {
            finishNative(false, reason: "Active native input gate unavailable. Relaunch with --diagnostic-panel --diagnostic-native-canary.")
            return
        }
        running = true
        status.stringValue = "Running native transport fixture on prepared ghbd; no Space is sent…"
        RuntimeDiagnostics.record(.harnessNativeStarted)
        Task { @MainActor in
            defer { self.running = false }
            guard let target = await self.activateTextEdit(),
                  let focus = CombinedShiftFocus.capture(processID: target.processIdentifier),
                  self.readValue(focus.element) == "ghbd",
                  let range = focus.initialSelection, range.location == 4, range.length == 0,
                  let context = LayoutSwitcher.combinedShiftContext(sourceLayoutID: "com.apple.keylayout.US") else {
                self.finishNative(false, reason: "Prepare only ghbd in a separate TextEdit document, caret at end.")
                return
            }
            LayoutSwitcher.switchTo(layoutID: "com.apple.keylayout.US")
            guard LayoutSwitcher.currentLayoutID() == "com.apple.keylayout.US" else {
                self.finishNative(false, reason: "US input source could not be selected.")
                return
            }
            self.monitor.resetCombinedShift()
            self.monitor.resetPredictionContext()
            self.converter.clearState()
            let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: self.monitor.inputRevision,
                currentInputRevision: { [weak monitor = self.monitor] in monitor?.inputRevision ?? UInt64.max })
            guard let lease = self.monitor.beginNativeInputTransaction(processID: focus.processID) else {
                self.finishNative(false, reason: "Test field or native input gate changed before the transaction.")
                return
            }
            var replayLayoutID: String?
            defer { self.monitor.finishNativeInputTransaction(lease, replayLayoutID: replayLayoutID) }
            guard execution.isValid(), self.readValue(focus.element) == "ghbd" else {
                self.finishNative(false, reason: "Test field changed before the transaction.")
                return
            }
            let success = self.converter.replaceVerifiedSuffix(original: "ghbd", replacement: "прив",
                sourceLayoutID: context.sourceLayoutID, resultLayoutID: context.targetLayoutID,
                execution: execution,
                inputBarrierIsActive: { [weak monitor = self.monitor] in
                    monitor?.nativeInputTransactionIsCurrent(lease) == true
                },
                forceNativeFixture: true)
            if success {
                self.monitor.markConverted()
                if let result = self.converter.lastResultLayoutID, LayoutSwitcher.switchTo(layoutID: result) {
                    replayLayoutID = result
                }
            }
            let finalRange = focus.selectionRange()
            self.finishNative(success && self.readValue(focus.element) == "прив"
                && finalRange?.location == 4 && finalRange?.length == 0,
                reason: "Native transaction was not confirmed. Leave the test text unchanged for inspection.")
        }
    }

    private func activateTextEdit() async -> NSRunningApplication? {
        guard CommandLine.arguments.contains("--diagnostic-panel"),
              let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) else { return nil }
        target.activate(options: [.activateIgnoringOtherApps])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                try? await Task.sleep(for: .milliseconds(60))
                return target
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func readValue(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func finish(_ success: Bool, automatic: Bool, reason: String? = nil) {
        RuntimeDiagnostics.record(automatic
            ? (success ? .harnessAutoPassed : .harnessAutoFailed)
            : (success ? .harnessSelectionPassed : .harnessSelectionFailed))
        status.stringValue = success
            ? "Internal path PASS: \(automatic ? "coordinator applied ghbd → прив before Space" : "selected ghbdtn → привет verified"). Physical keyboard acceptance is separate."
            : "Internal path FAIL: \(reason ?? "No confirmed replacement. Inspect diagnostic stages.")"
        show()
    }

    private func finishNative(_ success: Bool, reason: String? = nil) {
        RuntimeDiagnostics.record(success ? .harnessNativePassed : .harnessNativeFailed)
        status.stringValue = success
            ? "Internal transport PASS: native ghbd → прив and collapsed caret verified. Coordinator and physical keyboard acceptance are separate."
            : "Internal transport FAIL: \(reason ?? "No confirmed replacement. Inspect diagnostic stages.")"
        show()
    }
}
