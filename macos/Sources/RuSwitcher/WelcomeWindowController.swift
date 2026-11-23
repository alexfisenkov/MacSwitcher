import AppKit

enum WelcomePermission: Equatable { case accessibility, inputMonitoring }

/// What the first launch shows. New installs get one explaining screen; existing installs
/// keep the previous system-request wizard and alerts unchanged.
enum FirstRunPlan: Equatable {
    case start, welcome, permissionsReset, legacyWizard

    static func decide(freshProfile: Bool, welcomeCompleted: Bool, accessibility: Bool,
                       inputMonitoring: Bool, permissionsWereGranted: Bool) -> FirstRunPlan {
        let granted = accessibility && inputMonitoring
        if freshProfile { return granted && welcomeCompleted ? .start : .welcome }
        if granted { return .start }
        return permissionsWereGranted ? .permissionsReset : .legacyWizard
    }

    /// The launch-at-login and auto-correction alerts exist only for existing installs.
    static func offersLegacyPrompts(freshProfile: Bool) -> Bool { !freshProfile }
}

/// One welcome screen: why two permissions, a button to each System Settings pane, and the
/// two everyday switches. It never grants anything itself; AppDelegate's existing poll
/// reports the system state back through `update`.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    var onOpenSettings: ((WelcomePermission) -> Void)?
    var onAutomaticCorrectionChanged: ((Bool) -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onFinish: (() -> Void)?

    private var window: NSWindow?
    private var statusLabels: [WelcomePermission: NSTextField] = [:]
    private var openButtons: [WelcomePermission: NSButton] = [:]
    private var finished = false
    private static let width: CGFloat = 560
    private static let inset: CGFloat = 24

    var isVisible: Bool { window?.isVisible == true }

    func show(accessibility: Bool, inputMonitoring: Bool,
              automaticCorrection: Bool, launchAtLogin: Bool) {
        finished = false
        let content = makeContent(accessibility: accessibility, inputMonitoring: inputMonitoring,
            automaticCorrection: automaticCorrection, launchAtLogin: launchAtLogin)
        let win = window ?? NSWindow(contentRect: content.frame, styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = L10n.welcomeWindowTitle
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = content
        win.setContentSize(content.frame.size)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func close() {
        finished = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { finish() }

    func makeContent(accessibility: Bool, inputMonitoring: Bool,
                     automaticCorrection: Bool, launchAtLogin: Bool) -> NSView {
        statusLabels.removeAll()
        openButtons.removeAll()
        let column = Self.width - 2 * Self.inset
        var blocks: [(view: NSView, gap: CGFloat)] = []
        let title = NSTextField(labelWithString: L10n.welcomeTitle)
        title.font = .boldSystemFont(ofSize: 20)
        title.frame.size = NSSize(width: column, height: 28)
        blocks.append((title, 8))
        let lead = Self.wrapping(L10n.welcomeLead, size: 13, width: column, secondary: true)
        blocks.append((lead, 16))
        blocks.append((permissionBox(.accessibility, title: L10n.welcomeAccessibilityTitle,
            text: L10n.welcomeAccessibilityText, width: column), 10))
        blocks.append((permissionBox(.inputMonitoring, title: L10n.welcomeInputMonitoringTitle,
            text: L10n.welcomeInputMonitoringText, width: column), 16))
        blocks.append((switchBox(width: column, rows: [
            (L10n.menuAutoConvert, L10n.welcomeAutoCorrectionHint, automaticCorrection,
             #selector(automaticChanged(_:))),
            (L10n.welcomeLaunchAtLogin, L10n.welcomeLaunchAtLoginHint, launchAtLogin,
             #selector(launchAtLoginChanged(_:)))
        ]), 18))
        let done = NSButton(title: L10n.welcomeDone, target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame.size = NSSize(width: max(120, ceil(done.cell?.cellSize.width ?? 0) + 24), height: 32)
        blocks.append((done, 0))

        let height = Self.inset * 2 + blocks.reduce(0) { $0 + $1.view.frame.height + $1.gap }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        var top = height - Self.inset
        for (view, gap) in blocks {
            let x = view === done ? Self.width - Self.inset - view.frame.width : Self.inset
            view.frame.origin = NSPoint(x: x, y: top - view.frame.height)
            root.addSubview(view)
            top -= view.frame.height + gap
        }
        update(accessibility: accessibility, inputMonitoring: inputMonitoring)
        return root
    }

    func update(accessibility: Bool, inputMonitoring: Bool) {
        for (permission, granted) in [(WelcomePermission.accessibility, accessibility),
                                      (.inputMonitoring, inputMonitoring)] {
            statusLabels[permission]?.stringValue = granted ? L10n.welcomeGranted : L10n.welcomeMissing
            statusLabels[permission]?.textColor = granted ? .systemGreen : .secondaryLabelColor
            openButtons[permission]?.isEnabled = !granted
        }
    }

    private func permissionBox(_ permission: WelcomePermission, title: String, text: String,
                               width: CGFloat) -> NSBox {
        let pad: CGFloat = 16
        // The right column fits the longest status or button text of the current language.
        let longest = [L10n.welcomeGranted, L10n.welcomeMissing].map { text -> CGFloat in
            let probe = NSTextField(labelWithString: text)
            probe.font = .systemFont(ofSize: 12, weight: .medium)
            return ceil(probe.cell?.cellSize.width ?? 0) + 4 }.max() ?? 0
        let openProbe = NSButton(title: L10n.welcomeOpenSettings, target: nil, action: nil)
        openProbe.bezelStyle = .rounded
        let openWidth = ceil(openProbe.cell?.cellSize.width ?? 0) + 4
        let buttonWidth = max(170, longest, openWidth)
        let textWidth = width - 2 * pad - buttonWidth - 12
        let detail = Self.wrapping(text, size: 12, width: textWidth, secondary: true)
        let height = max(84, pad + 20 + 4 + detail.frame.height + pad)
        let box = Self.group(NSRect(x: 0, y: 0, width: width, height: height))
        let name = NSTextField(labelWithString: title)
        name.font = .boldSystemFont(ofSize: 14)
        name.frame = NSRect(x: pad, y: height - pad - 20, width: textWidth, height: 20)
        box.contentView?.addSubview(name)
        detail.frame.origin = NSPoint(x: pad, y: name.frame.minY - 4 - detail.frame.height)
        box.contentView?.addSubview(detail)
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.alignment = .center
        status.frame = NSRect(x: width - pad - buttonWidth, y: height / 2 + 4,
            width: buttonWidth, height: 18)
        box.contentView?.addSubview(status)
        statusLabels[permission] = status
        let open = NSButton(title: L10n.welcomeOpenSettings, target: self,
            action: #selector(openClicked(_:)))
        open.bezelStyle = .rounded
        open.tag = permission == .accessibility ? 0 : 1
        open.frame = NSRect(x: width - pad - buttonWidth, y: height / 2 - 30,
            width: buttonWidth, height: 30)
        box.contentView?.addSubview(open)
        openButtons[permission] = open
        return box
    }

    private func switchBox(width: CGFloat,
                           rows: [(String, String, Bool, Selector)]) -> NSBox {
        let pad: CGFloat = 16, switchWidth: CGFloat = 48
        let textWidth = width - 2 * pad - switchWidth - 12
        let built = rows.map { row -> (NSTextField, NSTextField, NSSwitch) in
            let name = NSTextField(labelWithString: row.0)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.frame.size = NSSize(width: textWidth, height: 18)
            let hint = Self.wrapping(row.1, size: 11, width: textWidth, secondary: true)
            let toggle = NSSwitch()
            toggle.state = row.2 ? .on : .off
            toggle.target = self
            toggle.action = row.3
            toggle.frame.size = NSSize(width: switchWidth, height: 28)
            return (name, hint, toggle)
        }
        let rowHeights = built.map { 18 + 2 + $0.1.frame.height }
        let height = pad * 2 + rowHeights.reduce(0, +) + 14 * CGFloat(max(0, rows.count - 1))
        let box = Self.group(NSRect(x: 0, y: 0, width: width, height: height))
        var top = height - pad
        for ((name, hint, toggle), rowHeight) in zip(built, rowHeights) {
            name.frame.origin = NSPoint(x: pad, y: top - 18)
            hint.frame.origin = NSPoint(x: pad, y: name.frame.minY - 2 - hint.frame.height)
            toggle.frame.origin = NSPoint(x: width - pad - switchWidth,
                y: top - rowHeight / 2 - toggle.frame.height / 2)
            [name, hint, toggle].forEach { box.contentView?.addSubview($0) }
            top -= rowHeight + 14
        }
        return box
    }

    @objc private func openClicked(_ sender: NSButton) {
        onOpenSettings?(sender.tag == 0 ? .accessibility : .inputMonitoring)
    }

    @objc private func automaticChanged(_ sender: NSSwitch) {
        onAutomaticCorrectionChanged?(sender.state == .on)
    }

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        onLaunchAtLoginChanged?(sender.state == .on)
    }

    @objc private func doneClicked() {
        finish()
        window?.close()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish?()
    }

    private static func wrapping(_ text: String, size: CGFloat, width: CGFloat,
                                 secondary: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        if secondary { label.textColor = .secondaryLabelColor }
        let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
            height: 10_000)).height ?? 16)
        label.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return label
    }

    private static func group(_ frame: NSRect) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 9
        box.contentViewMargins = .zero
        return box
    }
}
