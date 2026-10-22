import Foundation

/// Compatibility entry point for native combined Shift. The retained facade
/// delegates manual installation to MacSwitcher's own signed Sparkle feed.
@MainActor
enum LocalUpdateBridge {
    static var isLocalEdition: Bool { true }
    static func recoverOnLaunch() { /* Sparkle owns update recovery. */ }
    static func check(silent: Bool) async {
        if silent { UpdateChecker.checkPeriodic() } else { UpdateChecker.checkNow() }
    }
}
