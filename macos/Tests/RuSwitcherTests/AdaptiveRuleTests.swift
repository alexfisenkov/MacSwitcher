import Foundation
import ApplicationServices
import XCTest
@testable import RuSwitcher

final class AdaptiveRuleTests: XCTestCase {
    @MainActor
    func testManualAThenAutomaticBUndoRedoKeepsAAndRetractsB() throws {
        let focus = CombinedShiftFocus(processID: 6091,
            element: AXUIElementCreateApplication(6091))
        var provenance = AdaptiveManualProvenance()
        var autoProvenance = AdaptiveAutomaticUndoProvenance()
        var rules: [AdaptiveRule] = []
        var seen: Set<UUID> = [], withdrawn: Set<UUID> = []
        var votes: [UUID: AdaptiveVote] = [:]
        let manualA = try XCTUnwrap(provenance.confirmed(original: "abc", replacement: "фис",
            focus: focus, reconvert: false))
        AdaptiveRulePolicy.apply(manualA, to: &rules, seen: &seen, withdrawn: &withdrawn,
            votes: &votes)
        provenance.invalidate() // B was automatically applied; A's manual receipt is no longer current.
        let bID = UUID()
        let automaticB = AdaptiveEvidence.automaticUndoConfirmed(id: bID,
            original: "а", replacement: "f")
        AdaptiveRulePolicy.apply(automaticB, to: &rules, seen: &seen, withdrawn: &withdrawn,
            votes: &votes)
        AdaptiveRulePolicy.apply(automaticB, to: &rules, seen: &seen, withdrawn: &withdrawn,
            votes: &votes)
        autoProvenance.confirmedUndo(id: bID, original: "а", replacement: "f", focus: focus)
        XCTAssertNil(provenance.confirmed(original: "f", replacement: "а",
            focus: focus, reconvert: true)) // B redo must not withdraw A.
        let redoB = try XCTUnwrap(autoProvenance.confirmedRedo(original: "f", replacement: "а",
            focus: focus))
        AdaptiveRulePolicy.apply(redoB, to: &rules, seen: &seen, withdrawn: &withdrawn,
            votes: &votes)
        XCTAssertNil(autoProvenance.confirmedRedo(original: "f", replacement: "а",
            focus: focus))
        AdaptiveRulePolicy.apply(automaticB, to: &rules, seen: &seen, withdrawn: &withdrawn,
            votes: &votes) // Same receipt cannot revive the withdrawn vote.
        XCTAssertEqual(rules.first(where: { $0.pair.en == "abc" })?.confirmations, 1)
        XCTAssertNil(rules.first(where: { $0.pair.en == "f" }))
        AdaptiveRulePolicy.apply(.automaticUndoConfirmed(id: UUID(), original: "а", replacement: "f"),
            to: &rules, seen: &seen, withdrawn: &withdrawn, votes: &votes)
        XCTAssertEqual(rules.first(where: { $0.pair.en == "f" })?.confirmations, 1)
    }

    @MainActor
    func testManualUndoRequiresMatchingPairAndField() throws {
        let focus = CombinedShiftFocus(processID: 6092,
            element: AXUIElementCreateApplication(6092))
        let other = CombinedShiftFocus(processID: 6093,
            element: AXUIElementCreateApplication(6093))
        var provenance = AdaptiveManualProvenance()
        XCTAssertNotNil(provenance.confirmed(original: "abc", replacement: "фис",
            focus: focus, reconvert: false))
        XCTAssertNil(provenance.confirmed(original: "фис", replacement: "abc",
            focus: other, reconvert: true))
        XCTAssertNotNil(provenance.confirmed(original: "abc", replacement: "фис",
            focus: focus, reconvert: false))
        XCTAssertNil(provenance.confirmed(original: "а", replacement: "f",
            focus: focus, reconvert: true))
        XCTAssertNotNil(provenance.confirmed(original: "abc", replacement: "фис",
            focus: focus, reconvert: false))
        XCTAssertNotNil(provenance.confirmed(original: "фис", replacement: "abc",
            focus: focus, reconvert: true))
    }

    @MainActor
    func testAutomaticRedoRequiresMatchingPairAndField() throws {
        let focus = CombinedShiftFocus(processID: 6094,
            element: AXUIElementCreateApplication(6094))
        let other = CombinedShiftFocus(processID: 6095,
            element: AXUIElementCreateApplication(6095))
        var provenance = AdaptiveAutomaticUndoProvenance()
        provenance.confirmedUndo(id: UUID(), original: "а", replacement: "f", focus: focus)
        XCTAssertNil(provenance.confirmedRedo(original: "f", replacement: "а", focus: other))
        provenance.confirmedUndo(id: UUID(), original: "а", replacement: "f", focus: focus)
        XCTAssertNil(provenance.confirmedRedo(original: "abc", replacement: "фис", focus: focus))
        provenance.confirmedUndo(id: UUID(), original: "а", replacement: "f", focus: focus)
        XCTAssertNotNil(provenance.confirmedRedo(original: "f", replacement: "а", focus: focus))
    }

    func testDefaultOnDoesNotReadOrRecordBeforeExplanation() {
        XCTAssertFalse(AdaptiveIntroPolicy.mayReadOrRecord(preferenceEnabled: true,
            explanationShown: false))
        XCTAssertTrue(AdaptiveIntroPolicy.mayReadOrRecord(preferenceEnabled: true,
            explanationShown: true))
        XCTAssertFalse(AdaptiveIntroPolicy.mayReadOrRecord(preferenceEnabled: false,
            explanationShown: true))
    }

    func testTwoOccurrencesAndOppositeRevocation() throws {
        var rules: [AdaptiveRule] = []
        var seen: Set<UUID> = []
        var withdrawn: Set<UUID> = []
        var votes: [UUID: AdaptiveVote] = [:]
        let first = UUID(), second = UUID(), opposite = UUID()
        AdaptiveRulePolicy.apply(.manualConfirmed(id: first, original: "ghbdtn", replacement: "привет"), to: &rules, seen: &seen, withdrawn: &withdrawn, votes: &votes)
        XCTAssertEqual(rules.first?.confirmations, 1)
        AdaptiveRulePolicy.apply(.manualConfirmed(id: first, original: "ghbdtn", replacement: "привет"), to: &rules, seen: &seen, withdrawn: &withdrawn, votes: &votes)
        XCTAssertEqual(rules.first?.confirmations, 1)
        AdaptiveRulePolicy.apply(.manualConfirmed(id: second, original: "ghbdtn", replacement: "привет"), to: &rules, seen: &seen, withdrawn: &withdrawn, votes: &votes)
        XCTAssertEqual(rules.first?.confirmations, 2)
        AdaptiveRulePolicy.apply(.manualUndo(id: first), to: &rules, seen: &seen, withdrawn: &withdrawn, votes: &votes)
        XCTAssertEqual(rules.first?.confirmations, 1)
        AdaptiveRulePolicy.apply(.manualUndo(id: first), to: &rules, seen: &seen, withdrawn: &withdrawn, votes: &votes)
        XCTAssertEqual(rules.first?.confirmations, 1)
        AdaptiveRulePolicy.apply(.manualConfirmed(id: first, original: "ghbdtn", replacement: "привет"), to: &rules, seen: &seen, withdrawn: &withdrawn, votes: &votes)
        XCTAssertEqual(rules.first?.confirmations, 1)
        AdaptiveRulePolicy.apply(.manualConfirmed(id: opposite, original: "привет", replacement: "ghbdtn"), to: &rules, seen: &seen, withdrawn: &withdrawn, votes: &votes)
        XCTAssertEqual(rules.first?.confirmations, 1)
        XCTAssertEqual(rules.first?.preferred, "en")
    }

    func testWordOnlyAndMappedPunctuation() {
        XCTAssertEqual(AdaptiveWordPair.make("j,sxyj", "обычно")?.pair.ru, "обычно")
        XCTAssertEqual(AdaptiveWordPair.make("to`", "ещё")?.pair.ru, "ещё")
        XCTAssertEqual(AdaptiveWordPair.make("f ", "а ")?.pair.ru, "а")
        for bad in ["hello world", "user@example.com", "a/b", "abc123", "a_foo", "abcабв", String(repeating: "a", count: 65)] {
            XCTAssertNil(AdaptiveWordPair.make(bad, "фис"), bad)
        }
        XCTAssertNil(AdaptiveWordPair.make("QwerTyuiOpasDfghJklzXcvb", "йцукенгшщзфывапролдячсм").map(\.pair))
    }

    func testStoreGenerationDisabledAndRestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("adaptive-rules.json")
        let store = AdaptiveRuleStore(fileURL: url)
        let stale = store.currentGeneration
        XCTAssertFalse(try store.record(.manualConfirmed(id: UUID(), original: "f", replacement: "а"), generation: stale))
        store.setEnabled(true)
        XCTAssertFalse(try store.record(.manualConfirmed(id: UUID(), original: "f", replacement: "а"), generation: stale))
        let active = store.currentGeneration
        XCTAssertTrue(try store.record(.manualConfirmed(id: UUID(), original: "f", replacement: "а"), generation: active))
        XCTAssertEqual(store.allRules().count, 1)
        XCTAssertEqual(AdaptiveRuleStore(fileURL: url, enabled: true).rules().count, 1)
        store.setEnabled(false)
        XCTAssertTrue(store.rules().isEmpty)
        store.setEnabled(true)
        try store.reset()
        XCTAssertFalse(try store.record(.manualConfirmed(id: UUID(), original: "f", replacement: "а"), generation: active))
        XCTAssertTrue(store.rules().isEmpty)
    }

    func testResetAndOffDoNotReviveOldOccurrence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AdaptiveRuleStore(fileURL: folder.appendingPathComponent("adaptive-rules.json"), enabled: true)
        let id = UUID()
        XCTAssertTrue(try store.record(.manualConfirmed(id: id, original: "abc", replacement: "фис"),
            generation: store.currentGeneration))
        try store.reset()
        XCTAssertFalse(try store.record(.manualConfirmed(id: id, original: "abc", replacement: "фис"),
            generation: store.currentGeneration))
        store.setEnabled(false)
        store.setEnabled(true)
        XCTAssertFalse(try store.record(.manualConfirmed(id: id, original: "abc", replacement: "фис"),
            generation: store.currentGeneration))
        XCTAssertTrue(store.rules().isEmpty)
    }

    func testToggleKeepsOccurrenceUndoAndRedoTombstone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AdaptiveRuleStore(fileURL: folder.appendingPathComponent("adaptive-rules.json"), enabled: true)
        let first = UUID()
        let choice = AdaptiveEvidence.manualConfirmed(id: first, original: "abc", replacement: "фис")
        XCTAssertTrue(try store.record(choice, generation: store.currentGeneration))
        store.setEnabled(false)
        XCTAssertTrue(store.rules().isEmpty)
        store.setEnabled(true)
        XCTAssertTrue(try store.record(.manualUndo(id: first), generation: store.currentGeneration))
        XCTAssertTrue(store.allRules().isEmpty)
        XCTAssertFalse(try store.record(choice, generation: store.currentGeneration))
        let next = UUID()
        XCTAssertTrue(try store.record(.manualConfirmed(id: next, original: "abc", replacement: "фис"),
            generation: store.currentGeneration))
        XCTAssertEqual(store.allRules().first?.confirmations, 1)
        let second = UUID()
        XCTAssertTrue(try store.record(.manualConfirmed(id: second, original: "abc", replacement: "фис"),
            generation: store.currentGeneration))
        XCTAssertEqual(store.allRules().first?.confirmations, 2)
        store.setEnabled(false)
        store.setEnabled(true)
        XCTAssertTrue(try store.record(.manualUndo(id: next), generation: store.currentGeneration))
        XCTAssertEqual(store.allRules().first?.confirmations, 1)
    }

    func testCorruptFilePreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("adaptive-rules.json")
        let data = Data("{\"schema\":99}".utf8)
        try data.write(to: url)
        let store = AdaptiveRuleStore(fileURL: url, enabled: true)
        XCTAssertNotNil(store.readOnlyError)
        XCTAssertThrowsError(try store.record(.manualConfirmed(id: UUID(), original: "f", replacement: "а"), generation: store.currentGeneration))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testOversizedFileIsPreservedReadOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("adaptive-rules.json")
        let data = Data(repeating: 65, count: 512 * 1024 + 1)
        try data.write(to: url)
        let store = AdaptiveRuleStore(fileURL: url, enabled: true)
        XCTAssertNotNil(store.readOnlyError)
        XCTAssertEqual(try Data(contentsOf: url).count, data.count)
    }

    func testPostReplaceReadbackFailureRestoresDiskAndRAM() throws {
        enum SimulatedReadFailure: Error { case fail }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("adaptive-rules.json")
        let seed = AdaptiveRuleStore(fileURL: url, enabled: true)
        XCTAssertTrue(try seed.record(.manualConfirmed(id: UUID(), original: "abc", replacement: "фис"),
            generation: seed.currentGeneration))
        let before = try Data(contentsOf: url)
        let failing = AdaptiveRuleStore(fileURL: url, enabled: true,
            postReplaceReadback: { _ in throw SimulatedReadFailure.fail })
        let priorRules = failing.allRules()
        XCTAssertThrowsError(try failing.record(.manualConfirmed(id: UUID(), original: "f", replacement: "а"),
            generation: failing.currentGeneration))
        XCTAssertEqual(failing.allRules(), priorRules)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(AdaptiveRuleStore(fileURL: url, enabled: true).allRules(), priorRules)
        let hiddenBackups = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".adaptive-backup-") }
        XCTAssertTrue(hiddenBackups.isEmpty)
    }

    func testCommittedResetReportsPrivateBackupCleanupFailureAndRetries() throws {
        enum SimulatedCleanupFailure: Error { case fail }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("adaptive-rules.json")
        let seed = AdaptiveRuleStore(fileURL: url, enabled: true)
        XCTAssertTrue(try seed.record(.manualConfirmed(id: UUID(), original: "abc", replacement: "фис"),
            generation: seed.currentGeneration))
        let failing = AdaptiveRuleStore(fileURL: url, enabled: true,
            cleanupArtifact: { _ in throw SimulatedCleanupFailure.fail })
        try failing.reset()
        XCTAssertTrue(failing.allRules().isEmpty)
        XCTAssertNotNil(failing.readOnlyError)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".adaptive-backup-") }.isEmpty)
        let restarted = AdaptiveRuleStore(fileURL: url, enabled: true)
        XCTAssertTrue(restarted.allRules().isEmpty)
        XCTAssertNil(restarted.readOnlyError)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".adaptive-backup-") }.isEmpty)
    }

    func testFirstWriteCrashTempCleanupWithoutMainPreservesPossibleBackup() throws {
        enum SimulatedCleanupFailure: Error { case fail }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = folder.appendingPathComponent("adaptive-rules.json")
        let temp = folder.appendingPathComponent(".adaptive-\(UUID().uuidString).tmp")
        let backup = folder.appendingPathComponent(".adaptive-backup-\(UUID().uuidString)")
        try Data("synthetic pending word".utf8).write(to: temp)
        try Data("synthetic possible recovery".utf8).write(to: backup)
        let failed = AdaptiveRuleStore(fileURL: main, enabled: true,
            cleanupArtifact: { _ in throw SimulatedCleanupFailure.fail })
        XCTAssertNotNil(failed.readOnlyError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
        let restarted = AdaptiveRuleStore(fileURL: main, enabled: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertNotNil(restarted.readOnlyError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: main.path))
    }
}
