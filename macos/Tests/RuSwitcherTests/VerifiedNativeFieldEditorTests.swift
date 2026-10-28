import XCTest
@testable import RuSwitcher

final class VerifiedNativeFieldEditorTests: XCTestCase {
    @MainActor
    private final class Field {
        var text = "ghbd"
        var caret = 4
        var selection = 0
        var original = "ghbd"
        var replacement = "прив"
        var valid = true
        var barrier = true
        var editable = true
        var clock: TimeInterval = 0
        var frozenClock = false
        var posted: [NativeFieldEditOperation] = []
        var delivered: [NativeFieldEditOperation] = []
        var pending: [NativeFieldEditOperation] = []
        var observed: [NativeFieldObservation] = []
        var pauseCount = 0
        var observeCount = 0
        var batchCount = 0
        var cancellationCount = 0
        var textQueuedCount = 0
        var rejectReplacement = false
        var readDeadlines: [TimeInterval] = []
        var editableDeadlines: [TimeInterval] = []
        var deliverImmediately = true
        var postResponse = true
        var onPost: ((NativeFieldEditOperation) -> Void)?
        var onObserve: (() -> Void)?
        var onPause: (() -> Void)?
        var onValidate: (() -> Void)?
        var onCheapGate: (() -> Void)?
        var observationUnavailable = false
        var observationOverride: ((Int) -> NativeFieldObservation?)?
        var dropFinalInsertion = false
        var deliveryTarget: Field?
        var physicalPending: [String] = []
        var physicalDelivered: [String] = []

        var snapshot: NativeFieldObservation {
            NativeFieldObservation(text: text, caretUTF16Location: caret, selectionLength: selection)
        }

        func deliverNext() {
            guard !pending.isEmpty else { return }
            let operation = pending.removeFirst()
            delivered.append(operation)
            if let target = deliveryTarget {
                target.pending.append(operation)
                target.deliverNext()
                return
            }
            var units = Array(text.utf16)
            switch operation {
            case .insertReplacement:
                if dropFinalInsertion { return }
                units.replaceSubrange(caret..<(caret + selection), with: replacement.utf16)
                caret += replacement.utf16.count
                selection = 0
            case .selectPreviousCharacter:
                if caret > 0 { caret -= 1; selection += 1 }
            case .left: caret -= 1
            case .backspace: units.remove(at: caret - 1); caret -= 1
            case .right:
                caret = min(units.count, caret + (selection > 0 ? selection : 1))
                selection = 0
            }
            text = String(decoding: units, as: UTF16.self)
        }

        func flush() { while !pending.isEmpty { deliverNext() } }

        func physicalInput(_ value: String) {
            if barrier { physicalPending.append(value) }
            else {
                physicalDelivered.append(value)
                var units = Array(text.utf16)
                units.replaceSubrange(caret..<(caret + selection), with: value.utf16)
                caret += value.utf16.count
                selection = 0
                text = String(decoding: units, as: UTF16.self)
            }
        }

        func releasePhysicalInput() {
            barrier = false
            let held = physicalPending
            physicalPending.removeAll()
            for value in held { physicalInput(value) }
        }

        func access() -> NativeFieldAccess {
            NativeFieldAccess(validateOriginalIdentity: { _ in self.onValidate?(); return self.valid },
                cheapGate: { self.onCheapGate?(); return self.barrier }, isEditable: { limit in self.editableDeadlines.append(limit); return self.editable },
                observe: { limit in
                    self.readDeadlines.append(limit)
                    self.observeCount += 1
                    self.onObserve?()
                    guard !self.observationUnavailable else { return nil }
                    let value = self.observationOverride?(self.observeCount) ?? self.snapshot
                    self.observed.append(value)
                    return value
                }, postBatch: { operations in
                    guard self.postResponse, !(self.rejectReplacement && operations.contains(.insertReplacement)) else { return false }
                    self.batchCount += 1
                    for operation in operations {
                        self.posted.append(operation)
                        self.pending.append(operation)
                        if self.deliverImmediately { self.deliverNext() }
                        self.onPost?(operation)
                    }
                    return true
                }, cancelPreparedSelection: { deadline in
                    guard self.barrier, self.clock < deadline else { return false }
                    self.cancellationCount += 1
                    for operation: NativeFieldEditOperation in [.selectPreviousCharacter, .right] {
                        self.posted.append(operation)
                        self.pending.append(operation)
                        if self.deliverImmediately { self.deliverNext() }
                    }
                    return true
                }, now: { self.clock }, pause: { interval in
                    if !self.frozenClock { self.clock += interval }
                    self.pauseCount += 1
                    self.onPause?()
                })
        }

        func run(start: Int = 0) -> VerifiedNativeFieldEditResult {
            VerifiedNativeFieldEditor.execute(original: original, replacement: replacement, start: start,
                access: access(), onTextQueued: { self.textQueuedCount += 1 })
        }
    }

    @MainActor
    func testRealisticAXLatencyNeverLeavesMixedPrefixWhenHeldTypingResumes() {
        let field = Field()
        field.text = "ghbdtn"
        field.original = "ghbdtn"
        field.replacement = "привет"
        field.caret = 6
        field.onValidate = { field.clock += 0.0025 }
        field.onObserve = { field.clock += 0.0015 }
        let result = field.run()
        field.physicalInput("!")
        field.releasePhysicalInput()
        // The old per-pair protocol leaves exactly "ghпривет" at these latencies.
        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(field.text, "привет!")
        XCTAssertEqual(field.caret, 7)
        XCTAssertEqual(field.selection, 0)
        XCTAssertEqual(field.physicalDelivered, ["!"])
    }

    @MainActor
    func testTwoPhasesPreserveExactUnicodeNeighboursAndUseFiveWholeReads() {
        let field = Field()
        let prefix = "😀 e\u{301} "
        let suffix = " tail 🧑🏽‍💻"
        field.text = prefix + "ghbd" + suffix
        field.caret = prefix.utf16.count + 4
        field.onPost = { operation in
            XCTAssertEqual(field.observeCount, field.batchCount == 1 ? 2 : 4)
            if operation == .insertReplacement { XCTAssertEqual(field.selection, 0) }
        }
        XCTAssertEqual(field.run(start: prefix.utf16.count), .confirmed)
        XCTAssertEqual(Array(field.text.utf16), Array((prefix + "прив" + suffix).utf16))
        XCTAssertEqual(field.caret, prefix.utf16.count + 4)
        XCTAssertEqual(field.posted, Array(repeating: .selectPreviousCharacter, count: 4)
            + [.insertReplacement, .selectPreviousCharacter, .right])
        XCTAssertEqual(field.batchCount, 2)
        XCTAssertEqual(field.textQueuedCount, 1)
        XCTAssertEqual(field.observeCount, 5)
    }

    @MainActor
    func testPreparationRpcDeadlineReservesCleanupAndFinalAcknowledgementBudget() {
        let field = Field()
        XCTAssertEqual(field.run(), .confirmed)
        XCTAssertEqual(field.readDeadlines, [0.180, 0.070, 0.070, 0.070, 0.180])
        XCTAssertEqual(field.editableDeadlines, [0.180, 0.070, 0.070])
        XCTAssertEqual(field.textQueuedCount, 1)
    }

    @MainActor
    func testEveryDelayedSelectionIsAllowedToReachTheFinalWholeFieldAcknowledgement() {
        let field = Field()
        field.deliverImmediately = false
        field.onPause = { if field.pauseCount.isMultiple(of: 2) { field.deliverNext() } }
        XCTAssertEqual(field.run(), .confirmed)
        // Text can already be exact while the two non-text stabilization pairs
        // are still queued. The receipt never claims delivery of those pairs.
        XCTAssertEqual(field.pending, [.selectPreviousCharacter, .right])
        field.physicalInput("!")
        field.flush()
        XCTAssertEqual(field.posted, field.delivered)
        field.releasePhysicalInput()
        XCTAssertEqual(field.text, "прив!")
        XCTAssertEqual(field.selection, 0)
        XCTAssertEqual(field.batchCount, 2)
    }

    @MainActor
    func testLateSelectionPreparationQueuesCancellationBeforeHeldTypingWithoutText() {
        let field = Field()
        field.deliverImmediately = false
        let original = field.snapshot
        XCTAssertEqual(field.run(), .refused)
        XCTAssertEqual(field.snapshot, original)
        XCTAssertFalse(field.posted.contains(.insertReplacement))
        XCTAssertEqual(field.cancellationCount, 1)
        XCTAssertEqual(field.textQueuedCount, 0)
        field.physicalInput("!")
        field.flush()
        field.releasePhysicalInput()
        XCTAssertEqual(field.text, "ghbd!")
        XCTAssertEqual(field.selection, 0)
        XCTAssertLessThanOrEqual(field.clock, VerifiedNativeFieldEditor.maximumDuration)
    }

    @MainActor
    func testSelectionIdentityLossAtEveryPairNeverAuthorizesTextOrCleanup() {
        for pair in 1...4 {
            let field = Field()
            field.onPost = { _ in if field.posted.count == pair { field.valid = false } }
            guard case .preparationUncertain = field.run() else { return XCTFail("Identity lost before Unicode") }
            XCTAssertFalse(field.posted.contains(.insertReplacement))
            XCTAssertEqual(field.text, "ghbd")
            // The original field may keep its prepared selection. Retrying
            // cancellation after identity loss could navigate another field.
            XCTAssertEqual(field.selection, 4)
            XCTAssertEqual(field.caret, 0)
            XCTAssertEqual(field.textQueuedCount, 0)
            XCTAssertEqual(field.cancellationCount, 0)
        }
    }

    @MainActor
    func testCommittedReplacementNeverInterruptsItsCaretStabilization() {
        for pair in 5...7 {
            let field = Field()
            field.onPost = { _ in if field.posted.count == pair { field.valid = false } }
            guard case .uncertain = field.run() else { return XCTFail("Identity lost after data was queued") }
            XCTAssertEqual(field.posted.count, 7)
            XCTAssertEqual(field.text, "прив")
            XCTAssertEqual(field.selection, 0)
            XCTAssertEqual(field.caret, 4)
            XCTAssertEqual(field.textQueuedCount, 1)
            XCTAssertEqual(field.cancellationCount, 0)
        }
    }

    @MainActor
    func testSuffixTornNewTextWithOldSelectionWaitsForExactFinalReadWithoutResubmission() {
        let field = Field()
        field.observationOverride = { count in
            count == 5 ? NativeFieldObservation(text: "прив", caretUTF16Location: 0, selectionLength: 4) : nil
        }
        XCTAssertEqual(field.run(), .confirmed)
        XCTAssertEqual(field.batchCount, 2)
        XCTAssertEqual(field.posted.count, 7)
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.observeCount, 6)
        XCTAssertEqual(field.pauseCount, 1)
    }

    @MainActor
    func testFocusMoveAfterPreparationNeverQueuesCancellationIntoOtherField() {
        let field = Field()
        let other = Field()
        other.text = "KEEPB"
        other.caret = 5
        field.onPost = { _ in
            if field.posted.count == 4 { field.valid = false; field.deliveryTarget = other }
        }
        guard case .preparationUncertain = field.run() else { return XCTFail("Original focus was lost before Unicode") }
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.selection, 4)
        XCTAssertEqual(other.text, "KEEPB")
        XCTAssertTrue(other.delivered.isEmpty, "A PID-only cancellation must not navigate the newly focused field")
        XCTAssertFalse(field.posted.contains(.insertReplacement))
        XCTAssertEqual(field.textQueuedCount, 0)
        XCTAssertEqual(field.cancellationCount, 0)
    }

    @MainActor
    func testDroppedUnicodeAfterPreparedSelectionCannotDeleteOriginalOnHeldTyping() {
        let field = Field()
        field.dropFinalInsertion = true
        field.physicalInput("!")
        guard case .uncertain = field.run() else { return XCTFail("Missing Unicode cannot confirm") }
        field.flush()
        field.releasePhysicalInput()
        XCTAssertEqual(field.text, "ghbd!")
        XCTAssertEqual(field.selection, 0)
        XCTAssertEqual(field.caret, 5)
        XCTAssertEqual(field.textQueuedCount, 1) // Queue receipt is not delivery.
    }

    @MainActor
    func testDroppedFinalInsertionRemainsUncertainWithoutClaimingDeliveryOrResubmitting() {
        let field = Field()
        field.dropFinalInsertion = true
        let original = field.snapshot
        XCTAssertEqual(field.run(), .uncertain(observation: original))
        XCTAssertEqual(field.snapshot, original)
        XCTAssertEqual(field.batchCount, 2)
        XCTAssertEqual(field.posted.count, 7)
        XCTAssertLessThanOrEqual(field.clock, VerifiedNativeFieldEditor.maximumDuration)
    }

    @MainActor
    func testKnownCurrentCollapsedCaretAtZeroSkipsCancellationNavigation() {
        let field = Field()
        field.onObserve = {
            if field.observeCount == 3 { field.caret = 0; field.selection = 0 }
        }
        XCTAssertEqual(field.run(), .preparationUncertain(observation:
            NativeFieldObservation(text: "ghbd", caretUTF16Location: 0, selectionLength: 0)))
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.caret, 0)
        XCTAssertEqual(field.cancellationCount, 0)
        XCTAssertEqual(field.textQueuedCount, 0)
    }

    @MainActor
    func testCleanupThatCannotBeQueuedIsPreparationUncertainWithNoTextReceipt() {
        let field = Field()
        field.onPost = { _ in if field.batchCount == 1 { field.barrier = false } }
        guard case .preparationUncertain = field.run() else { return XCTFail("Cleanup was not queued") }
        XCTAssertFalse(field.posted.contains(.insertReplacement))
        XCTAssertEqual(field.cancellationCount, 0)
        XCTAssertEqual(field.textQueuedCount, 0)
        XCTAssertEqual(field.text, "ghbd")
    }

    @MainActor
    func testRejectedTextPhaseRestoresOriginalSelectionAndReturnsRefusedWithoutReceipt() {
        let field = Field()
        field.rejectReplacement = true
        let original = field.snapshot
        XCTAssertEqual(field.run(), .refused)
        XCTAssertEqual(field.snapshot, original)
        XCTAssertEqual(field.cancellationCount, 1)
        XCTAssertEqual(field.textQueuedCount, 0)
        XCTAssertFalse(field.posted.contains(.insertReplacement))
    }

    @MainActor
    func testPersistentWrongFinalCaretSelectionOrWholeTextIsUncertainWithoutSecondBatch() {
        for failure in 0..<3 {
            let field = Field()
            field.onPost = { operation in
                if operation == .right {
                    if failure == 0 { field.caret -= 1 }
                    if failure == 1 { field.selection = 1 }
                    if failure == 2 { field.text += "programmatic change" }
                }
            }
            XCTAssertEqual(field.run(), .uncertain(observation: field.snapshot))
            XCTAssertEqual(field.batchCount, 2)
            XCTAssertGreaterThan(field.pauseCount, 0)
            XCTAssertLessThanOrEqual(field.clock, VerifiedNativeFieldEditor.maximumDuration)
        }
    }

    @MainActor
    func testFinalReadIdentityLossCannotConfirmEvenWhenTextMatches() {
        let field = Field()
        field.onObserve = { if field.observeCount == 5 { field.valid = false } }
        guard case .uncertain = field.run() else { return XCTFail("Identity changed") }
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.batchCount, 2)
    }

    @MainActor
    func testReadThatFinishesAfterDeadlineCannotConfirm() {
        let field = Field()
        field.onObserve = { if field.observeCount == 5 { field.clock = 0.181 } }
        guard case .uncertain = field.run() else { return XCTFail("Late read") }
        XCTAssertEqual(field.posted.count, 7)
    }

    @MainActor
    func testFrozenClockAndUnavailableAcknowledgementAreBounded() {
        let field = Field()
        field.deliverImmediately = false
        field.frozenClock = true
        field.onPost = { _ in field.observationUnavailable = true }
        guard case .preparationUncertain = field.run() else { return XCTFail("Missing preparation delivery") }
        XCTAssertLessThanOrEqual(field.observeCount, VerifiedNativeFieldEditor.maximumObservations)
        XCTAssertLessThanOrEqual(field.pauseCount, VerifiedNativeFieldEditor.maximumObservations)
        XCTAssertEqual(field.batchCount, 1)
    }

    @MainActor
    func testRefusesInvalidPreflightWithoutMutation() {
        for failure in 0..<6 {
            let field = Field()
            switch failure {
            case 0: field.valid = false
            case 1: field.barrier = false
            case 2: field.editable = false
            case 3: field.text = "wrong"
            case 4: field.caret = 3
            default: field.observationUnavailable = true
            }
            XCTAssertEqual(field.run(), .refused)
            XCTAssertTrue(field.posted.isEmpty)
        }
    }

    @MainActor
    func testChangedFinalPreflightWholeTextCaretRevisionOrDeadlineNeverPosts() {
        for failure in 0..<4 {
            let field = Field()
            field.onObserve = {
                if field.observeCount == 2 {
                    if failure == 0 { field.text = "other same-PID field" }
                    if failure == 1 { field.caret = 3 }
                    if failure == 2 { field.valid = false }
                    if failure == 3 { field.clock = 0.180 }
                }
            }
            XCTAssertEqual(field.run(), .refused)
            XCTAssertTrue(field.posted.isEmpty)
        }
    }

    @MainActor
    func testRejectedBatchAdmissionMeansNoEventsAndLeavesOldText() {
        let field = Field()
        field.postResponse = false
        XCTAssertEqual(field.run(), .refused)
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.selection, 0)
        XCTAssertTrue(field.posted.isEmpty)
    }

    @MainActor
    func testCallerAbsoluteDeadlineIsNotExtendedAndClockRegressionCannotConfirm() {
        let field = Field()
        field.clock = 10
        field.deliverImmediately = false
        let result = VerifiedNativeFieldEditor.execute(original: "ghbd", replacement: "прив", start: 0,
            access: field.access(), absoluteDeadline: 10.002)
        XCTAssertEqual(result, .refused)
        XCTAssertFalse(field.posted.contains(.insertReplacement))
        XCTAssertEqual(field.cancellationCount, 1)
        XCTAssertLessThanOrEqual(field.clock, 10.002)
        let fresh = Field()
        XCTAssertEqual(VerifiedNativeFieldEditor.execute(original: "ghbd", replacement: "прив", start: 0,
            access: fresh.access(), absoluteDeadline: 1), .refused)
        XCTAssertTrue(fresh.posted.isEmpty)
        let backwards = Field()
        backwards.clock = 1
        backwards.onPost = { operation in if operation == .insertReplacement { backwards.clock = 0.9 } }
        guard case .uncertain = backwards.run() else { return XCTFail("Clock regression") }
        XCTAssertEqual(backwards.text, "прив")
    }

    @MainActor
    func testCommittedBatchQueuesAllKeyUpsEvenAfterEveryPossibleGateLossEdge() {
        for lostAfter in 0..<54 {
            var gate = true
            var checks = 0
            var edges: [Int] = []
            XCTAssertTrue(NativeFieldBatchPoster.post(eventCount: 54, mayBegin: { checks += 1; return gate }) {
                edges.append($0)
                if $0 == lostAfter { gate = false }
            })
            XCTAssertEqual(edges, Array(0..<54))
            XCTAssertEqual(checks, 1)
        }
    }

    @MainActor
    func testInvalidOrUnadmittedBatchNeverPostsAnyEdge() {
        for count in [-2, 0, 1, 3, 55, 56, Int.max] {
            var events = 0
            XCTAssertFalse(NativeFieldBatchPoster.post(eventCount: count, mayBegin: { true }) { _ in events += 1 })
            XCTAssertEqual(events, 0)
        }
        var events = 0
        XCTAssertFalse(NativeFieldBatchPoster.post(eventCount: 2, mayBegin: { false }) { _ in events += 1 })
        XCTAssertEqual(events, 0)
    }

    @MainActor
    func testLegacyPairStillReleasesItsKeyUpAfterGateDrops() {
        var gate = true
        var edges: [String] = []
        XCTAssertFalse(NativeFieldKeyPairPoster.post(mayContinue: { gate }, keyDown: {
            edges.append("down"); gate = false
        }, keyUp: { edges.append("up") }))
        XCTAssertEqual(edges, ["down", "up"])
    }
}
