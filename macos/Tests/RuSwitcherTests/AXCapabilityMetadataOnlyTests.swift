import ApplicationServices
import XCTest
@testable import RuSwitcher

final class AXCapabilityMetadataOnlyTests: XCTestCase {
    @MainActor
    private final class FakeReader: AXCapabilityDiagnostics.MetadataReader {
        var names: [String] = []
        var parameterized: [String] = []
        var scalars: [AXCapabilityDiagnostics.MetadataScalar: (AXError, AnyObject?)] = [:]
        var scalarReads: [AXCapabilityDiagnostics.MetadataScalar] = []
        var settableChecks: [String] = []

        func attributeNames() -> (AXError, [String]) { (.success, names) }
        func parameterizedAttributeNames() -> (AXError, [String]) { (.success, parameterized) }
        func scalar(_ name: AXCapabilityDiagnostics.MetadataScalar) -> (AXError, AnyObject?) {
            scalarReads.append(name)
            return scalars[name] ?? (.attributeUnsupported, nil)
        }
        func isSettable(_ name: String) -> (AXError, Bool) {
            settableChecks.append(name)
            return (.success, name == kAXValueAttribute)
        }
    }

    @MainActor
    func testMetadataUsesOnlyAllowlistedScalarReadsAndDoesNotSerializeArbitraryText() throws {
        let reader = FakeReader()
        reader.names = [kAXValueAttribute, kAXSelectedTextAttribute, "AXTitle", "AXDescription"]
        reader.parameterized = [kAXStringForRangeParameterizedAttribute, "AXPrivateUserText"]
        reader.scalars[.role] = (.success, "user-secret-role" as AnyObject)
        reader.scalars[.subrole] = (.success, "AXSecureTextField" as AnyObject)
        reader.scalars[.enabled] = (.success, kCFBooleanTrue)
        reader.scalars[.editable] = (.success, "user-secret-editable" as AnyObject)
        reader.scalars[.readOnly] = (.noValue, nil)

        let result = AXCapabilityDiagnostics.metadata(from: reader)
        XCTAssertEqual(Set(reader.scalarReads), Set(AXCapabilityDiagnostics.MetadataScalar.allCases))
        XCTAssertEqual(reader.scalarReads.count, AXCapabilityDiagnostics.MetadataScalar.allCases.count)
        XCTAssertEqual(Set(reader.settableChecks), Set([kAXValueAttribute, kAXSelectedTextAttribute,
                                                        kAXSelectedTextRangeAttribute, "AXSelectedTextMarkerRange"]))
        XCTAssertEqual(result["role"] as? String, "Other")
        XCTAssertEqual(result["secureTextSubrole"] as? Bool, true)
        let editability = try XCTUnwrap(result["editability"] as? [String: [String: Any]])
        XCTAssertEqual(editability["AXEnabled"]?["state"] as? String, "true")
        XCTAssertEqual(editability["AXEditable"]?["state"] as? String, "invalid")
        XCTAssertEqual(editability["AXReadOnly"]?["state"] as? String, "unavailable")
        let attributes = try XCTUnwrap(result["attributes"] as? [String: [String: Any]])
        XCTAssertEqual(attributes[kAXValueAttribute]?["present"] as? Bool, true)
        XCTAssertEqual(attributes[kAXValueAttribute]?["settable"] as? Bool, true)
        XCTAssertEqual(attributes[kAXSelectedTextRangeAttribute]?["present"] as? Bool, false)
        XCTAssertEqual(result["parameterizedAttributes"] as? [String], [kAXStringForRangeParameterizedAttribute])
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let output = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(output.contains("user-secret"))
        XCTAssertFalse(output.contains("AXPrivateUserText"))
        XCTAssertFalse(output.contains("AXTitle"))
        XCTAssertFalse(output.contains("AXDescription"))
    }

    @MainActor
    func testMetadataModeRejectsAccessibilitySetterFlagBeforeInspectingApps() {
        XCTAssertEqual(AXCapabilityDiagnostics.runIfRequested(arguments: ["MacSwitcher",
            "--ax-capabilities-metadata", "com.apple.TextEdit", "--enable-accessibility"]), 2)
    }

    @MainActor
    func testOverlayMetadataSerializesOnlyClosedRolesAndAttributeMembership() throws {
        let focus = AXCapabilityDiagnostics.overlayFocusMetadata(
            role: "private-role-text", subrole: "private-subrole-text",
            attributeNames: [kAXValueAttribute, kAXSelectedTextRangeAttribute,
                "AXTitle", "AXDescription", "private-window-title"])
        XCTAssertEqual(focus.role, .other)
        XCTAssertTrue(focus.valueAttributePresent)
        XCTAssertTrue(focus.selectedTextRangeAttributePresent)
        XCTAssertFalse(focus.selectedTextAttributePresent)
        let encoded = try JSONEncoder().encode(focus)
        let output = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["private", "AXTitle", "AXDescription", "AXValue", "AXSelectedTextRange"] {
            XCTAssertFalse(output.contains(forbidden))
        }
    }

    @MainActor
    func testOverlayHostInspectionIncludesThirdPartyBundleIDsAndIsBoundedToTwelve() throws {
        var inspected: [Int32] = []
        let pids = [Int32(1), 1, 2, 3] + Array(Int32(4)...Int32(30))
        let hosts = AXCapabilityDiagnostics.overlayHosts(windowOwnerPIDs: pids,
            bundleIDForPID: { pid in
                pid == 2 ? "com.example.launcher" : pid == 3 ? nil
                    : pid == 1 ? "com.apple.Spotlight" : "private window title"
            }, inspect: { pid in inspected.append(pid); return .unavailable })
        XCTAssertEqual(hosts.count, 12)
        XCTAssertEqual(inspected.count, 12)
        XCTAssertEqual(Set(inspected).count, 12)
        XCTAssertEqual(hosts.first?.bundleID, "com.apple.Spotlight")
        XCTAssertEqual(hosts[1].bundleID, "com.example.launcher")
        XCTAssertTrue(hosts.dropFirst(2).allSatisfy { $0.bundleID == "UnknownHost" })
        XCTAssertTrue(inspected.contains(2))
        XCTAssertTrue(inspected.contains(3))
        let encoded = try JSONEncoder().encode(hosts)
        let output = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(output.contains("private window title"))
    }

    @MainActor
    func testOverlayModeRejectsAnyAdditionalArgumentsBeforeInspection() {
        XCTAssertEqual(AXCapabilityDiagnostics.runIfRequested(arguments: ["MacSwitcher",
            "--ax-overlay-metadata", "--enable-accessibility"]), 2)
        XCTAssertEqual(AXCapabilityDiagnostics.runIfRequested(arguments: ["MacSwitcher",
            "--ax-overlay-metadata", "com.apple.Spotlight"]), 2)
    }

    @MainActor
    func testUnknownAXFlagsExitBeforeGUI() {
        XCTAssertEqual(AXCapabilityDiagnostics.runIfRequested(arguments: ["MacSwitcher", "--ax-metadata"]), 2)
        XCTAssertEqual(AXCapabilityDiagnostics.runIfRequested(arguments: ["MacSwitcher",
            "--ax-overlay-metadata=anything"]), 2)
        XCTAssertNil(AXCapabilityDiagnostics.runIfRequested(arguments: ["MacSwitcher", "--benchmark-prediction"]))
    }
}
