import AppKit
import ApplicationServices

/// Codex never uses numeric AX selection. Ordinary native editing is a separate
/// rollout; the fixed owned fixture can exercise it before that rollout.
enum AutomaticEditorRoute: Equatable { case axRange, blocked, nativeCanary, nativeVerified }

@MainActor
enum AutomaticEditorPolicy {
    static let codexBundleID = "com.openai.codex"
    static let inputFixtureBundleID = "com.alexfisenkov.macswitcher.inputfixture"
    private static var canaryClaimed = false
    private static var armedUntil: TimeInterval?

    static func armCanary() -> Bool {
        guard CommandLine.arguments.contains("--diagnostic-panel"),
              CommandLine.arguments.contains("--diagnostic-native-canary"), !canaryClaimed else { return false }
        armedUntil = ProcessInfo.processInfo.systemUptime + 30
        return true
    }

    static func route(bundleID: String?, suffix: String, sourceID: String,
                      arguments: [String] = CommandLine.arguments,
                      claimed: Bool? = nil, armed: Bool? = nil,
                      nativeEnabled: Bool? = nil) -> AutomaticEditorRoute {
        if bundleID == inputFixtureBundleID,
           arguments.contains("--diagnostic-panel"),
           arguments.contains("--diagnostic-native-canary") { return .nativeVerified }
        if (nativeEnabled ?? SettingsManager.shared.nativeAutoEnabled),
           !arguments.contains("--diagnostic-only-auto") { return .nativeVerified }
        guard bundleID == codexBundleID else { return .axRange }
        guard arguments.contains("--diagnostic-native-canary"), arguments.contains("--diagnostic-panel"),
              armed ?? (armedUntil.map { ProcessInfo.processInfo.systemUptime < $0 } ?? false),
              !(claimed ?? canaryClaimed),
              sourceID == "com.apple.keylayout.US", !suffix.isEmpty, "ghbd".hasPrefix(suffix) else { return .blocked }
        return .nativeCanary
    }

    static func claimCanary() -> Bool {
        guard !canaryClaimed, armedUntil.map({ ProcessInfo.processInfo.systemUptime < $0 }) == true else { return false }
        canaryClaimed = true
        armedUntil = nil
        return true
    }

    static func fieldMatchesFixture(_ focus: CombinedShiftFocus) -> Bool {
        guard let range = focus.selectionRange(), range.location == 4, range.length == 0 else { return false }
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(focus.element, kAXValueAttribute as CFString, &raw) == .success else { return false }
        return raw as? String == "ghbd"
    }
}
