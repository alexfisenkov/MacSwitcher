import Foundation

/// Diagnostic RPC budget only; it never extends an edit or input-fence deadline.
enum NativeAXMessagingPolicy {
    static let defaultTimeout: TimeInterval = 0.003
    private static let option = "--diagnostic-native-ax-timeout-ms"

    static func configuredTimeout(arguments: [String]) -> TimeInterval {
        guard arguments.contains("--diagnostic-panel"),
              arguments.contains("--diagnostic-native-canary") else { return defaultTimeout }
        var values: [String] = []
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == option {
                guard index + 1 < arguments.count else { return defaultTimeout }
                values.append(arguments[index + 1])
            } else if argument.hasPrefix(option + "=") {
                values.append(String(argument.dropFirst(option.count + 1)))
            }
        }
        guard values.count == 1 else { return defaultTimeout }
        switch values[0] {
        case "1": return 0.001
        case "3": return 0.003
        case "10": return 0.010
        case "20": return 0.020
        default: return defaultTimeout
        }
    }

    static func remainingTimeout(until deadline: TimeInterval, now: TimeInterval,
                                 configuredTimeout: TimeInterval) -> Float? {
        guard deadline.isFinite, now.isFinite, now >= 0, deadline > now,
              configuredTimeout.isFinite, configuredTimeout > 0, configuredTimeout <= 0.020 else { return nil }
        let limit = min(configuredTimeout, deadline - now)
        var value = Float(limit)
        // Float rounding must not extend the remaining deadline. Zero would
        // reset AX's default timeout, so underflow is a refusal, never an RPC.
        if Double(value) > limit { value = value.nextDown }
        guard value.isFinite, value > 0 else { return nil }
        return value
    }
}
