import XCTest
@testable import RuSwitcher

final class VerifiedNativeFieldEditorTests: XCTestCase {
    @MainActor
    private final class Field {
        var text = "ghbd"
        var caret = 4
        var selection = 0
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
        var deliverImmediately = true
        var postResponse = true
        var onPost: ((NativeFieldEditOperation) -> Void)?
        var onObserve: (() -> Void)?
        var onPause: (() -> Void)?
        var onValidate: (() -> Void)?
        var onCheapGate: (() -> Void)?
        var observationUnavailable = false
        var replacement = "прив"
        var physicalPending: [String] = []
        var physicalDelivered: [String] = []

        var snapshot: NativeFieldObservation {
            NativeFieldObservation(text: text, caretUTF16Location: caret, selectionLength: selection)
        }

        func deliverNext() {
            guard !pending.isEmpty else { return }
            let operation = pending.removeFirst()
            delivered.append(operation)
            var units = Array(text.utf16)
            switch operation {
            case .insertReplacement:
                units.insert(contentsOf: replacement.utf16, at: caret)
                caret += replacement.utf16.count
            case .left: caret -= 1
            case .backspace:
                guard caret > 0 else { return }
                units.remove(at: caret - 1)
                caret -= 1
            case .right: caret += 1
            }
            text = String(decoding: units, as: UTF16.self)
        }

        func physicalInput(_ value: String) {
            if barrier { physicalPending.append(value) }
            else { physicalDelivered.append(value) }
        }

        func releasePhysicalInput() {
            barrier = false
            physicalDelivered += physicalPending
            physicalPending.removeAll()
        }

        func access() -> NativeFieldAccess {
            NativeFieldAccess(validateOriginalIdentity: { _ in self.onValidate?(); return self.valid },
                cheapGate: { self.onCheapGate?(); return self.barrier }, isEditable: { self.editable },
                observe: {
                    self.observeCount += 1
                    self.onObserve?()
                    guard !self.observationUnavailable else { return nil }
                    let value = self.snapshot
                    self.observed.append(value)
                    return value
                }, post: { operation in
                    self.posted.append(operation)
                    self.pending.append(operation)
                    if self.deliverImmediately { self.deliverNext() }
                    self.onPost?(operation)
                    return self.postResponse
                }, now: { self.clock }, pause: { interval in
                    if !self.frozenClock { self.clock += interval }
                    self.pauseCount += 1
                    self.onPause?()
                })
        }

        func run(start: Int = 0) -> VerifiedNativeFieldEditResult {
            VerifiedNativeFieldEditor.execute(original: "ghbd", replacement: replacement, start: start, access: access())
        }
    }

    @MainActor
    func testConfirmedPacesEveryPairWithExactReadbackAndPreservesUnicodeNeighbours() {
        let field = Field()
        let prefix = "😀 e\u{301} "
        let suffix = " tail 🧑🏽‍💻"
        field.text = prefix + "ghbd" + suffix
        field.caret = prefix.utf16.count + 4
        var previousWasObserved = true
        field.onPost = { operation in
            XCTAssertTrue(previousWasObserved)
            previousWasObserved = false
            if operation == .backspace { XCTAssertTrue(field.observed.contains { $0.text == prefix + "ghbdприв" + suffix && $0.caretUTF16Location == prefix.utf16.count + 4 }) }
        }
        field.onObserve = { previousWasObserved = true }
        XCTAssertEqual(field.run(start: prefix.utf16.count), .confirmed)
        XCTAssertEqual(Array(field.text.utf16), Array((prefix + "прив" + suffix).utf16))
        XCTAssertEqual(field.caret, prefix.utf16.count + 4)
        XCTAssertEqual(field.posted, [.insertReplacement] + Array(repeating: .left, count: 4)
            + Array(repeating: .backspace, count: 4) + Array(repeating: .right, count: 4))
        XCTAssertEqual(field.pending.count, 0)
    }

    @MainActor
    func testUndeliveredInsertionNeverQueuesNavigationOrDeletionAndReturnsActualState() {
        let field = Field()
        field.deliverImmediately = false
        XCTAssertEqual(field.run(), .uncertain(observation: field.snapshot))
        XCTAssertEqual(field.posted, [.insertReplacement])
        XCTAssertEqual(field.delivered, [])
        XCTAssertEqual(field.pending, [.insertReplacement])
        XCTAssertLessThanOrEqual(field.clock, VerifiedNativeFieldEditor.maximumDuration)
    }

    @MainActor
    func testDelayedNavigationMustBeAcknowledgedBeforeAnotherPairOrDeletion() {
        let field = Field()
        field.deliverImmediately = false
        field.onPost = { operation in
            XCTAssertEqual(field.pending.count, 1)
            if operation == .backspace { XCTAssertEqual(field.caret, 4 - field.posted.filter { $0 == .backspace }.count + 1) }
        }
        field.onPause = { if field.pauseCount.isMultiple(of: 2) { field.deliverNext() } }
        XCTAssertEqual(field.run(), .confirmed)
        XCTAssertEqual(field.posted, field.delivered)
        XCTAssertEqual(field.text, "прив")
    }

    @MainActor
    func testWrongCaretAndNonCollapsedReadbackStopImmediatelyWithoutDeletion() {
        for nonCollapsed in [false, true] {
            let field = Field()
            field.onPost = { operation in
                if operation == .insertReplacement {
                    if nonCollapsed { field.selection = 1 } else { field.caret -= 1 }
                }
            }
            XCTAssertEqual(field.run(), .uncertain(observation: field.snapshot))
            XCTAssertEqual(field.posted, [.insertReplacement])
            XCTAssertEqual(field.pauseCount, 0)
        }
    }

    @MainActor
    func testPartialDeletionKeepsActualObservedWholeStateAndNeverRetries() {
        let field = Field()
        var deletionCount = 0
        field.onPost = { operation in
            if operation == .backspace { deletionCount += 1 }
            if deletionCount == 2 { field.postResponse = false }
        }
        let result = field.run()
        XCTAssertEqual(field.text, "ghприв")
        XCTAssertEqual(result, .uncertain(observation: field.snapshot))
        XCTAssertEqual(field.posted.filter { $0 == .backspace }.count, 2)
        XCTAssertFalse(field.posted.contains(.right))
    }

    @MainActor
    func testSamePIDProgrammaticWholeFieldChangeCannotAuthorizeAnotherWrite() {
        let field = Field()
        field.onPost = { if $0 == .left { field.text = "other field same PID" } }
        XCTAssertEqual(field.run(), .uncertain(observation: field.snapshot))
        XCTAssertEqual(field.posted, [.insertReplacement, .left])
        XCTAssertFalse(field.posted.contains(.backspace))
    }

    @MainActor
    func testGateLossOrIdentityLossAfterInsertionStopsWithoutAdditionalPair() {
        for gateLoss in [false, true] {
            let field = Field()
            field.onPost = { _ in if gateLoss { field.barrier = false } else { field.valid = false } }
            guard case .uncertain = field.run() else { return XCTFail("Mutation must remain uncertain") }
            XCTAssertEqual(field.posted, [.insertReplacement])
        }
    }

    @MainActor
    func testIdentityLossDuringReadCannotAuthorizeNavigation() {
        let field = Field()
        field.onObserve = { if field.text == "ghbdприв" { field.valid = false } }
        guard case .uncertain = field.run() else { return XCTFail("Identity changed") }
        XCTAssertEqual(field.posted, [.insertReplacement])
    }

    @MainActor
    func testDeadlineSharedAcrossAllStepsAndNoWriteOrRetryAfterExpiry() {
        let field = Field()
        field.onPost = { if $0 == .left { field.clock = 0.180 } }
        guard case .uncertain = field.run() else { return XCTFail("Expired mutation") }
        XCTAssertEqual(field.posted, [.insertReplacement, .left])
        XCTAssertEqual(field.pauseCount, 0)
    }

    @MainActor
    func testReadThatCompletesAfterDeadlineCannotAuthorizeNextPair() {
        let field = Field()
        field.onObserve = { if field.text == "ghbdприв" { field.clock = 0.181 } }
        guard case .uncertain = field.run() else { return XCTFail("Late read") }
        XCTAssertEqual(field.posted, [.insertReplacement])
    }

    @MainActor
    func testFrozenClockAndUnavailableObservationAreBounded() {
        let field = Field()
        field.deliverImmediately = false
        field.frozenClock = true
        guard case .uncertain = field.run() else { return XCTFail("Missing delivery") }
        XCTAssertLessThanOrEqual(field.observeCount, VerifiedNativeFieldEditor.maximumObservations)
        XCTAssertLessThanOrEqual(field.pauseCount, VerifiedNativeFieldEditor.maximumObservations)
        XCTAssertEqual(field.posted, [.insertReplacement])
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
    func testPhysicalInputModelRemainsPendingUntilCallerReleasesFenceAfterConfirmation() {
        let field = Field()
        field.physicalInput("before")
        field.onPost = { _ in field.physicalInput("during") }
        XCTAssertEqual(field.run(), .confirmed)
        field.physicalInput("after text confirmation, before source confirmation")
        XCTAssertEqual(field.physicalDelivered, [])
        XCTAssertEqual(field.physicalPending.count, 15)
        field.releasePhysicalInput()
        XCTAssertEqual(field.physicalDelivered.count, 15)
        XCTAssertEqual(field.physicalPending, [])
    }
    @MainActor
    func testPostedKeyDownAlwaysReceivesKeyUpWhenGateDrops() {
        var gate = true
        var edges: [String] = []
        XCTAssertFalse(NativeFieldKeyPairPoster.post(mayContinue: { gate }, keyDown: {
            edges.append("down")
            gate = false
        }, keyUp: { edges.append("up") }))
        XCTAssertEqual(edges, ["down", "up"])
        XCTAssertFalse(NativeFieldKeyPairPoster.post(mayContinue: { gate }, keyDown: {
            edges.append("unexpected down")
        }, keyUp: { edges.append("unexpected up") }))
        XCTAssertEqual(edges, ["down", "up"])
    }

    @MainActor
    func testCallerAbsoluteDeadlineIsNotExtendedByPreflightOrRetries() {
        let field = Field()
        field.clock = 10
        field.deliverImmediately = false
        let result = VerifiedNativeFieldEditor.execute(original: "ghbd", replacement: "прив", start: 0,
            access: field.access(), absoluteDeadline: 10.002)
        guard case .uncertain = result else { return XCTFail("Undelivered insertion") }
        XCTAssertEqual(field.posted, [.insertReplacement])
        XCTAssertLessThanOrEqual(field.clock, 10.002)
        let fresh = Field()
        XCTAssertEqual(VerifiedNativeFieldEditor.execute(original: "ghbd", replacement: "прив", start: 0,
            access: fresh.access(), absoluteDeadline: 1), .refused)
        XCTAssertTrue(fresh.posted.isEmpty)
    }

    @MainActor
    func testClockMovingBackwardsAfterInsertionStopsWithoutNavigation() {
        let field = Field()
        field.clock = 1
        field.onPost = { _ in field.clock = 0.9 }
        guard case .uncertain = field.run() else { return XCTFail("Clock regression") }
        XCTAssertEqual(field.posted, [.insertReplacement])
    }

    @MainActor
    func testDeadlineCrossedInsideLastCheapGateCannotPostFirstPair() {
        let field = Field()
        var gatesAfterSecondRead = 0
        field.onCheapGate = {
            if field.observeCount == 2 {
                gatesAfterSecondRead += 1
                if gatesAfterSecondRead == 4 { field.clock = 0.180 }
            }
        }
        XCTAssertEqual(field.run(), .refused)
        XCTAssertTrue(field.posted.isEmpty)
    }

}
