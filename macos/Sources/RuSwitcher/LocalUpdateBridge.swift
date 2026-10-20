import Foundation

/// Compatibility marker for native combined Shift. Public MacSwitcher never calls
/// the old personal Git/source updater or an upstream vendor installer.
@MainActor
enum LocalUpdateBridge {
    static var isLocalEdition: Bool { true }
    static func recoverOnLaunch() { /* No install transaction in the first alpha. */ }
    static func check(silent: Bool) async {
        if silent { UpdateChecker.checkPeriodic() } else { UpdateChecker.checkNow() }
    }
}
