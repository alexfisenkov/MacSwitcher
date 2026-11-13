import AppKit
import ApplicationServices

/// Prepares the active application's AX process before input needs a field anchor.
/// The standard application-role read is read-only; Electron separately documents
/// AXManualAccessibility for its original framework layout:
/// https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md
/// This never reads a field or changes MacSwitcher's input/editing gates.
@MainActor
final class ElectronAccessibilityBridge {
    struct Target: Equatable {
        let processID: Int32
        let bundleIdentifier: String?
        let bundleURL: URL?
        let launchDate: Date?
    }

    struct Platform {
        let notifications: NotificationCenter
        let frontmost: () -> Target?
        let trusted: () -> Bool
        let secureInputActive: () -> Bool
        let remoteDeferred: () -> Bool
        let electronFrameworkPresent: (URL) -> Bool
        let readApplicationRole: (Int32) -> Bool
        let enable: (Int32) -> Bool
        let now: () -> TimeInterval
        let ownProcessID: Int32

        static var live: Platform {
            Platform(
                notifications: NSWorkspace.shared.notificationCenter,
                frontmost: {
                    NSWorkspace.shared.frontmostApplication.map {
                        Target(processID: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                            bundleURL: $0.bundleURL, launchDate: $0.launchDate)
                    }
                },
                trusted: { AXIsProcessTrusted() },
                secureInputActive: { AutoSwitchPolicy.secureInputActive },
                remoteDeferred: { AutoSwitchPolicy.shouldDeferToRemoteClient },
                electronFrameworkPresent: { bundleURL in
                    FileManager.default.fileExists(atPath: bundleURL
                        .appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
                },
                readApplicationRole: { processID in
                    let app = AXUIElementCreateApplication(processID)
                    guard AXUIElementSetMessagingTimeout(app, 0.05) == .success else { return false }
                    var role: AnyObject?
                    guard AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString,
                        &role) == .success else { return false }
                    return role as? String == "AXApplication"
                },
                enable: { processID in
                    let app = AXUIElementCreateApplication(processID)
                    guard AXUIElementSetMessagingTimeout(app, 0.05) == .success else { return false }
                    return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString,
                        kCFBooleanTrue) == .success
                },
                now: { ProcessInfo.processInfo.systemUptime },
                ownProcessID: Int32(ProcessInfo.processInfo.processIdentifier))
        }
    }

    private let platform: Platform
    private var observer: NSObjectProtocol?
    private var lastSuccessfulActivation: Target?
    private var lastAttemptedActivation: Target?
    private var nextAttemptAt: TimeInterval = 0
    private static let minimumRetryInterval: TimeInterval = 2

    init(platform: Platform = .live) {
        self.platform = platform
    }

    /// This prepares manual double-Shift even when automatic conversion is off
    /// or an app is excluded from automatic editing.
    static func shouldRun(monitoringActive: Bool, autoSwitchEnabled: Bool) -> Bool {
        monitoringActive && autoSwitchEnabled
    }

    func start() {
        guard observer == nil else { return }
        observer = platform.notifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.prepareCurrent() }
            }
        prepareCurrent()
    }

    /// Called only from the existing main-thread status refresh, never the HID
    /// callback or an input fence. A transient AX/secure-input refusal may retry.
    func refresh() {
        prepareCurrent()
    }

    func stop() {
        if let observer { platform.notifications.removeObserver(observer) }
        observer = nil
        clearPreparation()
    }

    private func prepareCurrent() {
        guard observer != nil else { return }
        let current = platform.frontmost()
        guard let current, current.processID > 0,
              current.processID != platform.ownProcessID,
              current.bundleIdentifier != Bundle.main.bundleIdentifier else {
            clearPreparation()
            return
        }
        if current != lastSuccessfulActivation { lastSuccessfulActivation = nil }
        // Gates precede every AX and bundle probe. A temporary gate closure
        // revokes the receipt so the same app is prepared again when it clears.
        guard mayPrepare(current) else {
            clearPreparation()
            return
        }
        guard current != lastSuccessfulActivation else { return }
        if current != lastAttemptedActivation {
            lastAttemptedActivation = current
            nextAttemptAt = 0
        }
        let now = platform.now()
        guard now.isFinite, now >= nextAttemptAt else { return }
        nextAttemptAt = now + Self.minimumRetryInterval

        let rolePrepared = platform.readApplicationRole(current.processID)
        guard mayPrepare(current) else {
            clearPreparation()
            return
        }
        // Without a launch identity, PID/bundle/path equality cannot rule out
        // process reuse. The standard role read above is safe, but neither a
        // legacy setter nor a durable success receipt is justified.
        guard current.launchDate != nil else { return }
        // Preserve the documented manual setter only for the original Electron
        // layout. A role receipt is not proof that a text field is editable.
        let hasLegacyElectronFramework = current.bundleURL.map(platform.electronFrameworkPresent) ?? false
        guard mayPrepare(current) else {
            clearPreparation()
            return
        }
        let prepared = hasLegacyElectronFramework ? platform.enable(current.processID) : rolePrepared
        guard mayPrepare(current) else {
            clearPreparation()
            return
        }
        if prepared { lastSuccessfulActivation = current }
    }

    private func mayPrepare(_ target: Target) -> Bool {
        platform.trusted() && !platform.secureInputActive() && !platform.remoteDeferred()
            && platform.frontmost() == target
    }

    private func clearPreparation() {
        lastSuccessfulActivation = nil
        lastAttemptedActivation = nil
        nextAttemptAt = 0
    }
}
