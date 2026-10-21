import XCTest
@testable import RuSwitcher

final class AutomaticEditorPolicyTests: XCTestCase {
    @MainActor
    func testCodexNeverUsesNumericAXRangeEvenWithoutUserExclusion() {
        for suffix in ["g", "ghbd", "hello ghbd", "private text"] {
            XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: suffix,
                sourceID: "com.apple.keylayout.US", arguments: [], claimed: false), .blocked)
        }
    }
    @MainActor
    func testCanaryAcceptsOnlyUnclaimedExactSyntheticPrefixAndSource() {
        let args = ["MacSwitcher", "--diagnostic-native-canary", "--diagnostic-panel"]
        for prefix in ["g", "gh", "ghb", "ghbd"] {
            XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: prefix,
                sourceID: "com.apple.keylayout.US", arguments: args, claimed: false, armed: true), .nativeCanary)
        }
        for suffix in ["", "ghbd ", "ghbdtn", "other ghbd", "GHBD"] {
            XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: suffix,
                sourceID: "com.apple.keylayout.US", arguments: args, claimed: false, armed: true), .blocked)
        }
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: "ghbd",
            sourceID: "com.apple.keylayout.Russian", arguments: args, claimed: false, armed: true), .blocked)
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: "ghbd",
            sourceID: "com.apple.keylayout.US", arguments: args, claimed: true, armed: true), .blocked)
    }
    @MainActor
    func testFlagsAloneCannotArmOrBypassCodexExclusion() {
        let args = ["MacSwitcher", "--diagnostic-native-canary", "--diagnostic-panel"]
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: "ghbd",
            sourceID: "com.apple.keylayout.US", arguments: args, claimed: false, armed: false), .blocked)
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.openai.codex", suffix: "ghbd",
            sourceID: "com.apple.keylayout.US", arguments: ["--diagnostic-native-canary"], claimed: false, armed: true), .blocked)
    }
    @MainActor
    func testNativeTextEditPathDoesNotRequireCodexCanary() {
        XCTAssertEqual(AutomaticEditorPolicy.route(bundleID: "com.apple.TextEdit", suffix: "ghbdtn",
            sourceID: "com.apple.keylayout.US", arguments: [], claimed: false), .axRange)
    }
}
