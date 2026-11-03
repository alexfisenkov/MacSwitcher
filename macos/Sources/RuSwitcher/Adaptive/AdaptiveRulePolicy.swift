import Foundation

/// A canonical physical-key pair. No surrounding field text reaches this type.
struct AdaptiveWordPair: Codable, Hashable, Sendable {
    let ru: String
    let en: String

    static func make(_ first: String, _ second: String) -> (pair: Self, preferred: String)? {
        guard !looksLikeLongIdentifier(first), !looksLikeLongIdentifier(second) else { return nil }
        let a = first.trimmingCharacters(in: .whitespaces).lowercased().precomposedStringWithCanonicalMapping
        let b = second.trimmingCharacters(in: .whitespaces).lowercased().precomposedStringWithCanonicalMapping
        guard a != b,
              (validRussian(a) && validEnglishLayout(b)) ||
              (validRussian(b) && validEnglishLayout(a)) else { return nil }
        if validRussian(a), validEnglishLayout(b), maps(b, to: a) { return (Self(ru: a, en: b), "en") }
        if validRussian(b), validEnglishLayout(a), maps(a, to: b) { return (Self(ru: b, en: a), "ru") }
        return nil
    }

    private static func validRussian(_ s: String) -> Bool {
        validLength(s) && validSeparators(s) && s.contains(where: \.isLetter) &&
        s.allSatisfy { isRussian($0) || $0 == "-" || $0 == "'" || $0 == "’" }
    }

    private static func validEnglishLayout(_ s: String) -> Bool {
        validLength(s) && validSeparators(s) && s.contains(where: { $0.isLetter }) &&
        !s.contains(".") && !s.contains("/") &&
        s.allSatisfy { KeyMapping.enToRu[$0] != nil || $0 == "-" || $0 == "’" }
    }

    private static func validLength(_ s: String) -> Bool { !s.isEmpty && s.utf16.count <= 64 }
    private static func looksLikeLongIdentifier(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        guard letters.count >= 24 else { return false }
        let internalCapitals = letters.dropFirst().filter(\.isUppercase).count
        return internalCapitals >= 2
    }
    private static func validSeparators(_ s: String) -> Bool {
        guard let first = s.first, let last = s.last, first.isLetter, last.isLetter || last == "`" || last == "\\" else { return false }
        return !s.contains("--") && !s.contains("''") && !s.contains("  ")
    }
    private static func isRussian(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }
    private static func maps(_ en: String, to ru: String) -> Bool {
        guard en.count == ru.count else { return false }
        return zip(en, ru).allSatisfy { source, target in
            if (source == "-" || source == "'" || source == "’") && source == target { return true }
            return KeyMapping.enToRu[source] == target
        }
    }
}

enum AdaptiveEvidence: Sendable {
    case manualConfirmed(id: UUID, original: String, replacement: String)
    case automaticUndoConfirmed(id: UUID, original: String, replacement: String)
    case manualUndo(id: UUID)
    case automaticRedoConfirmed(id: UUID)
}

enum AdaptiveIntroPolicy {
    static func mayReadOrRecord(preferenceEnabled: Bool, explanationShown: Bool) -> Bool {
        preferenceEnabled && explanationShown
    }
}

struct AdaptiveRule: Codable, Equatable, Sendable {
    let pair: AdaptiveWordPair
    var preferred: String
    var confirmations: Int
    var confirmedAt: Date
    var lastOccurrenceID: UUID
}

struct AdaptiveVote: Sendable {
    let pair: AdaptiveWordPair
    let preferred: String
}

enum AdaptiveRulePolicy {
    static func apply(_ evidence: AdaptiveEvidence, to rules: inout [AdaptiveRule],
                      seen: inout Set<UUID>, withdrawn: inout Set<UUID>,
                      votes: inout [UUID: AdaptiveVote], now: Date = Date()) {
        switch evidence {
        case .manualUndo(let id), .automaticRedoConfirmed(let id):
            guard seen.contains(id), withdrawn.insert(id).inserted,
                  let vote = votes[id],
                  let index = rules.firstIndex(where: { $0.pair == vote.pair && $0.preferred == vote.preferred }) else { return }
            rules[index].confirmations -= 1
            if rules[index].confirmations == 0 { rules.remove(at: index) }
        case .manualConfirmed(let id, let original, let replacement),
             .automaticUndoConfirmed(let id, let original, let replacement):
            guard let parsed = AdaptiveWordPair.make(original, replacement),
                  !rules.contains(where: { $0.lastOccurrenceID == id }),
                  seen.insert(id).inserted else { return }
            votes[id] = AdaptiveVote(pair: parsed.pair, preferred: parsed.preferred)
            if let index = rules.firstIndex(where: { $0.pair == parsed.pair }) {
                if rules[index].preferred == parsed.preferred {
                    rules[index].confirmations = min(2, rules[index].confirmations + 1)
                } else {
                    rules[index].preferred = parsed.preferred
                    rules[index].confirmations = 1
                }
                rules[index].confirmedAt = now
                rules[index].lastOccurrenceID = id
            } else {
                rules.append(AdaptiveRule(pair: parsed.pair, preferred: parsed.preferred,
                    confirmations: 1, confirmedAt: now, lastOccurrenceID: id))
            }
        }
    }
}
