import XCTest
@testable import RuSwitcher

final class AutomaticEditorPolicyTests: XCTestCase {
    @MainActor
    func testCodexNeverUsesNumericAXRangeEvenWithoutUserExclusion() {
        for suffix in ["g", "ghbd", "hello ghbd", "private text"] {
            XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: suffix,
                sourceID: "com.apple.keylayout.US", arguments: [], claimed: false, nativeEnabled: false), .blocked)
        }
    }
    @MainActor
    func testCanaryAcceptsOnlyUnclaimedExactSyntheticPrefixAndSource() {
        let args = ["MacSwitcher", "--diagnostic-native-canary", "--diagnostic-panel"]
        for prefix in ["g", "gh", "ghb", "ghbd"] {
            XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: prefix,
                sourceID: "com.apple.keylayout.US", arguments: args, claimed: false, armed: true, nativeEnabled: false), .nativeCanary)
        }
        for suffix in ["", "ghbd ", "ghbdtn", "other ghbd", "GHBD"] {
            XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: suffix,
                sourceID: "com.apple.keylayout.US", arguments: args, claimed: false, armed: true, nativeEnabled: false), .blocked)
        }
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: "ghbd",
            sourceID: "com.apple.keylayout.Russian", arguments: args, claimed: false, armed: true, nativeEnabled: false), .blocked)
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: "ghbd",
            sourceID: "com.apple.keylayout.US", arguments: args, claimed: true, armed: true, nativeEnabled: false), .blocked)
    }
    @MainActor
    func testFlagsAloneCannotArmOrBypassCodexExclusion() {
        let args = ["MacSwitcher", "--diagnostic-native-canary", "--diagnostic-panel"]
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: "ghbd",
            sourceID: "com.apple.keylayout.US", arguments: args, claimed: false, armed: false, nativeEnabled: false), .blocked)
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: "ghbd",
            sourceID: "com.apple.keylayout.US", arguments: ["--diagnostic-native-canary"], claimed: false, armed: true, nativeEnabled: false), .blocked)
    }
    @MainActor
    func testNativeTextEditPathDoesNotRequireCodexCanary() {
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.apple.TextEdit", suffix: "ghbdtn",
            sourceID: "com.apple.keylayout.US", arguments: [], claimed: false, nativeEnabled: false), .axRange)
    }
    @MainActor
    func testOrdinaryNativeRolloutNeverUsesAXRangeForAnyEditor() {
        for app in ["com.openai.codex", "com.apple.TextEdit", "com.google.Chrome"] {
            XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: app, suffix: "word", sourceID: "us",
                arguments: [], nativeEnabled: true), .nativeVerified)
        }
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: "ghbd", sourceID: "us",
            arguments: ["--diagnostic-only-auto"], nativeEnabled: true), .blocked)
    }
    @MainActor
    func testOwnedFixtureCanExerciseNativeBeforeOrdinaryRollout() {
        let flags = ["--diagnostic-panel", "--diagnostic-native-canary"]
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: AutomaticEditorPolicy.inputFixtureBundleID,
            suffix: "arbitrary synthetic prefix", sourceID: "us", arguments: flags, nativeEnabled: false), .nativeVerified)
        for arguments in [[], ["--diagnostic-panel"], ["--diagnostic-native-canary"]] {
            XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: AutomaticEditorPolicy.inputFixtureBundleID,
                suffix: "ghbd", sourceID: "us", arguments: arguments, nativeEnabled: false), .axRange)
        }
    }
}
