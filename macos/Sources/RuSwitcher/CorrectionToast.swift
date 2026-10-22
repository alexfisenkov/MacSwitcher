import AppKit

private final class CorrectionToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Local feedback for one confirmed correction. The owner closures retain the immutable receipt ID.
/// This view never reads or writes the focused field.
@MainActor
final class CorrectionToast: NSObject {
    private let panel: NSPanel
    private let message: NSTextField
    private var onUndo: (() -> Void)?
    private var onNever: (() -> Void)?
    private var timer: Timer?

    override init() {
        panel = CorrectionToastPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 90),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        message = NSTextField(wrappingLabelWithString: "")
        super.init()
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 90))
        message.frame = NSRect(x: 14, y: 42, width: 412, height: 38)
        message.lineBreakMode = .byTruncatingMiddle
        message.maximumNumberOfLines = 2
        content.addSubview(message)

        let undo = NSButton(title: label("Отменить", "Undo"), target: self, action: #selector(undoPressed))
        undo.frame = NSRect(x: 14, y: 10, width: 110, height: 27)
        content.addSubview(undo)
        let never = NSButton(title: label("Больше не исправлять фразу", "Never correct this phrase"),
                             target: self, action: #selector(neverPressed))
        never.frame = NSRect(x: 132, y: 10, width: 290, height: 27)
        content.addSubview(never)
        panel.contentView = content
    }

    func show(original: String, replacement: String, onUndo: @escaping () -> Void,
              onNever: @escaping () -> Void) {
        timer?.invalidate()
        self.onUndo = onUndo
        self.onNever = onNever
        message.stringValue = "\(original) → \(replacement)"
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 18,
                                         y: screen.visibleFrame.maxY - panel.frame.height - 18))
        }
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        onUndo = nil
        onNever = nil
        panel.orderOut(nil)
    }

    @objc private func undoPressed() {
        let action = onUndo
        hide()
        action?()
    }

    @objc private func neverPressed() {
        let action = onNever
        hide()
        action?()
    }

    private func label(_ ru: String, _ en: String) -> String { L10n.languageCode == "ru" ? ru : en }
}
