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

    func testTelegramTextAreaAllowsSettableValueWhenSelectedTextIsNotSettable() {
        // Two running Telegram instances expose AXTextArea with AXEnabled=true,
        // no AXEditable/AXReadOnly, AXSelectedText=false and AXValue=true.
        XCTAssertTrue(NativeFieldEditabilityPolicy.allows(enabled: .value(true),
            readOnly: .unavailable, editable: .unavailable, selectedTextSettable: .value(false),
            valueSettable: .value(true)))
    }

    func testMissingEditableAllowsSettableValueWhenSelectedTextIsUnsupported() {
        XCTAssertTrue(NativeFieldEditabilityPolicy.allows(enabled: .value(true),
            readOnly: .unavailable, editable: .unavailable, selectedTextSettable: .unavailable,
            valueSettable: .value(true)))
    }

    func testMissingEditableRejectsAbsentOrFailedCapabilityEvidence() {
        for value in [NativeFieldBooleanSignal.value(false), .unavailable, .invalid] {
            XCTAssertFalse(NativeFieldEditabilityPolicy.allows(enabled: .value(true),
                readOnly: .unavailable, editable: .unavailable, selectedTextSettable: .value(false),
                valueSettable: value))
        }
        XCTAssertFalse(NativeFieldEditabilityPolicy.allows(enabled: .value(true),
            readOnly: .unavailable, editable: .unavailable, selectedTextSettable: .unavailable))
    }

    func testFailedSelectedTextCapabilityCannotFallBackToSettableValue() {
        XCTAssertFalse(NativeFieldEditabilityPolicy.allows(enabled: .value(true),
            readOnly: .unavailable, editable: .unavailable, selectedTextSettable: .invalid,
            valueSettable: .value(true)))
    }

    func testExplicitNegativeOrInvalidFlagsCannotBeBypassedBySettableValue() {
        let cases: [(NativeFieldBooleanSignal, NativeFieldBooleanSignal, NativeFieldBooleanSignal)] = [
            (.value(false), .unavailable, .unavailable),
            (.value(true), .value(true), .unavailable),
            (.value(true), .unavailable, .value(false)),
            (.invalid, .unavailable, .unavailable),
            (.value(true), .invalid, .unavailable),
            (.value(true), .unavailable, .invalid),
        ]
        for (enabled, readOnly, editable) in cases {
            XCTAssertFalse(NativeFieldEditabilityPolicy.allows(enabled: enabled,
                readOnly: readOnly, editable: editable, selectedTextSettable: .value(false),
                valueSettable: .value(true)))
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
