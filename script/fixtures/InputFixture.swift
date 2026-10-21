import AppKit
import Carbon

// Public synthetic-event marker from KeyboardMonitor.swift; physical input has no such marker.
private let macSwitcherEventMarker: Int64 = 0x52555300

@MainActor
@objc(MacSwitcherInputFixtureApplication)
final class InputFixtureApplication: NSApplication {
    // NSTextView initialization may request NSApplication.shared. Delay it
    // until our NSApplication subclass has finished its own initialization.
    private lazy var fixtureDelegate = InputFixtureDelegate()
    private var delayed: [(event: NSEvent, readyAt: DispatchTime)] = []
    private var deliveryScheduled = false
    private var markedCount = 0
    var delayMilliseconds = 0
    var markedCountDidChange: ((Int) -> Void)?

    override func finishLaunching() {
        delegate = fixtureDelegate
        super.finishLaunching()
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) == macSwitcherEventMarker else {
            super.sendEvent(event)
            return
        }
        markedCount += 1
        markedCountDidChange?(markedCount)
        if delayMilliseconds == 0, delayed.isEmpty, !deliveryScheduled {
            super.sendEvent(event)
            return
        }
        // Only marked synthetic events enter this fixture-only FIFO. Normal input
        // always takes the immediate branch above, including during delayed writes.
        delayed.append((event, .now() + .milliseconds(delayMilliseconds)))
        scheduleNextMarkedEvent()
    }

    private func scheduleNextMarkedEvent() {
        guard !deliveryScheduled, let next = delayed.first else { return }
        deliveryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: next.readyAt) { [weak self] in
            self?.deliverNextMarkedEvent()
        }
    }

    private func deliverNextMarkedEvent() {
        guard !delayed.isEmpty else { deliveryScheduled = false; return }
        let next = delayed.removeFirst()
        super.sendEvent(next.event)
        deliveryScheduled = false
        scheduleNextMarkedEvent()
    }
}

@MainActor
final class FixtureTextView: NSTextView {
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
}

@MainActor
final class InputFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let fieldA = FixtureTextView()
    private let fieldB = FixtureTextView()
    private let secureField = NSSecureTextField()
    private let markedLabel = NSTextField(labelWithString: "Marked events: 0")
    private let sourceLabel = NSTextField(labelWithString: "Prepare selects enabled US only")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MacSwitcher Input Fixture"
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        self.window = window
        guard let content = window.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let instructions = NSTextField(labelWithString:
            "Synthetic data only. Prepare resets A/B. Tab moves A → B → Secure; physical input is never delayed.")
        root.addArrangedSubview(instructions)
        let buttonTitles = ["Prepare Empty", "Prepare Prefix", "Prepare Selection",
                            "Prepare Neighbors", "Prepare Selected Neighbors", "Prepare Long Selection"]
        for tags in [0..<3, 3..<6] {
            let row = NSStackView()
            row.spacing = 8
            row.distribution = .fillEqually
            for tag in tags {
                let button = NSButton(title: buttonTitles[tag], target: self, action: #selector(prepare(_:)))
                button.tag = tag
                button.setAccessibilityIdentifier("prepare-\(tag)")
                row.addArrangedSubview(button)
            }
            root.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }

        let readOnly = NSButton(checkboxWithTitle: "Read-only A", target: self, action: #selector(readOnlyChanged(_:)))
        readOnly.setAccessibilityIdentifier("read-only-a")
        let delay = NSPopUpButton()
        delay.addItems(withTitles: ["0 ms", "5 ms", "20 ms"])
        delay.target = self
        delay.action = #selector(delayChanged(_:))
        delay.setAccessibilityLabel("Delay marked events")
        delay.setAccessibilityIdentifier("marked-event-delay")
        let options = NSStackView(views: [readOnly, NSTextField(labelWithString: "Delay marked events:"), delay,
                                         markedLabel, sourceLabel])
        options.spacing = 12
        root.addArrangedSubview(options)
        markedLabel.setAccessibilityIdentifier("marked-event-count")
        sourceLabel.font = .systemFont(ofSize: 11)

        let inputs = NSStackView(views: [panel("Fixture A", field: fieldA, identifier: "fixture-a"),
                                        panel("Fixture B", field: fieldB, identifier: "fixture-b")])
        inputs.spacing = 16
        inputs.distribution = .fillEqually
        inputs.alignment = .top
        root.addArrangedSubview(inputs)
        inputs.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        for panel in inputs.arrangedSubviews {
            panel.heightAnchor.constraint(equalTo: inputs.heightAnchor).isActive = true
        }

        secureField.stringValue = "fake-password"
        secureField.placeholderString = "FAKE PASSWORD ONLY"
        secureField.setAccessibilityLabel("Fixture Secure")
        secureField.setAccessibilityIdentifier("fixture-secure")
        let secureRow = NSStackView(views: [NSTextField(labelWithString: "Synthetic secure field:"), secureField])
        secureRow.spacing = 12
        root.addArrangedSubview(secureRow)
        secureRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        secureField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        fieldA.nextKeyView = fieldB
        fieldB.nextKeyView = secureField
        secureField.nextKeyView = fieldA
        fieldB.string = "SECOND_FIELD_SENTINEL"
        (NSApp as? InputFixtureApplication)?.markedCountDidChange = { [weak self] count in
            self?.markedLabel.stringValue = "Marked events: \(count)"
        }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Input Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(fieldA)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func panel(_ title: String, field: NSTextView, identifier: String) -> NSStackView {
        field.frame = NSRect(x: 0, y: 0, width: 440, height: 260)
        field.isRichText = false
        field.importsGraphics = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticSpellingCorrectionEnabled = false
        field.isContinuousSpellCheckingEnabled = false
        field.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        field.textContainerInset = NSSize(width: 10, height: 10)
        field.isHorizontallyResizable = false
        field.isVerticallyResizable = true
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.setAccessibilityLabel(title)
        field.setAccessibilityIdentifier(identifier)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = field
        let panel = NSStackView(views: [NSTextField(labelWithString: title), scroll])
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 6
        scroll.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        return panel
    }

    @objc private func prepare(_ sender: NSButton) {
        let text: String
        let selection: NSRange
        switch sender.tag {
        case 0: (text, selection) = ("", NSRange(location: 0, length: 0))
        case 1: (text, selection) = ("ghbd", NSRange(location: 4, length: 0))
        case 2: (text, selection) = ("ghbdtn", NSRange(location: 0, length: 6))
        case 3: (text, selection) = ("START 😀 ghbd END", NSRange(location: 13, length: 0))
        case 4: (text, selection) = ("START 😀 ghbdtn END", NSRange(location: 9, length: 6))
        case 5:
            text = String(repeating: "ghbdtn ", count: 100)
            selection = NSRange(location: 0, length: text.utf16.count)
        default: return
        }
        fieldA.string = text
        fieldB.string = "SECOND_FIELD_SENTINEL"
        secureField.stringValue = "fake-password"
        fieldA.setSelectedRange(selection)
        fieldA.scrollRangeToVisible(selection)
        sourceLabel.stringValue = selectEnabledUS() ? "US selection requested" : "Enabled US source unavailable"
        window?.makeFirstResponder(fieldA)
    }

    private func selectEnabledUS() -> Bool {
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US",
                      kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let us = sources.first else { return false }
        return TISSelectInputSource(us) == noErr
    }

    @objc private func readOnlyChanged(_ sender: NSButton) { fieldA.isEditable = sender.state != .on }

    @objc private func delayChanged(_ sender: NSPopUpButton) {
        (NSApp as? InputFixtureApplication)?.delayMilliseconds = [0, 5, 20][sender.indexOfSelectedItem]
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
