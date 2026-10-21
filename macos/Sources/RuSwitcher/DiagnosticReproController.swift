import AppKit
import ApplicationServices

/// Opt-in developer integration fixture, confined to exact synthetic TextEdit
/// input. It never writes AXValue or supplies the expected Russian result.
@MainActor
final class DiagnosticReproController: NSObject {
    private let monitor: KeyboardMonitor
    private let converter: TextConverter
    private let window: NSWindow
    private let status = NSTextField(labelWithString:
        "Use a separate TextEdit document. Selection: select ghbdtn. Auto: put ghbd in an otherwise empty document, caret at end.")
    private var running = false
    private var runningAuto = false
    private var automaticApplications = 0

    init(monitor: KeyboardMonitor, converter: TextConverter) {
        self.monitor = monitor
        self.converter = converter
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 210),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "MacSwitcher — Internal Integration Test"
        window.isReleasedWhenClosed = false
        let selection = NSButton(title: "Test selected ghbdtn", target: self, action: #selector(testSelection))
        selection.frame = NSRect(x: 20, y: 155, width: 275, height: 32)
        let auto = NSButton(title: "Test early correction of ghbd", target: self, action: #selector(testAuto))
        auto.frame = NSRect(x: 305, y: 155, width: 295, height: 32)
        status.frame = NSRect(x: 20, y: 25, width: 580, height: 110)
        status.maximumNumberOfLines = 5
        window.contentView?.addSubview(selection)
        window.contentView?.addSubview(auto)
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
            let success = await self.converter.convertSelection(context: context, execution: execution)
            if success {
                self.monitor.markConverted()
                if let result = self.converter.lastResultLayoutID { LayoutSwitcher.switchTo(layoutID: result) }
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
}
