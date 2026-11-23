import AppKit

private final class CorrectionHintWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A small nonactivating plate next to the caret with the offered word.
/// It never takes focus, never reads or writes the field text: the only AX
/// read is the caret's screen bounds in the already verified field.
@MainActor
final class CorrectionHintPanel {
    let panel: NSPanel
    let label: NSTextField
    private let height: CGFloat = 24
    private let flagRaised: () -> Bool
    private let readCaret: (PendingCorrectionHint) -> NSRect?

    /// `flagRaised` and `readCaret` are the session flag and the caret AX
    /// read; tests replace them, the app uses the live ones.
    init(flagRaised: (() -> Bool)? = nil, readCaret: ((PendingCorrectionHint) -> NSRect?)? = nil) {
        self.flagRaised = flagRaised ?? { AutoSwitchPolicy.secureInputActive }
        self.readCaret = readCaret ?? { CorrectionHintPanel.caretRect($0) }
        panel = CorrectionHintWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: height),
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: true)
        label = NSTextField(labelWithString: "")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 120, height: height))
        content.material = .hudWindow
        content.state = .active
        content.blendingMode = .behindWindow
        content.wantsLayer = true
        content.layer?.cornerRadius = 7
        content.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        content.addSubview(label)
        panel.contentView = content
    }

    var isVisible: Bool { panel.isVisible }

    /// Lays out the plate for `word`; `caret` is in AppKit screen coordinates.
    func update(word: String, near caret: NSRect?) {
        label.stringValue = L10n.correctionHint(word: word)
        label.sizeToFit()
        let width = min(360, ceil(label.frame.width) + 20)
        panel.setContentSize(NSSize(width: width, height: height))
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        label.frame = NSRect(x: 10, y: (height - label.frame.height) / 2,
                             width: width - 20, height: label.frame.height)
        let anchor = caret ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 4)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) })
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = anchor.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
        }
        panel.setFrameOrigin(NSPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }

    /// Under the raised flag the plate obeys the auto-correction rule per field
    /// (`secureFlagPermits`): a password field, the flag holder's field or an
    /// unsure AX answer gets neither a caret read nor a plate. Returns whether shown.
    @discardableResult
    func show(_ hint: PendingCorrectionHint) -> Bool {
        guard hint.focus.secureFlagPermits(flagRaised: flagRaised()) else { hide(); return false }
        update(word: hint.word, near: readCaret(hint))
        panel.orderFrontRegardless()
        return true
    }

    func hide() { panel.orderOut(nil) }

    /// Screen bounds of the caret in the hint's own field, bounded to 50 ms.
    /// Called only after `show` admitted the field; never reads text.
    static func caretRect(_ hint: PendingCorrectionHint) -> NSRect? {
        guard hint.focus.fieldBoundary == nil else { return nil }
        let element = hint.focus.element
        AXUIElementSetMessagingTimeout(element, 0.05)
        var range = CFRange(location: max(0, hint.caretUTF16Location - 1), length: 1)
        guard let argument = AXValueCreate(.cfRange, &range) else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element,
                  kAXBoundsForRangeParameterizedAttribute as CFString, argument, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height >= 1,
              rect.width.isFinite, let primary = NSScreen.screens.first else { return nil }
        rect.origin.x = rect.maxX
        rect.size.width = 0
        rect.origin.y = primary.frame.height - rect.origin.y - rect.height
        return rect
    }
}
