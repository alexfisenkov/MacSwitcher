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
}
