import Foundation

/// Implicit undo: right after a confirmed automatic correction the person
/// erased the corrected word entirely and typed the original keys again. That
/// is the same "do not correct this" vote as a confirmed undo of that receipt.
///
/// No typing history is kept: only the one receipt's word pair (already in RAM
/// for undo), a remaining-erase counter and how many retyped keys matched.
/// The owner of the vote records it outside the key callback and input fence.
struct ImplicitUndoWatch {
    /// Same shape as `AdaptiveEvidence.automaticUndoConfirmed`: `original` is
    /// the corrected text that was removed, `replacement` the retyped word.
    struct Vote: Equatable, Sendable {
        let id: UUID
        let original: String
        let replacement: String
    }

    static let maximumUnits = 64

    private enum Phase: Equatable {
        case erasing(remaining: Int)
        case retyping(matched: Int)
    }
    private struct Armed {
        let id: UUID
        let corrected: String
        let original: [Character]
        let processID: Int32
        var phase: Phase
    }
    private var armed: Armed?

    var isArmed: Bool { armed != nil }

    mutating func disarm() { armed = nil }

    /// One single-word receipt. A retype already in progress is kept: the
    /// re-correction of its own prefix must not erase the evidence.
    mutating func arm(id: UUID, corrected: String, original: String, processID: Int32) {
        if let armed, armed.processID == processID,
           case .retyping(let matched) = armed.phase, matched > 0 { return }
        let word = original.trimmingCharacters(in: .whitespaces)
        let fixed = corrected.trimmingCharacters(in: .whitespaces)
        guard processID > 0, !word.isEmpty, !fixed.isEmpty,
              !word.contains(where: \.isWhitespace), !fixed.contains(where: \.isWhitespace),
              corrected.count <= Self.maximumUnits,
              AdaptiveWordPair.make(fixed, word) != nil else { self.armed = nil; return }
        self.armed = Armed(id: id, corrected: fixed, original: Array(word), processID: processID,
                           phase: .erasing(remaining: corrected.count))
    }

    mutating func noteBackspace(processID: Int32) {
        guard var current = armed, current.processID == processID else { armed = nil; return }
        switch current.phase {
        case .erasing(let remaining):
            current.phase = remaining <= 1 ? .retyping(matched: 0) : .erasing(remaining: remaining - 1)
        case .retyping(let matched):
            // Erasing past the corrected word is not this receipt any more.
            guard matched > 0 else { armed = nil; return }
            current.phase = .retyping(matched: matched - 1)
        }
        armed = current
    }

    mutating func noteTyped(_ text: String, processID: Int32) -> Vote? {
        guard var current = armed, current.processID == processID, !text.isEmpty else {
            armed = nil; return nil
        }
        switch current.phase {
        case .erasing(let remaining):
            // Typing on before erasing: the corrected word just grew.
            let grown = remaining + text.count
            guard grown <= Self.maximumUnits else { armed = nil; return nil }
            current.phase = .erasing(remaining: grown)
            armed = current
            return nil
        case .retyping(var matched):
            for character in text {
                guard matched < current.original.count,
                      Self.sameKey(character, current.original[matched]) else { armed = nil; return nil }
                matched += 1
            }
            guard matched == current.original.count else {
                current.phase = .retyping(matched: matched)
                armed = current
                return nil
            }
            armed = nil
            return Vote(id: current.id, original: current.corrected,
                        replacement: String(current.original))
        }
    }

    /// The same physical key: the exact character, or its RU/EN layout twin
    /// (a re-correction of the prefix may already have switched the layout).
    static func sameKey(_ typed: Character, _ expected: Character) -> Bool {
        let a = Character(typed.lowercased()), b = Character(expected.lowercased())
        return a == b || KeyMapping.enToRu[b] == a || KeyMapping.ruToEn[b] == a
    }
}
