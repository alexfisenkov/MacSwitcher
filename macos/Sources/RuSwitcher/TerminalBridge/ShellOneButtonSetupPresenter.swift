import AppKit

/// The windows and system calls behind the one-button zsh setup. Logic lives in
/// `ShellOneButtonSetup`; this file only gathers real state and shows the dialogs.
@MainActor
enum ShellOneButtonSetupPresenter {
    /// `manage` opens the old install/remove dialog when there is nothing left to set up.
    static func present(enableBridge: @escaping () -> Void, manage: @escaping () -> Void) {
        guard let resource = ShellBridgeProfilePatch.packagedResourceURL else {
            show(L10n.shellSetupFailed); return
        }
        let profile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        let existing = FileManager.default.fileExists(atPath: profile.path) ? try? Data(contentsOf: profile) : nil
        guard let preview = try? ShellBridgeProfilePatch.preview(profileData: existing, resourcePath: resource.path) else {
            show(L10n.shellSetupFailed); return
        }
        let installed = preview.action == .alreadyInstalled
        let discovery = SelectedTTYCapabilityDiscovery()
        let hosts = NSWorkspace.shared.runningApplications.filter {
            discovery.capability(pid: $0.processIdentifier) != nil
        }
        let host = hosts.count == 1 ? hosts.first : nil
        Task { @MainActor in
            var granted = false
            if let pid = host?.processIdentifier {
                granted = await Task.detached(priority: .userInitiated) {
                    NativeReadOnlyAppleEventExecutor().preflight(pid: pid) == noErr
                }.value
            }
            if installed && granted { manage(); return }
            let setup = ShellOneButtonSetup(
                lineInstalled: { installed },
                confirm: { confirm(sourceLine: preview.sourceLine) },
                installLine: { _ = try ShellBridgeProfilePatch.apply(profile: profile, resourcePath: resource.path) },
                enableBridge: enableBridge,
                terminalAvailable: { host != nil },
                accessGranted: { granted },
                requestAccess: {
                    guard let pid = host?.processIdentifier else { return false }
                    return await Task.detached(priority: .userInitiated) {
                        NativeReadOnlyAppleEventExecutor.requestConsent(pid: pid) == noErr
                    }.value
                })
            let outcome = await setup.run()
            let message = L10n.shellSetupResult(outcome)
            if !message.isEmpty { show(message) }
        }
    }

    private static func confirm(sourceLine: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.shellSetupTitle
        alert.informativeText = L10n.shellSetupExplanation(sourceLine: sourceLine)
        alert.addButton(withTitle: L10n.shellSetupConnect)
        alert.addButton(withTitle: L10n.shellSetupCancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func show(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "MacSwitcher"
        alert.informativeText = text
        alert.runModal()
    }
}
