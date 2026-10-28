import AppKit

/// issue #27: показывает разовое объяснение «MacSwitcher на паузе из-за защищённого ввода»
/// НЕ крадя фокус. Раньше это был `NSAlert.runModal()` — модалка активировала приложение и
/// уводила фокус из поля пароля (пользователь терял позицию в терминале и вводил пароль заново).
/// Теперь это неактивирующая плашка (как `CaretIndicator`): `.nonactivatingPanel` +
/// `orderFrontRegardless`, без `NSApp.activate` и без `makeKey…` — фокус остаётся в поле ввода.
/// Сама гаснет через несколько секунд; доступна кнопка закрытия и необязательное действие.
@MainActor
final class SecureInputNotice {
    enum Kind: Hashable {
        case secureInput, manualFailure, unknownEdit, sourceFailure, undoRefusal, saveFailure
    }

    private let panel: NSPanel
    private let title: NSTextField
    private let body: NSTextField
    private let actionButton: NSButton
    private let closeButton: NSButton
    private var onAction: (() -> Void)?
    private var lastShownAt: [Kind: Date] = [:]
    private var presentationGeneration = 0
    private var hideTimer: Timer?
    private let width: CGFloat = 380

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 96),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true

        let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        backdrop.material = .hudWindow
        backdrop.state = .active
        backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop

        title = NSTextField(labelWithString: "")
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        body = NSTextField(wrappingLabelWithString: "")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints = false
        body.preferredMaxLayoutWidth = width - 32

        actionButton = NSButton(title: "", target: nil, action: nil)
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.isHidden = true

        let closeLabel = L10n.languageCode == "ru" ? "Закрыть уведомление" : "Close notification"
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: closeLabel)!,
                               target: nil, action: nil)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.controlSize = .small
        closeButton.setAccessibilityLabel(closeLabel)
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        closeButton.target = self
        closeButton.action = #selector(closePressed)

        let stack = NSStackView(views: [title, body, actionButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(closeButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -42),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -14),
            closeButton.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    /// Показать плашку (не крадёт фокус). Длительность зависит от объёма текста.
    @discardableResult
    func show(title titleText: String, body bodyText: String, kind: Kind? = nil,
              actionTitle: String? = nil, onAction: (() -> Void)? = nil,
              onWillPresent: (() -> Void)? = nil) -> Bool {
        if let kind, let last = lastShownAt[kind], Date().timeIntervalSince(last) < 30 { return false }
        if let kind { lastShownAt[kind] = Date() }
        onWillPresent?()
        presentationGeneration += 1
        title.stringValue = titleText
        body.stringValue = bodyText
        self.onAction = onAction
        actionButton.title = actionTitle ?? ""
        actionButton.isHidden = actionTitle == nil || onAction == nil
        panel.ignoresMouseEvents = false

        // Подгоняем высоту панели под содержимое и ставим рядом с указателем.
        panel.setContentSize(NSSize(width: width, height: 200))     // временно, чтобы layout развернулся
        panel.layoutIfNeeded()
        let fitH = panel.contentView?.fittingSize.height ?? 96
        let h = max(72, min(fitH, 220))
        panel.setContentSize(NSSize(width: width, height: h))
        if let origin = FeedbackPanelPlacement.origin(size: NSSize(width: width, height: h)) {
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()                                // показ БЕЗ активации приложения
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; panel.animator().alphaValue = 1 }

        let duration = min(9.0, 4.0 + Double(bodyText.count) / 45.0)  // дольше читать — дольше висит
        hideTimer?.invalidate()
        // .common — иначе таймер не сработает, пока main-runloop в eventTracking (открыто меню)
        // или modalPanel, и плашка зависла бы дольше срока (скептик #27).
        let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
        return true
    }

    func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        onAction = nil
        panel.ignoresMouseEvents = true
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
                                                 Task { @MainActor in
                                                     guard self?.presentationGeneration == generation else { return }
                                                     self?.panel.orderOut(nil)
                                                 }
                                             })
    }

    @objc private func actionPressed() {
        let action = onAction
        hide()
        action?()
    }

    @objc private func closePressed() { hide() }
}
