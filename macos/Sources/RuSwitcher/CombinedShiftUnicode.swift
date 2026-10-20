import CoreGraphics

/// Conservative Unicode event packets. Boundaries never divide a UTF-16 surrogate pair.
enum CombinedShiftUnicode {
    static let maximumUnits = 20

    static func chunks(_ text: String) -> [[UInt16]] {
        var packets: [[UInt16]] = []
        var current: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > maximumUnits {
                packets.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { packets.append(current) }
        return packets
    }

    static func payloadMatches(_ event: CGEvent, expected: [UInt16]) -> Bool {
        var units = [UInt16](repeating: 0, count: expected.count + 1)
        var length = 0
        let capacity = units.count
        event.keyboardGetUnicodeString(maxStringLength: capacity, actualStringLength: &length, unicodeString: &units)
        return length == expected.count && Array(units.prefix(length)) == expected
    }
}
