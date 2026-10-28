import AppKit

/// A confirmed undo may stage one offer. Only an explicit accept writes the phrase.
@MainActor
final class CorrectionExceptionOfferPolicy {
    private let store: PersonalWordStore
    private var offered: Set<String> = []
    private(set) var pending: ConfirmedCorrectionNotice?

    init(store: PersonalWordStore = .shared) { self.store = store }

    func stage(_ notice: ConfirmedCorrectionNotice) -> Bool {
        guard !notice.original.isEmpty, notice.original != notice.replacement else { return false }
        let key = notice.sourceLanguage + "\0" + notice.original.lowercased().precomposedStringWithCanonicalMapping
        guard !offered.contains(key),
              !store.containsPhrase(original: notice.original, sourceLanguage: notice.sourceLanguage) else { return false }
        offered.insert(key)
        pending = notice
        return true
    }

    func dismiss() { pending = nil }

    @discardableResult
    func accept() throws -> Bool {
        guard let notice = pending else { return false }
        pending = nil
        try store.addPhrase(original: notice.original, replacement: notice.replacement,
                            sourceLanguage: notice.sourceLanguage)
        return true
    }
}

private final class CorrectionExceptionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Nonactivating offer after receipt-backed undo. It does not inspect the focused field.
@MainActor
final class CorrectionExceptionOffer: NSObject {
    private let policy: CorrectionExceptionOfferPolicy
    private let panel: NSPanel
    private let message: NSTextField
    private var timer: Timer?
    private var onSaved: (() -> Void)?
    private var onFailure: (() -> Void)?

    init(policy: CorrectionExceptionOfferPolicy = CorrectionExceptionOfferPolicy()) {
        self.policy = policy
        panel = CorrectionExceptionPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 92),
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
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 390, height: 92))
        backdrop.material = .hudWindow
        backdrop.state = .active
        backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 11
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop

        message.frame = NSRect(x: 14, y: 43, width: 362, height: 38)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .labelColor
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byTruncatingMiddle
        backdrop.addSubview(message)

        let add = NSButton(title: L10n.learnAdd, target: self, action: #selector(addPressed))
        add.bezelStyle = .rounded
        add.controlSize = .small
        add.frame = NSRect(x: 14, y: 10, width: 198, height: 27)
        backdrop.addSubview(add)
        let dismiss = NSButton(title: L10n.learnNotNow, target: self, action: #selector(dismissPressed))
        dismiss.bezelStyle = .rounded
        dismiss.controlSize = .small
        dismiss.frame = NSRect(x: 220, y: 10, width: 120, height: 27)
        backdrop.addSubview(dismiss)
    }

    @discardableResult
    func show(_ notice: ConfirmedCorrectionNotice, onSaved: @escaping () -> Void,
              onFailure: @escaping () -> Void) -> Bool {
        guard policy.stage(notice) else { return false }
        timer?.invalidate()
        self.onSaved = onSaved
        self.onFailure = onFailure
        message.stringValue = L10n.learnQuestion(notice.original)
        if let origin = FeedbackPanelPlacement.origin(size: panel.frame.size) {
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        let t = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        return true
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        policy.dismiss()
        onSaved = nil
        onFailure = nil
        panel.orderOut(nil)
    }

    @objc private func addPressed() {
        let success = onSaved
        let failure = onFailure
        do {
            let saved = try policy.accept()
            hide()
            if saved { success?() }
        } catch {
            hide()
            failure?()
        }
    }

    @objc private func dismissPressed() { hide() }
}
