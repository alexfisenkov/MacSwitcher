import Foundation

/// A deliberately narrow map between a rich editor's formatted AXValue and
/// the text-content coordinate space used by its selected numeric range.
/// Only generated LF separators may differ. The complete bounded strings
/// must align monotonically; no occurrence search or offset guessing is used.
struct NativeSelectedTextProjection: Equatable {
    let formatted: String
    let flat: String
    private let firstFormattedOffset: [Int]
    private let lastFormattedOffset: [Int]

    init?(formatted: String, flat: String) {
        let formattedUnits = Array(formatted.utf16)
        let flatUnits = Array(flat.utf16)
        guard formattedUnits.count <= NativeFieldEditPlan.maximumFieldUnits,
              flatUnits.count <= NativeFieldEditPlan.maximumFieldUnits,
              NativeFieldEditPlan.isWellFormedUTF16(formattedUnits),
              NativeFieldEditPlan.isWellFormedUTF16(flatUnits),
              !flatUnits.contains(0x000A), !formattedUnits.contains(0x000D) else { return nil }
        var first = [Int](repeating: -1, count: flatUnits.count + 1)
        var last = [Int](repeating: -1, count: flatUnits.count + 1)
        first[0] = 0
        last[0] = 0
        var raw = 0
        for (formattedOffset, unit) in formattedUnits.enumerated() {
            if unit != 0x000A {
                guard raw < flatUnits.count, unit == flatUnits[raw] else { return nil }
                raw += 1
                if first[raw] == -1 { first[raw] = formattedOffset + 1 }
            }
            last[raw] = formattedOffset + 1
        }
        guard raw == flatUnits.count, first.allSatisfy({ $0 >= 0 }),
              last.allSatisfy({ $0 >= 0 }) else { return nil }
        self.formatted = formatted
        self.flat = flat
        firstFormattedOffset = first
        lastFormattedOffset = last
    }

    /// For a nonempty selection, its start is after any generated separator
    /// at that raw offset and its end is before a separator at the end offset.
    /// A selection crossing a structural boundary is refused.
    func formattedStart(rawRange: CFRange, byRange: String) -> Int? {
        let flatUnits = Array(flat.utf16)
        let formattedUnits = Array(formatted.utf16)
        guard rawRange.location >= 0, rawRange.length > 0,
              rawRange.location <= flatUnits.count,
              rawRange.length <= flatUnits.count - rawRange.location,
              rawRange.length == byRange.utf16.count else { return nil }
        let start = rawRange.location
        let end = start + rawRange.length
        let mappedStart = lastFormattedOffset[start]
        let mappedEnd = firstFormattedOffset[end]
        guard mappedEnd >= mappedStart,
              mappedEnd - mappedStart == rawRange.length,
              flatUnits[start..<end].elementsEqual(byRange.utf16),
              formattedUnits[mappedStart..<mappedEnd].elementsEqual(byRange.utf16) else { return nil }
        return mappedStart
    }

    func selectedFormattedStart(rawRange: CFRange, byRange: String, byAttribute: String) -> Int? {
        guard byRange.utf16.elementsEqual(byAttribute.utf16) else { return nil }
        return formattedStart(rawRange: rawRange, byRange: byRange)
    }

    /// A collapsed raw caret adjacent to a generated separator has two
    /// formatted positions. Its side must be proved by another signal.
    func unambiguousFormattedCaret(rawLocation: Int) -> Int? {
        guard rawLocation >= 0, rawLocation < firstFormattedOffset.count,
              firstFormattedOffset[rawLocation] == lastFormattedOffset[rawLocation] else { return nil }
        return firstFormattedOffset[rawLocation]
    }

    func paragraphText(startingAt formattedStart: Int) -> String? {
        let units = Array(formatted.utf16)
        guard formattedStart >= 0, formattedStart < units.count,
              units[formattedStart] != 0x000A else { return nil }
        var end = formattedStart
        while end < units.count && units[end] != 0x000A { end += 1 }
        let paragraph = Array(units[formattedStart..<end])
        guard !paragraph.isEmpty, NativeFieldEditPlan.isWellFormedUTF16(paragraph) else { return nil }
        return String(decoding: paragraph, as: UTF16.self)
    }
}
