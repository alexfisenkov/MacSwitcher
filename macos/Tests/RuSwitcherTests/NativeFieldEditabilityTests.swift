import ApplicationServices
import XCTest
@testable import RuSwitcher

final class NativeFieldEditabilityTests: XCTestCase {
    func testCocoaTextAreaWithMissingFlagsAndSettableSelectedTextIsEligible() {
        XCTAssertTrue(NativeFieldEditabilityPolicy.allows(enabled: .unavailable,
            readOnly: .unavailable, editable: .unavailable, selectedTextSettable: .value(true)))
    }

    func testReadOnlyCocoaTextAreaWithMissingFlagsAndUnsettableSelectedTextIsRefused() {
        // Such a field may still expose a settable selection range. Selection
        // navigation alone is not evidence that the text can be edited.
        XCTAssertFalse(NativeFieldEditabilityPolicy.allows(enabled: .unavailable,
            readOnly: .unavailable, editable: .unavailable, selectedTextSettable: .value(false)))
    }

    func testExplicitNegativeFlagsOverridePositiveEditingCapability() {
        let cases: [(NativeFieldBooleanSignal, NativeFieldBooleanSignal, NativeFieldBooleanSignal)] = [
            (.value(false), .unavailable, .value(true)),
            (.value(true), .value(true), .value(true)),
            (.value(true), .value(false), .value(false)),
        ]
        for (enabled, readOnly, editable) in cases {
            XCTAssertFalse(NativeFieldEditabilityPolicy.allows(enabled: enabled,
                readOnly: readOnly, editable: editable, selectedTextSettable: .value(true)))
        }
    }

    func testInvalidFlagReadsOverridePositiveEditingCapability() {
        let cases: [(NativeFieldBooleanSignal, NativeFieldBooleanSignal, NativeFieldBooleanSignal)] = [
            (.invalid, .unavailable, .value(true)),
            (.value(true), .invalid, .value(true)),
            (.value(true), .value(false), .invalid),
        ]
        for (enabled, readOnly, editable) in cases {
            XCTAssertFalse(NativeFieldEditabilityPolicy.allows(enabled: enabled,
                readOnly: readOnly, editable: editable, selectedTextSettable: .value(true)))
        }
    }

    func testMissingEditableRequiresPositiveSelectedTextCapability() {
        // AXValue alone is deliberately not a fallback: eligibility requires
        // AXSelectedText when the explicit editable flag is absent.
        for capability in [NativeFieldBooleanSignal.value(false), .unavailable, .invalid] {
            XCTAssertFalse(NativeFieldEditabilityPolicy.allows(enabled: .value(true),
                readOnly: .value(false), editable: .unavailable, selectedTextSettable: capability))
        }
    }

    func testExplicitEditableStillAllowsFieldWithoutSelectedTextCapability() {
        XCTAssertTrue(NativeFieldEditabilityPolicy.allows(enabled: .value(true),
            readOnly: .value(false), editable: .value(true), selectedTextSettable: .unavailable))
    }

    func testAttributeReadsDistinguishBooleansAbsenceErrorsAndMalformedValues() {
        XCTAssertEqual(NativeFieldBooleanSignal.attribute(status: .success, raw: kCFBooleanTrue), .value(true))
        XCTAssertEqual(NativeFieldBooleanSignal.attribute(status: .success, raw: kCFBooleanFalse), .value(false))
        for status in [AXError.attributeUnsupported, .noValue] {
            XCTAssertEqual(NativeFieldBooleanSignal.attribute(status: status, raw: nil), .unavailable)
        }
        for status in [AXError.cannotComplete, .failure, .apiDisabled] {
            XCTAssertEqual(NativeFieldBooleanSignal.attribute(status: status, raw: nil), .invalid)
        }
        for raw in [nil, "true" as NSString, NSNumber(value: 1)] as [AnyObject?] {
            XCTAssertEqual(NativeFieldBooleanSignal.attribute(status: .success, raw: raw), .invalid)
        }
    }

    func testCapabilityReadsRequireSuccessfulPositiveSettableResult() {
        XCTAssertEqual(NativeFieldBooleanSignal.capability(status: .success, settable: true), .value(true))
        XCTAssertEqual(NativeFieldBooleanSignal.capability(status: .success, settable: false), .value(false))
        for status in [AXError.attributeUnsupported, .noValue] {
            XCTAssertEqual(NativeFieldBooleanSignal.capability(status: status, settable: true), .unavailable)
        }
        XCTAssertEqual(NativeFieldBooleanSignal.capability(status: .cannotComplete, settable: true), .invalid)
    }
}
