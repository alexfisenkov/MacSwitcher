import XCTest
@testable import RuSwitcher

final class NativeAXMessagingPolicyTests: XCTestCase {
    private let flags = ["--diagnostic-panel", "--diagnostic-native-canary"]
    private let option = "--diagnostic-native-ax-timeout-ms"

    func testOverrideRequiresBothExactDiagnosticFlags() {
        for arguments in [[], ["--diagnostic-panel"], ["--diagnostic-native-canary"],
                          ["--diagnostic-panel=true", "--diagnostic-native-canary"],
                          ["--diagnostic-panel", "--diagnostic-native-canary=true"]] {
            XCTAssertEqual(NativeAXMessagingPolicy.configuredTimeout(arguments: arguments + [option, "20"]), 0.020)
        }
        XCTAssertEqual(NativeAXMessagingPolicy.configuredTimeout(arguments: flags), 0.020)
    }

    func testOnlyFourWhitelistedValuesWorkInSeparateAndEqualsForms() {
        for (value, expected) in [("1", 0.001), ("3", 0.003), ("10", 0.010), ("20", 0.020)] {
            XCTAssertEqual(NativeAXMessagingPolicy.configuredTimeout(arguments: flags + [option, value]), expected)
            XCTAssertEqual(NativeAXMessagingPolicy.configuredTimeout(arguments: flags + [option + "=" + value]), expected)
        }
    }

    func testMalformedMissingAndDuplicateOverridesFailClosedToDefaultTwentyMilliseconds() {
        for value in ["", "0", "2", "5", "-1", "NaN", "inf", "10.0", "010", "+10", "1000"] {
            XCTAssertEqual(NativeAXMessagingPolicy.configuredTimeout(arguments: flags + [option, value]), 0.020)
        }
        XCTAssertEqual(NativeAXMessagingPolicy.configuredTimeout(arguments: flags + [option]), 0.020)
        XCTAssertEqual(NativeAXMessagingPolicy.configuredTimeout(arguments: flags + [option, "10", option + "=20"]), 0.020)
    }

    func testRpcTimeoutIsPositiveAndBoundedByConfiguredAndRemainingBudgets() throws {
        for configured in [0.001, 0.003, 0.010, 0.020] {
            for remaining in [0.0000000001, 0.0005, 0.005, 0.180] {
                let timeout = try XCTUnwrap(NativeAXMessagingPolicy.remainingTimeout(until: remaining,
                    now: 0, configuredTimeout: configured))
                XCTAssertGreaterThan(timeout, 0)
                XCTAssertLessThanOrEqual(Double(timeout), configured)
                XCTAssertLessThanOrEqual(Double(timeout), remaining)
                XCTAssertEqual(Double(timeout), min(configured, remaining), accuracy: 0.000000001)
            }
        }
    }

    func testExpiredNonfiniteAndNegativeClockInputsNeverAuthorizeAnRpc() {
        for (deadline, now) in [(0.0, 0.0), (1, 1), (1, 2), (-1, 0), (1, -0.001),
                                (.nan, 0), (.infinity, 0), (1, .nan), (1, .infinity), (1, -.infinity)] {
            XCTAssertNil(NativeAXMessagingPolicy.remainingTimeout(until: deadline, now: now, configuredTimeout: 0.003))
        }
    }

    func testInvalidConfigurationAndFloatUnderflowNeverProduceZeroDefaultReset() {
        for configured in [0, -0.001, 0.021, TimeInterval.nan, .infinity, -.infinity] {
            XCTAssertNil(NativeAXMessagingPolicy.remainingTimeout(until: 1, now: 0, configuredTimeout: configured))
        }
        XCTAssertNil(NativeAXMessagingPolicy.remainingTimeout(until: Double.leastNonzeroMagnitude,
            now: 0, configuredTimeout: 0.003))
    }
}
