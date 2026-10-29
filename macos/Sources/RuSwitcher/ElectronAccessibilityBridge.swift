import AppKit
import ApplicationServices

/// Initializes an active Electron app's AX tree before input needs a field anchor.
/// Electron documents AXManualAccessibility for third-party macOS software:
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
        let enable: (Int32) -> Bool
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
                enable: { processID in
                    let app = AXUIElementCreateApplication(processID)
                    guard AXUIElementSetMessagingTimeout(app, 0.05) == .success else { return false }
                    return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString,
                        kCFBooleanTrue) == .success
                },
                ownProcessID: Int32(ProcessInfo.processInfo.processIdentifier))
        }
    }

    private let platform: Platform
    private var observer: NSObjectProtocol?
    private var lastSuccessfulActivation: Target?

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
        lastSuccessfulActivation = nil
    }

    private func prepareCurrent() {
        guard observer != nil else { return }
        let current = platform.frontmost()
        guard current != lastSuccessfulActivation else { return }
        lastSuccessfulActivation = nil
        guard let current, current.processID > 0,
              current.processID != platform.ownProcessID,
              current.bundleIdentifier != Bundle.main.bundleIdentifier,
              let bundleURL = current.bundleURL,
              platform.electronFrameworkPresent(bundleURL),
              platform.trusted(), !platform.secureInputActive(), !platform.remoteDeferred(),
              platform.frontmost()?.processID == current.processID else { return }
        if platform.enable(current.processID) { lastSuccessfulActivation = current }
    }
}
