import ApplicationServices
import XCTest
@testable import RuSwitcher

final class ProductionPredictionCoordinatorTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field

    @MainActor
    private final class Rig {
        let monitor = KeyboardMonitor()
        let fields: [Field]
        let englishID: String
        let russianID: String
        let engine: PredictionEngine
        var currentField: Field
        var sourceID: String
        var remainingBudget: TimeInterval = 0.250
        var activeLease: InputEventFence.Lease?
        var generation: UInt64 = 0
        var sourceSelections: [String] = []
        var sourceOutcome: LayoutSelectionCommit.Outcome = .confirmed
        var sourceFailures: [(target: String, outcome: LayoutSelectionCommit.Outcome?, leaseReleased: Bool)] = []
        var applied: [String] = []
        var unknownNotices = 0
        var onApplication: (() -> Void)?

        lazy var converter = ProductionCombinedShiftEditingTests.converter(for: fields,
            automaticRoute: { _, _, _ in .nativeVerified })

        lazy var platform = PredictionCoordinatorPlatform(
            frontmost: { [unowned self] in ("com.apple.TextEdit", currentField.pid) },
            currentLayoutID: { [unowned self] in sourceID },
            route: { _, _, _ in .nativeVerified }, deniedApp: { _ in false },
            autoSwitchEnabled: { true }, autoConvertEnabled: { true }, remoteDeferred: { false },
            secureInputActive: { [unowned self] in currentField.secure },
            captureFocus: { [unowned self] pid in pid == currentField.pid ? currentField.focus() : nil },
            focusIsCurrent: { [unowned self] focus in
                currentField.pid == focus.processID && currentField.valid
                    && CFEqual(currentField.element, focus.element)
            },
            beginLease: { [unowned self] pid in
                guard activeLease == nil, !monitor.hasPendingInputSourceTransition else { return nil }
                generation &+= 1
                let lease = InputEventFence.Lease(generation: generation, processID: pid)
                activeLease = lease
                return lease
            },
            leaseIsCurrent: { [unowned self] lease in activeLease == lease && remainingBudget > 0 },
            leaseRemaining: { [unowned self] lease in activeLease == lease ? remainingBudget : nil },
            finishLease: { [unowned self] lease, _ in
                if activeLease == lease { activeLease = nil }
            },
            selectSource: { [unowned self] target in
                sourceSelections.append(target)
                if sourceOutcome == .confirmed { sourceID = target }
                return sourceOutcome
            }, sourceRequestedAt: { DispatchTime.now().uptimeNanoseconds },
            noteUnconfirmedSource: { [unowned self] target, at in
                monitor.noteUnconfirmedInputSource(target, requestedAt: at)
            })

        lazy var coordinator: PredictionCoordinator = {
            let value = PredictionCoordinator(monitor: monitor, converter: converter, platform: platform, engine: engine)
            value.onApplied = { [unowned self] word in
                applied.append(word)
                onApplication?()
            }
            value.onUnconfirmedEdit = { [unowned self] in unknownNotices += 1 }
            value.onSourceFailure = { [unowned self] target, outcome in
                sourceFailures.append((target, outcome, activeLease == nil))
            }
            monitor.onPredictionInput = { [weak value] in value?.submit($0) }
            monitor.onPredictionInvalidated = { [weak value] in value?.invalidate() }
            return value
        }()

        init(fields: [Field], englishID: String, russianID: String) {
            self.fields = fields
            self.englishID = englishID
            self.russianID = russianID
            currentField = fields[0]
            sourceID = englishID
            let lexicon = PredictionLexicon(wordsByLanguage: [
                "ru": ["привет": 1_000_000, "думаю": 800_000, "что-то": 600_000,
                       "такое": 500_000, "а": 8_000_000],
                "en": ["hello": 900_000, "press": 500_000, "f": 20_000]
            ])
            engine = PredictionEngine(lexicon: lexicon)
        }

        func deliver(_ text: String, to field: Field? = nil, source: String? = nil) {
            let destination = field ?? currentField
            destination.type(text)
            monitor.recordPredictionText(text, processID: destination.pid, sourceLayoutID: source ?? sourceID)
        }

        func deliverPhysicalEnglishKeys(_ raw: String) {
            for character in raw {
                if character == " " { deliver(" "); continue }
                guard let key = KeyMapping.keycodeToEN.first(where: { $0.value == character })?.key else {
                    preconditionFailure("Missing synthetic key mapping")
                }
                let rendered = sourceID == englishID ? character : (KeyMapping.keycodeToRU[key] ?? character)
                deliver(String(rendered), source: sourceID)
            }
        }
    }

    @MainActor
    private func layoutIDs() throws -> (en: String, ru: String) {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let ru = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        return (LayoutSwitcher.sourceID(en), LayoutSwitcher.sourceID(ru))
    }

    @MainActor
    private func spin(_ seconds: TimeInterval = 0.16) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    @MainActor
    func testRealSubmitEvaluateAppliesEarlyThenContinuesNextWordAndNewField() throws {
        let pair = try layoutIDs()
        let a = Field(pid: 2011, text: "")
        let b = Field(pid: 2011, text: "", element: AXUIElementCreateSystemWide())
        XCTAssertFalse(CFEqual(a.element, b.element))
        let rig = Rig(fields: [a, b], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator

        rig.deliver("ghbd")
        spin()
        XCTAssertEqual(a.text, "прив")
        XCTAssertEqual(a.queuedText, 1)
        XCTAssertEqual(rig.sourceID, pair.ru)

        rig.deliver("ет")
        spin()
        XCTAssertEqual(a.text, "привет")
        rig.deliver(" ")
        rig.deliver("руддщ")
        spin()
        XCTAssertEqual(a.text, "привет hello")
        XCTAssertEqual(a.queuedText, 2)

        rig.currentField = b
        rig.sourceID = pair.en
        rig.monitor.resetPredictionContext()
        rig.deliver("ghbdtn")
        spin()
        XCTAssertEqual(b.text, "привет")
        XCTAssertEqual(a.text, "привет hello")
        XCTAssertEqual(rig.applied.count, 3)
    }

    @MainActor
    func testRealSubmitNearExpiryRefusesBeforeSelectionAndUnknownNeverReplays() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2013, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.remainingBudget = 0.010
        rig.deliver("ghbd")
        spin()
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.queuedSelection, 0)
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertFalse(rig.converter.hasUnconfirmedAXEdit)

        rig.monitor.resetPredictionContext()
        field.text = ""
        field.caret = 0
        field.selection = 0
        rig.remainingBudget = 0.250
        field.dropInsertion = true
        rig.deliver("ghbd")
        spin()
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))
        XCTAssertEqual(rig.converter.unconfirmedOriginals.first?.text, "ghbd")
        XCTAssertEqual(rig.unknownNotices, 1)
        rig.deliver("!")
        spin()
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testDeferredCoordinatorRejectsFieldSwitchAndSecureInputBeforeWrite() throws {
        let pair = try layoutIDs()
        let a = Field(pid: 2014, text: "")
        let b = Field(pid: 2014, text: "", element: AXUIElementCreateSystemWide())
        XCTAssertFalse(CFEqual(a.element, b.element))
        let rig = Rig(fields: [a, b], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.deliver("ghbd")
        rig.currentField = b
        spin()
        XCTAssertEqual(a.text, "ghbd")
        XCTAssertEqual(a.queuedText, 0)
        XCTAssertEqual(b.queuedText, 0)

        rig.currentField = a
        rig.monitor.resetPredictionContext()
        a.secure = true
        rig.deliver("ghbd")
        spin()
        XCTAssertEqual(a.queuedText, 0)
        XCTAssertEqual(rig.applied.count, 0)
    }

    @MainActor
    func testExactOwnerExampleAsSuccessiveAutomaticWordSnapshots() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2016, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator

        rig.deliver("MacSwitcher ", source: pair.en)
        spin()
        XCTAssertEqual(field.text, "MacSwitcher ")
        XCTAssertEqual(field.queuedText, 0)

        rig.deliverPhysicalEnglishKeys("levf.")
        spin()
        rig.deliver(" ")
        spin()
        XCTAssertEqual(field.text, "MacSwitcher думаю ")

        // After automatic source selection, the same physical keys render in
        // Russian. No extra user Shift or expected-result paste is injected.
        rig.deliverPhysicalEnglishKeys("xnj-nj")
        spin()
        rig.deliver(" ")
        spin()
        XCTAssertEqual(field.text, "MacSwitcher думаю что-то ")

        rig.deliverPhysicalEnglishKeys("nfrjt")
        spin()
        XCTAssertEqual(field.text, "MacSwitcher думаю что-то такое")
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testConfirmedAutomaticTextWithRefusedSourceExplainsAndPreservesUndo() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2017, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.sourceOutcome = .refused

        rig.deliver("ghbd")
        spin()
        XCTAssertEqual(field.text, "прив", "Text ACK is independent of source refusal")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(rig.converter.hasReconversionState)
        XCTAssertFalse(rig.monitor.keysTypedSinceConversion,
            "Confirmed text must establish undo state even if TIS selection fails")
        XCTAssertEqual(rig.sourceFailures.count, 1)
        XCTAssertEqual(rig.sourceFailures.first?.target, pair.ru)
        XCTAssertEqual(rig.sourceFailures.first?.outcome, .refused)
        XCTAssertEqual(rig.sourceFailures.first?.leaseReleased, true)
        XCTAssertNotNil(CombinedShiftFailure.sourceNotConfirmed.userMessage)
        XCTAssertEqual(field.queuedText, 1, "Source repair never resends Unicode")
    }

    @MainActor
    func testUnconfirmedAutomaticSourceBlocksUntilActualTargetObservedThenNextWordWorks() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2018, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.sourceOutcome = .unconfirmed

        rig.deliver("ghbd")
        spin()
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(rig.monitor.hasPendingInputSourceTransition)
        XCTAssertEqual(rig.sourceFailures.count, 1)
        XCTAssertEqual(rig.sourceFailures.first?.outcome, .unconfirmed)
        XCTAssertEqual(rig.sourceFailures.first?.leaseReleased, true)

        rig.monitor.recordObservedInputSource(pair.en)
        XCTAssertTrue(rig.monitor.hasPendingInputSourceTransition,
            "Observing the old source cannot clear a pending requested target")
        rig.sourceID = pair.ru // synthetic fresh TIS read-back after explicit user selection
        rig.monitor.recordObservedInputSource(rig.sourceID)
        XCTAssertFalse(rig.monitor.hasPendingInputSourceTransition)

        rig.sourceOutcome = .confirmed
        rig.deliver("ет ")
        spin()
        rig.deliver("руддщ")
        spin()
        XCTAssertEqual(field.text, "привет hello")
        XCTAssertEqual(field.queuedText, 2)
    }
}
