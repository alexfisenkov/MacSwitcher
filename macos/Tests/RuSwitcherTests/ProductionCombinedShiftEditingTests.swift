import ApplicationServices
import XCTest
@testable import RuSwitcher

/// The production decision branch and TextConverter call the production
/// VerifiedNativeFieldEditor. Only AX, event delivery, layout and time are fake.
final class ProductionCombinedShiftEditingTests: XCTestCase {
    final class Field {
        let pid: Int32
        let element: AXUIElement
        var text: String
        var caret: Int
        var selection = 0
        var clock: TimeInterval = 1
        var valid = true
        var secure = false
        var readOnly = false
        var refuseBeforeQueue = false
        var dropInsertion = false
        var loseFocusAfterSelection = false
        var selectionPostDelay: TimeInterval = 0
        var leaseDeadline: TimeInterval = .infinity
        var queuedText = 0
        var queuedSelection = 0
        var observedCount = 0
        var subrole: (AXError, AnyObject?) = (.attributeUnsupported, nil)
        var queuedLayoutTargets: [String] = []

        init(pid: Int32, text: String, element: AXUIElement? = nil) {
            self.pid = pid
            self.element = element ?? AXUIElementCreateApplication(pid)
            self.text = text
            caret = text.utf16.count
        }

        var active: Bool { valid && clock < leaseDeadline }

        func selectedRange() -> CFRange { CFRange(location: caret, length: selection) }

        func substring(_ range: CFRange) -> String? {
            observedCount += 1
            let units = Array(text.utf16)
            guard range.location >= 0, range.length >= 0, range.location <= units.count,
                  range.length <= units.count - range.location else { return nil }
            return String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
        }

        func focus() -> CombinedShiftFocus {
            CombinedShiftFocus(processID: pid, element: element,
                initialSelection: selectedRange(), fieldBoundary: CombinedShiftFieldBoundary(
                    validationFailure: { [self] in
                        if secure { return .secureInput }
                        return valid ? nil : .focusChanged
                    },
                    selectionRange: { [self] in selectedRange() },
                    text: { [self] in substring($0) },
                    secureSubrole: { [self] in subrole }))
        }

        var observation: NativeFieldObservation {
            NativeFieldObservation(text: text, caretUTF16Location: caret, selectionLength: selection)
        }

        func insert(_ replacement: String) {
            let units = Array(text.utf16)
            let result = Array(units[..<caret]) + Array(replacement.utf16) + Array(units[(caret + selection)...])
            text = String(decoding: result, as: UTF16.self)
            caret += replacement.utf16.count
            selection = 0
        }

        func type(_ source: String) {
            insert(source)
        }

        @MainActor
        func access(replacement: String, barrier: @escaping () -> Bool) -> NativeFieldAccess {
            NativeFieldAccess(validateOriginalIdentity: { [self] _ in active && !secure },
                cheapGate: { [self] in active && barrier() },
                isEditable: { [self] _ in active && !secure && !readOnly },
                observe: { [self] _ in observedCount += 1; return active ? observation : nil },
                postBatch: { [self] operations in
                    guard active && !refuseBeforeQueue else { return false }
                    let droppedReplacementBatch = dropInsertion && operations.contains(.insertReplacement)
                    for operation in operations {
                        switch operation {
                        case .selectPreviousCharacter:
                            if droppedReplacementBatch { continue }
                            if selection == 0 { caret -= 1 } else { caret -= 1 }
                            selection += 1
                            queuedSelection += 1
                        case .insertReplacement:
                            queuedText += 1
                            if !dropInsertion { insert(replacement) }
                        case .right:
                            if droppedReplacementBatch { continue }
                            caret += selection
                            selection = 0
                        case .left:
                            if droppedReplacementBatch { continue }
                            caret = max(0, caret - 1)
                            selection = 0
                        case .backspace:
                            if caret > 0 {
                                let units = Array(text.utf16)
                                text = String(decoding: Array(units[..<(caret - 1)]) + Array(units[caret...]), as: UTF16.self)
                                caret -= 1
                            }
                        }
                    }
                    if operations.contains(.selectPreviousCharacter), !operations.contains(.insertReplacement) {
                        clock += selectionPostDelay
                        if loseFocusAfterSelection { valid = false }
                    }
                    return true
                },
                cancelPreparedSelection: { [self] _ in
                    guard active else { return false }
                    caret += selection
                    selection = 0
                    return true
                }, now: { [self] in clock }, pause: { [self] interval in clock += interval })
        }
    }

    @MainActor
    static func converter(for fields: [Field],
                          automaticRoute: @escaping (String?, String, String) -> AutomaticEditorRoute = {
                              AutomaticEditorPolicy.route(bundleID: $0, suffix: $1, sourceID: $2)
                          }) -> TextConverter {
        TextConverter(selectionPreferences: { (false, true) },
            nativeEditBoundary: { selected, original, replacement, execution, barrier, prepared, queued in
                guard let field = fields.first(where: {
                    $0.pid == execution.focus.processID && CFEqual($0.element, execution.focus.element)
                }) else { return .refused }
                let access = field.access(replacement: replacement, barrier: barrier)
                if selected {
                    return VerifiedNativeFieldEditor.executeSelection(original: original.text,
                        replacement: replacement, start: original.range.location, access: access,
                        onPrepared: prepared, onTextQueued: queued)
                }
                return VerifiedNativeFieldEditor.execute(original: original.text, replacement: replacement,
                    start: original.range.location, access: access,
                    onPrepared: prepared, onTextQueued: queued)
            }, wholeFieldObservationOverride: { focus in
                fields.first(where: {
                    $0.pid == focus.processID && CFEqual($0.element, focus.element) && $0.valid
                })?.observation
            }, automaticRoute: automaticRoute)
    }

    @MainActor
    private func layoutPair() throws -> (en: String, ru: String, enToRu: CombinedShiftContext, ruToEn: CombinedShiftContext) {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let ru = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        let enID = LayoutSwitcher.sourceID(en)
        let ruID = LayoutSwitcher.sourceID(ru)
        return (enID, ruID, CombinedShiftContext(sourceLayoutID: enID, targetLayoutID: ruID),
                CombinedShiftContext(sourceLayoutID: ruID, targetLayoutID: enID))
    }

    @MainActor
    private func type(_ text: String, source: String, monitor: KeyboardMonitor) throws {
            let language = text.unicodeScalars.allSatisfy { $0.value < 128 }
                ? KeyMapping.keycodeToEN : KeyMapping.keycodeToRU
        for character in text {
            let key = try XCTUnwrap(language.first { $0.value == character }?.key)
            monitor.handleKeyDown(keyCode: key, flags: [], renderedSourceLayoutID: source)
        }
    }

    @MainActor
    private func request(_ action: CombinedShiftGesture.Action, monitor: KeyboardMonitor,
                         field: Field, contexts: [String: CombinedShiftContext]) throws -> CombinedShiftRequest {
        try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: action,
            frontProcessID: field.pid, focus: field.focus(), contextForSource: { contexts[$0] }))
    }

    @MainActor
    private func edit(_ field: Field, monitor: KeyboardMonitor, converter: TextConverter,
                      context: CombinedShiftContext, contexts: [String: CombinedShiftContext],
                      onFailure: ((CombinedShiftFailure) -> Void)? = nil,
                      onDiagnostic: ((CombinedShiftDiagnostic) -> Void)? = nil,
                      application: CombinedShiftApplicationFamily = .other) throws -> Bool {
        let first = try request(.switchLayout(context), monitor: monitor, field: field, contexts: contexts)
        let second = try request(.convert(context), monitor: monitor, field: field, contexts: contexts)
        XCTAssertEqual(first.frontProcessID, second.frontProcessID)
        let execution = CombinedShiftExecutionContext(focus: try XCTUnwrap(second.focus),
            inputRevision: second.inputRevision, currentInputRevision: { monitor.inputRevision })
        guard execution.isValid() else { return false }
        return converter.withNativeInputBudget({
            field.leaseDeadline.isFinite ? max(0, field.leaseDeadline - field.clock) : 0.250
        }) {
            converter.withNativeTextQueuedHandler({ field.queuedLayoutTargets.append($0) }) {
                CombinedShiftEditing.perform(request: second, context: context, execution: execution,
                    converter: converter, inputBarrierIsActive: { field.active }, convertWholeLine: false,
                    contextForSource: { contexts[$0] }, onFailure: onFailure,
                    onDiagnostic: onDiagnostic, application: application)
            }
        }
    }

    @MainActor
    func testRepeatedRealConverterEditsUndoNewWordPauseAndFieldChange() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let monitor = KeyboardMonitor()
        let fieldA = Field(pid: 1001, text: "ghbdtn")
        let fieldB = Field(pid: 1002, text: "ghbdtn")
        let fieldC = Field(pid: 1015, text: "MacSwitcher levf. xnj-nj nfrjt")
        let converter = Self.converter(for: [fieldA, fieldB, fieldC])

        try type("ghbdtn", source: pair.en, monitor: monitor)
        XCTAssertTrue(try edit(fieldA, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(fieldA.text, "привет")
        monitor.markConverted()

        fieldA.type(" ")
        monitor.handleKeyDown(keyCode: KC.space, flags: [], renderedSourceLayoutID: pair.ru)
        fieldA.type("руддщ")
        try type("руддщ", source: pair.ru, monitor: monitor)
        fieldA.clock += 2
        XCTAssertTrue(try edit(fieldA, monitor: monitor, converter: converter,
            context: pair.ruToEn, contexts: contexts))
        XCTAssertEqual(fieldA.text, "привет hello")
        monitor.markConverted()

        XCTAssertTrue(try edit(fieldA, monitor: monitor, converter: converter,
            context: pair.ruToEn, contexts: contexts))
        XCTAssertEqual(fieldA.text, "привет руддщ")
        monitor.markConverted()

        fieldB.valid = true
        monitor.resetCombinedShift()
        try type("ghbdtn", source: pair.en, monitor: monitor)
        XCTAssertTrue(try edit(fieldB, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(fieldB.text, "привет")
        XCTAssertEqual(fieldA.text, "привет руддщ")

        fieldC.caret = 0
        fieldC.selection = fieldC.text.utf16.count
        monitor.resetCombinedShift()
        XCTAssertTrue(try edit(fieldC, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(fieldC.text, "MacSwitcher думаю что-то такое")
        XCTAssertEqual(fieldB.text, "привет")
    }

    @MainActor
    func testPrioritySelectionUsesRealConverterAndPreservesCorrectName() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let monitor = KeyboardMonitor()
        let field = Field(pid: 1003, text: "ghbdtn MacSwitcher")
        field.caret = 0
        field.selection = field.text.utf16.count
        let converter = Self.converter(for: [field])

        XCTAssertTrue(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.text, "привет MacSwitcher")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(field.queuedSelection, 0)
    }

    @MainActor
    func testManualSelectionCanCorrectWordBesideProtectedTechnicalPath() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let field = Field(pid: 1014, text: "ghbdtn /tmp/project")
        field.caret = 0
        field.selection = field.text.utf16.count
        let converter = Self.converter(for: [field])

        XCTAssertTrue(try edit(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.text, "привет /tmp/project")
    }

    @MainActor
    func testCorrectNameSelectionLeavesFieldUntouched() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let field = Field(pid: 1006, text: "MacSwitcher")
        field.caret = 0
        field.selection = field.text.utf16.count
        let converter = Self.converter(for: [field])

        XCTAssertFalse(try edit(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.text, "MacSwitcher")
        XCTAssertEqual(field.queuedText, 0)
    }

    @MainActor
    func testExactOwnerMixedSelectionThroughProductionHandler() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let field = Field(pid: 1007, text: "MacSwitcher levf. xnj-nj nfrjt")
        field.caret = 0
        field.selection = field.text.utf16.count
        let converter = Self.converter(for: [field])
        var diagnostics: [CombinedShiftDiagnostic] = []

        XCTAssertTrue(try edit(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.enToRu, contexts: contexts, onDiagnostic: { diagnostics.append($0) },
            application: .textEdit))
        XCTAssertEqual(field.text, "MacSwitcher думаю что-то такое")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(diagnostics, [CombinedShiftDiagnostic(application: .textEdit,
            operation: .selection, result: .confirmed)])
    }

    @MainActor
    func testRefusalBeforeQueueAndUnknownAfterQueueNeverBlindlyReplay() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let monitor = KeyboardMonitor()
        let field = Field(pid: 1004, text: "ghbdtn")
        let converter = Self.converter(for: [field])
        try type("ghbdtn", source: pair.en, monitor: monitor)

        field.refuseBeforeQueue = true
        XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)

        field.refuseBeforeQueue = false
        field.dropInsertion = true
        XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: field.focus()))
        converter.clearState()
        field.clock += 20
        XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: field.focus()))
        XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(converter.unconfirmedOriginals.first?.text, "ghbdtn")

        field.text = "external"
        field.caret = field.text.utf16.count
        field.selection = 0
        XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.text, "external")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: field.focus()))
        XCTAssertEqual(converter.unconfirmedOriginals.first?.text, "ghbdtn")
    }

    @MainActor
    func testPreparationOnlyFailureDoesNotQuarantineFreshExplicitSelection() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let field = Field(pid: 1020, text: "ghbdtn")
        let converter = Self.converter(for: [field])
        let firstMonitor = KeyboardMonitor()
        try type("ghbdtn", source: pair.en, monitor: firstMonitor)
        field.loseFocusAfterSelection = true

        XCTAssertFalse(try edit(field, monitor: firstMonitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)
        XCTAssertTrue(converter.unconfirmedOriginals.isEmpty)

        field.valid = true
        field.loseFocusAfterSelection = false
        let freshMonitor = KeyboardMonitor()
        XCTAssertTrue(try edit(field, monitor: freshMonitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.text, "привет")
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testEightPreparationOnlyFailuresDoNotExhaustRecoverySlotsForNinthField() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let fields = (0..<9).map { Field(pid: Int32(1030 + $0), text: "ghbdtn") }
        let converter = Self.converter(for: fields)
        for field in fields.prefix(8) {
            let monitor = KeyboardMonitor()
            try type("ghbdtn", source: pair.en, monitor: monitor)
            field.loseFocusAfterSelection = true
            XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
                context: pair.enToRu, contexts: contexts))
            XCTAssertEqual(field.queuedText, 0)
        }
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)
        XCTAssertTrue(converter.unconfirmedOriginals.isEmpty)

        let ninth = fields[8]
        let freshMonitor = KeyboardMonitor()
        try type("ghbdtn", source: pair.en, monitor: freshMonitor)
        XCTAssertTrue(try edit(ninth, monitor: freshMonitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(ninth.text, "привет")
        XCTAssertEqual(ninth.queuedText, 1)
    }

    @MainActor
    func testExactOriginalReadbackAfterQueuedUnknownStaysQuarantined() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let monitor = KeyboardMonitor()
        let field = Field(pid: 1012, text: "ghbdtn")
        let converter = Self.converter(for: [field])
        try type("ghbdtn", source: pair.en, monitor: monitor)
        field.dropInsertion = true

        XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: field.focus()))
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.selection, 6)
        let queuedBeforeRecovery = field.queuedText

        XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.queuedText, queuedBeforeRecovery, "Exact read-back must not queue a no-op replacement")
        XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: field.focus()),
            "An unchanged original cannot prove that queued Unicode will never arrive")
        XCTAssertEqual(converter.unconfirmedOriginals.first?.text, "ghbdtn")

        field.dropInsertion = false
        XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.queuedText, queuedBeforeRecovery)
        XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: field.focus()))
    }

    @MainActor
    func testNearExpiredLeaseRefusesBeforeSelectingOriginal() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let monitor = KeyboardMonitor()
        let field = Field(pid: 1005, text: "ghbdtn")
        let converter = Self.converter(for: [field])
        try type("ghbdtn", source: pair.en, monitor: monitor)
        field.leaseDeadline = field.clock + 0.010
        field.selectionPostDelay = 0.015

        XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts))
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.queuedSelection, 0, "Unsafe remaining lease must refuse before selecting text")
        XCTAssertEqual(field.selection, 0)
        XCTAssertEqual(field.queuedText, 0)
    }

    @MainActor
    func testSecureReadOnlyAndLostFocusNeverQueueReplacement() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        for pid in [1008, 1009, 1010] {
            let field = Field(pid: Int32(pid), text: "ghbdtn")
            let converter = Self.converter(for: [field])
            let monitor = KeyboardMonitor()
            try type("ghbdtn", source: pair.en, monitor: monitor)
            field.secure = pid == 1008
            field.readOnly = pid == 1009
            field.loseFocusAfterSelection = pid == 1010
            XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
                context: pair.enToRu, contexts: contexts))
            XCTAssertEqual(field.text, "ghbdtn")
            XCTAssertEqual(field.queuedText, 0)
            if field.secure || field.readOnly { XCTAssertEqual(field.observedCount, 0) }
        }
    }

    func testMissingLexiconEvidenceDoesNotAuthorizeAutomaticMutation() {
        let unavailable = PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: ["en": [:], "ru": [:]]))
        XCTAssertNil(unavailable.evaluate(suffix: "ghbdtn", sourceLanguage: "en"))
        XCTAssertNil(unavailable.evaluate(suffix: "f привет", sourceLanguage: "ru"))
    }

    @MainActor
    func testRefusalProvidesUserReasonAndRecoveryRouteWithoutFocusingWindow() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let monitor = KeyboardMonitor()
        let field = Field(pid: 1011, text: "ghbdtn")
        field.dropInsertion = true
        let converter = Self.converter(for: [field])
        try type("ghbdtn", source: pair.en, monitor: monitor)
        var reported: [CombinedShiftFailure] = []

        XCTAssertFalse(try edit(field, monitor: monitor, converter: converter,
            context: pair.enToRu, contexts: contexts, onFailure: { reported.append($0) }))
        XCTAssertEqual(reported, [.unconfirmedEdit])
        XCTAssertNotNil(reported.first?.userMessage)
        XCTAssertTrue(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testBothShiftSidesImmediateSoloThenOriginalDirectionForDouble() throws {
        let pair = try layoutPair()
        for side in [CombinedShiftGesture.Side.left, .right] {
            var gesture = CombinedShiftGesture()
            gesture.press(side, at: 0, context: pair.enToRu)
            XCTAssertEqual(gesture.release(side, at: 20_000_000), .switchLayout(pair.enToRu))
            gesture.press(side, at: 120_000_000, context: pair.ruToEn)
            XCTAssertEqual(gesture.release(side, at: 180_000_000), .convert(pair.enToRu))
            gesture.press(side, at: 500_000_000, context: pair.ruToEn)
            XCTAssertEqual(gesture.release(side, at: 520_000_000), .switchLayout(pair.ruToEn))
            gesture.press(side, at: 681_000_000, context: pair.enToRu)
            XCTAssertEqual(gesture.release(side, at: 701_000_000), .switchLayout(pair.enToRu))
        }
    }

    func testDiagnosticApplicationFamilyContainsNoTypedContent() {
        XCTAssertEqual(CombinedShiftApplicationFamily.classify(bundleID: "com.apple.TextEdit"), .textEdit)
        XCTAssertEqual(CombinedShiftApplicationFamily.classify(bundleID: "com.openai.codex"), .codex)
        XCTAssertEqual(CombinedShiftApplicationFamily.classify(bundleID: "com.google.Chrome"), .browser)
        XCTAssertEqual(CombinedShiftApplicationFamily.classify(bundleID: "user.private.editor"), .other)
    }

    @MainActor
    func testCaretAndRevisionDriftBeforeWriteRefuseWithoutQueuing() throws {
        let pair = try layoutPair()
        let contexts = [pair.en: pair.enToRu, pair.ru: pair.ruToEn]
        let monitor = KeyboardMonitor()
        let field = Field(pid: 1013, text: "ghbdtn")
        let converter = Self.converter(for: [field])
        try type("ghbdtn", source: pair.en, monitor: monitor)
        _ = try request(.switchLayout(pair.enToRu), monitor: monitor, field: field, contexts: contexts)
        let captured = try request(.convert(pair.enToRu), monitor: monitor, field: field, contexts: contexts)
        let focus = try XCTUnwrap(captured.focus)
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: captured.inputRevision,
            currentInputRevision: { monitor.inputRevision })

        field.caret = 5
        XCTAssertFalse(CombinedShiftEditing.perform(request: captured, context: pair.enToRu,
            execution: execution, converter: converter, inputBarrierIsActive: { field.active },
            convertWholeLine: false, contextForSource: { contexts[$0] }))
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.queuedSelection, 0)
        XCTAssertEqual(field.queuedText, 0)

        field.caret = 6
        monitor.resetCombinedShift()
        XCTAssertFalse(execution.isValid())
        XCTAssertEqual(field.queuedText, 0)
    }

    func testPredictionEarlyContextAmbiguityAndTechnicalRefusals() throws {
        let lexicon = PredictionLexicon(wordsByLanguage: [
            "ru": ["привет": 1_000_000, "думаю": 800_000, "что-то": 600_000,
                   "такое": 500_000, "а": 8_000_000],
            "en": ["hello": 900_000, "press": 500_000, "f": 20_000]
        ])
        let engine = PredictionEngine(lexicon: lexicon)
        XCTAssertEqual(engine.evaluate(suffix: "ghbdtn", sourceLanguage: "en")?.replacementSuffix, "привет")
        XCTAssertEqual(engine.evaluate(suffix: "ghbd", sourceLanguage: "en")?.replacementSuffix, "прив")
        XCTAssertNil(engine.evaluate(suffix: "ghb", sourceLanguage: "en"))
        XCTAssertNil(engine.evaluate(suffix: "f", sourceLanguage: "en"))
        XCTAssertNil(engine.evaluate(suffix: "f ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(engine.evaluate(suffix: "f привет", sourceLanguage: "ru")?.replacementSuffix, "а привет")
        XCTAssertNil(engine.evaluate(suffix: "press f привет", sourceLanguage: "ru"))
        XCTAssertNil(engine.evaluate(suffix: "MacSwitcher", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine.evaluate(suffix: "API", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine.evaluate(suffix: "https://example.org", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine.evaluate(suffix: "/tmp/ghbdtn", sourceLanguage: "en", atBoundary: true))
        XCTAssertNil(engine.evaluate(suffix: "Ctrl+f", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(engine.evaluate(suffix: "levf.", sourceLanguage: "en", atBoundary: true)?.replacementSuffix,
                       "думаю")
        XCTAssertEqual(engine.evaluate(suffix: "xnj-nj", sourceLanguage: "en", atBoundary: true)?.replacementSuffix,
                       "что-то")
        XCTAssertEqual(engine.evaluate(suffix: "nfrjt", sourceLanguage: "en", atBoundary: true)?.replacementSuffix,
                       "такое")
    }
}
