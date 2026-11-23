import AppKit
import XCTest
@testable import RuSwitcher

/// R12: erased a confirmed automatic correction and typed the original keys
/// again — the same "do not correct" vote as a confirmed undo. Synthetic words only.
final class ImplicitUndoTests: XCTestCase {
    private let id = UUID()

    private func erase(_ watch: inout ImplicitUndoWatch, _ count: Int, pid: Int32 = 7) {
        for _ in 0..<count { watch.noteBackspace(processID: pid) }
    }

    func testErasingTheWholeCorrectionAndRetypingTheOriginalVotes() {
        var watch = ImplicitUndoWatch()
        watch.arm(id: id, corrected: "привет ", original: "ghbdtn ", processID: 7)
        erase(&watch, 7)
        var vote: ImplicitUndoWatch.Vote?
        for character in "ghbdtn" { vote = watch.noteTyped(String(character), processID: 7) ?? vote }
        XCTAssertEqual(vote, .init(id: id, original: "привет", replacement: "ghbdtn"))
        XCTAssertFalse(watch.isArmed)
    }

    func testRetypeThroughAReCorrectedPrefixStillCountsByPhysicalKey() {
        var watch = ImplicitUndoWatch()
        watch.arm(id: id, corrected: "привет", original: "ghbdtn", processID: 7)
        erase(&watch, 6)
        for character in "ghbd" { XCTAssertNil(watch.noteTyped(String(character), processID: 7)) }
        // Automatic correction of the retyped prefix must not erase the evidence.
        watch.arm(id: UUID(), corrected: "прив", original: "ghbd", processID: 7)
        XCTAssertNil(watch.noteTyped("е", processID: 7))
        XCTAssertEqual(watch.noteTyped("т", processID: 7)?.id, id)
    }

    func testPartialEraseOtherWordOtherAppOrMultiWordNeverVote() {
        var watch = ImplicitUndoWatch()
        watch.arm(id: id, corrected: "привет", original: "ghbdtn", processID: 7)
        erase(&watch, 3)
        for character in "ghbdtn" { XCTAssertNil(watch.noteTyped(String(character), processID: 7)) }

        watch.arm(id: id, corrected: "привет", original: "ghbdtn", processID: 7)
        erase(&watch, 6)
        XCTAssertNil(watch.noteTyped("x", processID: 7))
        XCTAssertFalse(watch.isArmed)

        watch.arm(id: id, corrected: "привет", original: "ghbdtn", processID: 7)
        erase(&watch, 6)
        XCTAssertNil(watch.noteTyped("g", processID: 8))
        XCTAssertFalse(watch.isArmed)

        watch.arm(id: id, corrected: "а не", original: "f yt", processID: 7)
        XCTAssertFalse(watch.isArmed)
    }

    func testTwoIndependentImplicitUndosActivateTheRuleLikeConfirmedUndo() {
        var rules: [AdaptiveRule] = [], seen = Set<UUID>(), withdrawn = Set<UUID>()
        var votes: [UUID: AdaptiveVote] = [:]
        for _ in 0..<2 {
            var watch = ImplicitUndoWatch()
            let occurrence = UUID()
            watch.arm(id: occurrence, corrected: "привет ", original: "ghbdtn ", processID: 7)
            erase(&watch, 7)
            var vote: ImplicitUndoWatch.Vote?
            for character in "ghbdtn" { vote = watch.noteTyped(String(character), processID: 7) ?? vote }
            let cast = try? XCTUnwrap(vote)
            AdaptiveRulePolicy.apply(.automaticUndoConfirmed(id: occurrence,
                original: cast?.original ?? "", replacement: cast?.replacement ?? ""),
                to: &rules, seen: &seen, withdrawn: &withdrawn, votes: &votes)
        }
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.preferred, "en")
        XCTAssertEqual(rules.first?.confirmations, 2)
    }

    @MainActor
    func testMonitorDeliversTheVoteOnlyAfterTheKeyCallbackReturns() throws {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        try XCTSkipIf(pid <= 0, "No frontmost process to bind the synthetic keys to")
        let monitor = KeyboardMonitor()
        var votes: [ImplicitUndoWatch.Vote] = []
        monitor.onImplicitUndo = { votes.append($0) }
        monitor.armImplicitUndo(id: id, corrected: "привет", original: "ghbdtn", processID: pid)
        for _ in 0..<6 { monitor.handleKeyDown(keyCode: KC.backspace, flags: []) }
        for character in "ghbdtn" {
            let code = try XCTUnwrap(KeyMapping.keycodeToEN.first(where: { $0.value == character })?.key)
            monitor.handleKeyDown(keyCode: code, flags: [], renderedText: String(character))
        }
        XCTAssertTrue(votes.isEmpty, "Learning never runs inside the key callback")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(votes, [.init(id: id, original: "привет", replacement: "ghbdtn")])
    }
}
