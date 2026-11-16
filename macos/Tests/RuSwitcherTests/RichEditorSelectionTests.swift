import ApplicationServices
import XCTest
@testable import RuSwitcher

/// A contenteditable can expose formatted AXValue and flat AXStringForRange.
/// These tests exercise the production manual transaction with only AX/HID/TIS faked.
final class RichEditorSelectionTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field

    func testFullMonotonicProjectionMapsOnlySingleParagraphSelection() throws {
        let projection = try XCTUnwrap(NativeSelectedTextProjection(formatted: "A\nB\nC", flat: "ABC"))
        XCTAssertEqual(projection.selectedFormattedStart(rawRange: CFRange(location: 1, length: 1),
            byRange: "B", byAttribute: "B"), 2)
        XCTAssertNil(projection.selectedFormattedStart(rawRange: CFRange(location: 0, length: 2),
            byRange: "AB", byAttribute: "AB"))
        XCTAssertNil(projection.unambiguousFormattedCaret(rawLocation: 1))
        XCTAssertEqual(projection.unambiguousFormattedCaret(rawLocation: 3), 5)
        XCTAssertNil(NativeSelectedTextProjection(formatted: "A\nB\nC", flat: "AXC"))
        XCTAssertNil(NativeSelectedTextProjection(formatted: "longvalue", flat: "x"))
        XCTAssertNil(NativeSelectedTextProjection(formatted: "A\nB\nC", flat: ""))
        XCTAssertNil(NativeSelectedTextProjection(formatted: "A", flat: "much longer"))
    }

    func testProjectionNeverFindsFirstRepeatedWordBySubstring() throws {
        let projection = try XCTUnwrap(NativeSelectedTextProjection(
            formatted: "ghbdtn\nghbdtn Z", flat: "ghbdtnghbdtn Z"))
        XCTAssertEqual(projection.selectedFormattedStart(rawRange: CFRange(location: 6, length: 6),
            byRange: "ghbdtn", byAttribute: "ghbdtn"), 7)
        XCTAssertNil(projection.selectedFormattedStart(rawRange: CFRange(location: 5, length: 6),
            byRange: "nghbdt", byAttribute: "ghbdtn"))
    }

    @MainActor
    func testCoincidentValueSliceStillResolvesCompleteRichCoordinateStream() throws {
        let field = Field(pid: 8829, text: "A\nAAAA")
        field.caret = field.text.utf16.count
        let rawStart = 2
        XCTAssertEqual(field.substring(CFRange(location: rawStart, length: 3)), "AAA",
            "The wrong formatted position coincidentally has the same repeated text")
        let focus = richFocus(field)
        guard case .projected(let mapped, let needsWitness) = focus.nativeCollapsedCoordinateResolution(
            observation(field), rawStart: rawStart, original: "AAA",
            prepareRead: { true }) else {
            XCTFail("Complete marker stream must determine the position"); return
        }
        XCTAssertEqual(mapped, 3)
        XCTAssertFalse(needsWitness)
    }

    @MainActor
    private func directions() throws -> (en: String, ru: String, context: CombinedShiftContext) {
        let layouts = LayoutSwitcher.installedLayouts()
        let english = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let russian = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        let en = LayoutSwitcher.sourceID(english)
        let ru = LayoutSwitcher.sourceID(russian)
        return (en, ru, CombinedShiftContext(sourceLayoutID: en, targetLayoutID: ru))
    }

    private func flatSubstring(_ text: String, _ range: CFRange) -> String? {
        let units = Array(text.replacingOccurrences(of: "\n", with: "").utf16)
        guard range.location >= 0, range.length >= 0, range.location <= units.count,
              range.length <= units.count - range.location else { return nil }
        return String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
    }

    @MainActor
    private func rawCaret(_ field: Field) -> Int {
        Array(field.text.utf16.prefix(field.caret)).filter { $0 != 0x000A }.count
    }

    @MainActor
    private func observation(_ field: Field) -> NativeFieldObservation {
        NativeFieldObservation(text: field.text, caretUTF16Location: rawCaret(field),
            selectionLength: field.selection)
    }

    @MainActor
    private func syntheticParagraphProof(_ field: Field)
        -> (CFRange, String, String, NativeParagraphBoundaryWitness.Side) -> Bool {
        { raw, flat, leaf, side in
            let units = Array(field.text.utf16)
            guard flat == field.text.replacingOccurrences(of: "\n", with: ""),
                  raw.location == self.rawCaret(field),
                  raw.length == field.selection,
                  field.caret >= 0, field.caret <= units.count else { return false }
            let paragraphStart = (units[..<field.caret].lastIndex(of: 0x000A) ?? -1) + 1
            var paragraphEnd = paragraphStart
            while paragraphEnd < units.count && units[paragraphEnd] != 0x000A { paragraphEnd += 1 }
            let actualLeaf = String(decoding: units[paragraphStart..<paragraphEnd], as: UTF16.self)
            guard leaf == actualLeaf, !leaf.isEmpty else { return false }
            switch side {
            case .selectedLeafStart:
                return field.selection > 0 && field.caret == paragraphStart
                    && field.substring(CFRange(location: field.caret,
                        length: field.selection)).map { leaf.hasPrefix($0) } == true
            case .selectedWholeLeaf:
                return field.selection == leaf.utf16.count && field.caret == paragraphStart
            case .collapsedLeafEnd:
                return field.selection == 0 && field.caret == paragraphEnd
            }
        }
    }

    @MainActor
    private func richFocus(_ field: Field, selectedText: (() -> String?)? = nil,
                           fullTextContent: (() -> String?)? = nil,
                           fullMarkerRange: (() -> Bool)? = nil,
                           fullMarkerText: (() -> String?)? = nil,
                           readAdmission: (() -> Bool)? = nil,
                           paragraphBoundaryProof: ((CFRange, String, String,
                               NativeParagraphBoundaryWitness.Side) -> Bool)? = nil) -> CombinedShiftFocus {
        CombinedShiftFocus(processID: field.pid, element: field.element,
            initialSelection: CFRange(location: rawCaret(field), length: field.selection),
            fieldBoundary: CombinedShiftFieldBoundary(
                validationFailure: { field.valid ? nil : .focusChanged },
                selectionRange: { CFRange(location: self.rawCaret(field), length: field.selection) },
                text: { range in self.flatSubstring(field.text, range) },
                secureSubrole: { field.subrole },
                fullTextContent: fullTextContent ?? {
                    field.text.replacingOccurrences(of: "\n", with: "")
                },
                selectedText: selectedText ?? {
                    field.substring(CFRange(location: field.caret, length: field.selection))
                }, fullMarkerRange: fullMarkerRange,
                fullMarkerText: fullMarkerText,
                readAdmission: readAdmission,
                nativeEditability: { field.valid && !field.readOnly && !field.secure },
                paragraphBoundaryProof: paragraphBoundaryProof,
                nativeWholeObservation: { self.observation(field) },
                valueText: { field.text }))
    }

    @MainActor
    private func converter(_ field: Field, convertByText: Bool = false,
                           smartConversion: Bool = true,
                           beforeNativeObservation: (() -> Void)? = nil,
                           beforeNativePost: (() -> Void)? = nil,
                           afterNativePost: (() -> Void)? = nil) -> TextConverter {
        TextConverter(selectionPreferences: { (convertByText, smartConversion) }, nativeEditBoundary: {
            selected, original, replacement, execution, barrier, prepared, queued, formattedStart,
            requiresEndpointWitness, allowCoordinateResolution, onResolvedFormattedStart in
            let base = field.access(replacement: replacement, barrier: barrier)
            var textWasQueued = false
            var hasNativeObservation = false
            var preparedObservation: NativeFieldObservation?
            var activeFormattedStart = formattedStart
            var activeRequiresEndpointWitness = requiresEndpointWitness
            var coordinateResolved = formattedStart != nil || selected
                || !allowCoordinateResolution
            func contract() -> NativeProjectedReadContract? {
                activeFormattedStart.map {
                    NativeProjectedReadContract(rawStart: original.range.location,
                        formattedStart: $0, original: original.text, replacement: replacement,
                        replacingSelection: selected,
                        requiresEndpointWitness: activeRequiresEndpointWitness)
                }
            }
            let access = NativeFieldAccess(validateOriginalIdentity: base.validateOriginalIdentity,
                cheapGate: base.cheapGate, isEditable: base.isEditable,
                observe: { deadline in
                    if !hasNativeObservation {
                        hasNativeObservation = true
                        beforeNativeObservation?()
                    }
                    guard base.observe(deadline) != nil else { return nil }
                    let observed = self.observation(field)
                    if !coordinateResolved {
                        guard let resolution = execution.focus.nativeCollapsedCoordinateResolution(
                            observed, rawStart: original.range.location,
                            original: original.text,
                            prepareRead: { base.cheapGate() }) else { return nil }
                        coordinateResolved = true
                        if case .projected(let mapped, let needsStartWitness) = resolution {
                            activeFormattedStart = mapped
                            activeRequiresEndpointWitness = needsStartWitness
                            onResolvedFormattedStart(mapped)
                        }
                    }
                    guard let contract = contract() else { return observed }
                    return execution.focus.nativeProjectedObservation(observed,
                        contract: contract, textBatchQueued: textWasQueued,
                        phaseDeadline: ProcessInfo.processInfo.systemUptime + 0.180,
                        prepareRead: { base.cheapGate() })
                }, postBatch: { operations in
                    beforeNativePost?()
                    if activeRequiresEndpointWitness && operations.contains(.insertReplacement) {
                        guard base.validateOriginalIdentity(field.clock + 0.180),
                            let preparedObservation, let contract = contract(),
                            execution.focus.nativeProjectedPrequeueProof(
                                prepared: preparedObservation, contract: contract,
                            phaseDeadline: ProcessInfo.processInfo.systemUptime + 0.180,
                            prepareRead: { base.cheapGate() }),
                            base.validateOriginalIdentity(field.clock + 0.180) else { return false }
                    }
                    let posted = base.postBatch(operations)
                    if posted && operations.contains(.insertReplacement) { textWasQueued = true }
                    if posted { afterNativePost?() }
                    return posted
                },
                cancelPreparedSelection: base.cancelPreparedSelection, now: base.now, pause: base.pause)
            if selected {
                return VerifiedNativeFieldEditor.executeSelection(original: original.text,
                    replacement: replacement, start: original.range.location, access: access,
                    onPrepared: { observed in
                        preparedObservation = observed
                        prepared(observed)
                    }, onTextQueued: queued, formattedStart: formattedStart)
            }
            return VerifiedNativeFieldEditor.execute(original: original.text,
                replacement: replacement, start: original.range.location, access: access,
                onPrepared: { observed in
                    preparedObservation = observed
                    prepared(observed)
                }, onTextQueued: queued, formattedStart: formattedStart,
                resolvedFormattedStart: { activeFormattedStart })
        }, wholeFieldObservationOverride: { _ in self.observation(field) })
    }

    @MainActor
    private func run(_ field: Field, monitor: KeyboardMonitor, converter: TextConverter,
                     context: CombinedShiftContext, sourceID: String,
                     firstFocus: CombinedShiftFocus? = nil,
                     beforeTransactionObservation: (() -> Void)? = nil,
                     sourceBeforeTransactionObservation: String? = nil)
        throws -> CombinedShiftTransaction.Result {
        let contexts = [context.sourceLayoutID: context, context.targetLayoutID: context.reversed]
        let focus = firstFocus ?? richFocus(field)
        _ = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .switchLayout(context),
            frontProcessID: field.pid, focus: focus, contextForSource: { contexts[$0] }))
        let request = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .convert(context),
            frontProcessID: field.pid, focus: field.focus(), contextForSource: { contexts[$0] }))
        let execution = CombinedShiftExecutionContext(focus: try XCTUnwrap(request.focus),
            inputRevision: request.inputRevision, currentInputRevision: { monitor.inputRevision })
        let fence = InputEventFence()
        var currentSource = sourceID
        var observedTransaction = false
        let platform = CombinedShiftTransaction.Platform(
            currentSourceID: { currentSource }, frontProcessID: { field.pid },
            secureInputActive: { field.secure },
            beginLease: { fence.begin(processID: $0, maximumDuration: 0.250) },
            leaseIsCurrent: { fence.isCurrent($0) }, leaseRemaining: { fence.remainingDuration($0) },
            finishLease: { fence.finish($0, replayLayoutID: $1) }, pendingSourceTargetID: { nil },
            selectSource: { currentSource = $0; return .confirmed },
            noteUnconfirmedSource: { _, _ in },
            observeWholeField: { focus in
                if !observedTransaction {
                    observedTransaction = true
                    beforeTransactionObservation?()
                    if let sourceBeforeTransactionObservation {
                        currentSource = sourceBeforeTransactionObservation
                    }
                }
                let current = CombinedShiftExecutionContext(focus: focus,
                    inputRevision: request.inputRevision, currentInputRevision: { monitor.inputRevision })
                return converter.nativeSelectionBaseline(execution: current)?.field
            }, applicationFamily: { .other })
        return CombinedShiftTransaction.run(request: request, context: context,
            execution: execution, converter: converter, monitor: monitor, platform: platform,
            convertWholeLine: false, contextForSource: { contexts[$0] }, diagnosticsEnabled: false)
    }

    @MainActor
    func testFormattedMultilineSelectedWordSurvivesFlatRangeDisagreement() throws {
        let pair = try directions()
        let field = Field(pid: 8801, text: "🙂\nghbdtn Z")
        field.caret = "🙂\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))

        XCTAssertEqual(result.outcome, .confirmed(resultID: pair.ru))
        XCTAssertEqual(field.text, "🙂\nпривет Z")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testFinalParagraphRepeatedWordRoundTripsWithExactFormattedSource() throws {
        let pair = try directions()
        let field = Field(pid: 8802, text: "ghbdtn\n🙂 ghbdtn")
        let secondStart = "ghbdtn\n🙂 ".utf16.count
        field.caret = secondStart
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)
        let monitor = KeyboardMonitor()

        let first = try run(field, monitor: monitor, converter: converter,
            context: pair.context, sourceID: pair.ru,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
        XCTAssertEqual(first.outcome, .confirmed(resultID: pair.ru))
        XCTAssertEqual(field.text, "ghbdtn\n🙂 привет")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(converter.confirmedNativeField?.before.text, "ghbdtn\n🙂 ghbdtn")
        XCTAssertEqual(converter.confirmedNativeField?.after.text, "ghbdtn\n🙂 привет")

        field.caret = secondStart
        field.selection = "привет".utf16.count
        let undo = try run(field, monitor: monitor, converter: converter,
            context: pair.context.reversed, sourceID: pair.en,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
        XCTAssertEqual(undo.outcome, .confirmed(resultID: pair.en))
        XCTAssertEqual(field.text, "ghbdtn\n🙂 ghbdtn")
        XCTAssertEqual(field.queuedText, 2)
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testInternalParagraphEndRefusesBeforePostingText() throws {
        let pair = try directions()
        let field = Field(pid: 8803, text: "A\nghbdtn\nC")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.text, "A\nghbdtn\nC")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testAmbiguousStartWithoutLeafMarkerRefusesBeforeUnicode() throws {
        let pair = try directions()
        let field = Field(pid: 8827, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.text, "A\nghbdtn Z")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testAmbiguousStartMarkerAnchoredToPreviousParagraphRefuses() throws {
        let pair = try directions()
        let field = Field(pid: 8828, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)
        var startProofs = 0
        let focus = richFocus(field, paragraphBoundaryProof: { _, _, _, side in
            if case .selectedLeafStart = side { startProofs += 1 }
            // The actual marker belongs to the previous paragraph.
            return false
        })

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru, firstFocus: focus)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(startProofs, 1)
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(field.text, "A\nghbdtn Z")
    }

    @MainActor
    func testWitnessedCompleteInternalParagraphAndTrailingEmptyParagraph() throws {
        let pair = try directions()
        let sourceLeaf = "ghbdtn rfr ltkf"
        let resultLeaf = "привет как дела"
        for (index, suffix) in ["\nC", "\n"].enumerated() {
            let field = Field(pid: Int32(8820 + index), text: "A\n" + sourceLeaf + suffix)
            field.caret = "A\n".utf16.count
            field.selection = sourceLeaf.utf16.count
            var selectedProofs = 0
            var collapsedProofs = 0
            let focus = richFocus(field, paragraphBoundaryProof: { raw, flat, leaf, side in
                guard flat == field.text.replacingOccurrences(of: "\n", with: "") else { return false }
                switch side {
                case .selectedWholeLeaf:
                    selectedProofs += 1
                    return raw.location == 1 && raw.length == leaf.utf16.count
                        && (leaf == sourceLeaf || leaf == resultLeaf)
                case .selectedLeafStart:
                    return false
                case .collapsedLeafEnd:
                    collapsedProofs += 1
                    return raw.location == 1 + leaf.utf16.count && raw.length == 0
                        && (leaf == sourceLeaf || leaf == resultLeaf)
                }
            })
            let converter = converter(field, convertByText: true, smartConversion: false)
            let monitor = KeyboardMonitor()

            let first = try run(field, monitor: monitor, converter: converter,
                context: pair.context, sourceID: pair.ru, firstFocus: focus)
            XCTAssertEqual(first.outcome, .confirmed(resultID: pair.ru))
            XCTAssertEqual(field.text, "A\n" + resultLeaf + suffix)
            XCTAssertEqual(field.queuedText, 1)
            XCTAssertGreaterThanOrEqual(selectedProofs, 2)
            XCTAssertGreaterThanOrEqual(collapsedProofs, 1)
            XCTAssertFalse(converter.hasUnconfirmedAXEdit)

            let undo = try run(field, monitor: monitor, converter: converter,
                context: pair.context.reversed, sourceID: pair.en,
                firstFocus: richFocus(field, paragraphBoundaryProof: focus.fieldBoundary?.paragraphBoundaryProof))
            XCTAssertEqual(undo.outcome, .confirmed(resultID: pair.en),
                "selectedProofs=\(selectedProofs) collapsedProofs=\(collapsedProofs) queuedSelection=\(field.queuedSelection)")
            XCTAssertEqual(field.text, "A\n" + sourceLeaf + suffix)
            XCTAssertEqual(field.queuedText, 2)
        }
    }

    @MainActor
    func testWitnessInvalidatedAtPrequeueRefusesWithoutUnicode() throws {
        let pair = try directions()
        let field = Field(pid: 8822, text: "A\nghbdtn\nC")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        var witnessAllowed = true
        let focus = richFocus(field, paragraphBoundaryProof: { _, _, _, _ in witnessAllowed })
        let converter = converter(field, beforeNativePost: { witnessAllowed = false })

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru, firstFocus: focus)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(field.text, "A\nghbdtn\nC")
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testWitnessLostAfterQueueRetainsCompleteFormattedSource() throws {
        let pair = try directions()
        let field = Field(pid: 8823, text: "A\nghbdtn\nC")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let focus = richFocus(field, paragraphBoundaryProof: { _, _, _, side in
            if case .collapsedLeafEnd = side { return false }
            return true
        })
        let converter = converter(field)

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru, firstFocus: focus)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(field.text, "A\nпривет\nC")
        XCTAssertEqual(converter.unconfirmedOriginals.first?.text, "A\nghbdtn\nC")
        XCTAssertTrue(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testExternalWholeValueChangeAfterQueuedWitnessKeepsOriginal() throws {
        let pair = try directions()
        let field = Field(pid: 8824, text: "A\nghbdtn\nC")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let focus = richFocus(field, paragraphBoundaryProof: { _, _, _, _ in true })
        let converter = converter(field, afterNativePost: { field.text += "!" })

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru, firstFocus: focus)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(field.text, "A\nпривет\nC!")
        XCTAssertEqual(converter.unconfirmedOriginals.first?.text, "A\nghbdtn\nC")
        XCTAssertTrue(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testConflictingSelectedPayloadRefusesBeforePostingText() throws {
        let pair = try directions()
        let field = Field(pid: 8804, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)
        let focus = richFocus(field, selectedText: { "different" })

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru, firstFocus: focus)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(field.text, "A\nghbdtn Z")
    }

    @MainActor
    func testFailedCompleteMarkerReadNeverDowngradesToRangeOnly() throws {
        let pair = try directions()
        let field = Field(pid: 8805, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)
        let focus = richFocus(field, fullTextContent: { nil })

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru, firstFocus: focus)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(field.text, "A\nghbdtn Z")
    }

    @MainActor
    func testReadGateClosingAfterMarkerRangeSkipsMarkerTextAndWrite() throws {
        let pair = try directions()
        let field = Field(pid: 8813, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)
        var gate = true
        var rangeReads = 0
        var markerTextReads = 0
        var selectedReads = 0
        let focus = richFocus(field, selectedText: {
            selectedReads += 1
            return "ghbdtn"
        }, fullMarkerRange: {
            rangeReads += 1
            gate = false
            return true
        }, fullMarkerText: {
            markerTextReads += 1
            return "Aghbdtn Z"
        }, readAdmission: { gate })

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru, firstFocus: focus)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(rangeReads, 1)
        XCTAssertEqual(markerTextReads, 0)
        XCTAssertEqual(selectedReads, 0)
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(field.text, "A\nghbdtn Z")
    }

    @MainActor
    func testFlatRepresentationChangingWhileValueStaysSameRefusesBeforeQueue() throws {
        let pair = try directions()
        let field = Field(pid: 8814, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)
        var markerReads = 0
        let focus = richFocus(field, fullMarkerRange: { true }, fullMarkerText: {
            markerReads += 1
            return markerReads == 1 ? "Aghbdtn Z" : "Aghbdtn Y"
        }, paragraphBoundaryProof: syntheticParagraphProof(field))

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru, firstFocus: focus)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertGreaterThanOrEqual(markerReads, 2)
        XCTAssertEqual(field.text, "A\nghbdtn Z")
        XCTAssertEqual(field.queuedText, 0)
    }

    @MainActor
    func testCollapsedCaretConvertsFinalRepeatedWordAndImmediatelyReverses() throws {
        let pair = try directions()
        let field = Field(pid: 8806, text: "ghbdtn\nghbdtn")
        field.caret = field.text.utf16.count
        field.selection = 0
        let converter = converter(field)
        let monitor = KeyboardMonitor()

        let first = try run(field, monitor: monitor, converter: converter,
            context: pair.context, sourceID: pair.ru,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
        XCTAssertEqual(first.outcome, .confirmed(resultID: pair.ru))
        XCTAssertEqual(field.text, "ghbdtn\nпривет")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(converter.confirmedNativeField?.before.text, "ghbdtn\nghbdtn")

        let reverse = try run(field, monitor: monitor, converter: converter,
            context: pair.context.reversed, sourceID: pair.en,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
        XCTAssertEqual(reverse.outcome, .confirmed(resultID: pair.en))
        XCTAssertEqual(field.text, "ghbdtn\nghbdtn")
        XCTAssertEqual(field.queuedText, 2)
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testTypedBufferWordAtRichFinalParagraphUsesPairedCoordinates() throws {
        let pair = try directions()
        let field = Field(pid: 8826, text: "lead\nghbdtn")
        field.caret = field.text.utf16.count
        field.selection = 0
        let converter = converter(field)
        let monitor = KeyboardMonitor()
        for character in "ghbdtn" {
            let code = try XCTUnwrap(KeyMapping.keycodeToEN.first { $0.value == character }?.key)
            monitor.handleKeyDown(keyCode: code, flags: [], renderedSourceLayoutID: pair.en)
        }

        let first = try run(field, monitor: monitor, converter: converter,
            context: pair.context, sourceID: pair.ru,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
        XCTAssertEqual(first.outcome, .confirmed(resultID: pair.ru))
        XCTAssertEqual(field.text, "lead\nпривет")
        XCTAssertEqual(field.queuedText, 1)

        let undo = try run(field, monitor: monitor, converter: converter,
            context: pair.context.reversed, sourceID: pair.en,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
        XCTAssertEqual(undo.outcome, .confirmed(resultID: pair.en))
        XCTAssertEqual(field.text, "lead\nghbdtn")
        XCTAssertEqual(field.queuedText, 2)
    }

    @MainActor
    func testCollapsedInteriorWordPreservesExistingSuffix() throws {
        let pair = try directions()
        let field = Field(pid: 8807, text: "A ghbdtn Z")
        field.caret = "A ghbdtn".utf16.count
        field.selection = 0
        let converter = converter(field)

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru)
        XCTAssertEqual(result.outcome, .confirmed(resultID: pair.ru))
        XCTAssertEqual(field.text, "A привет Z")
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testSameRangeExternalFieldChangeRefusesBeforeQueue() throws {
        let pair = try directions()
        let field = Field(pid: 8808, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)),
            beforeTransactionObservation: { field.text = "A\nghbdtn Y" })
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.text, "A\nghbdtn Y")
        XCTAssertEqual(field.queuedText, 0)
    }

    @MainActor
    func testUnrelatedSuffixChangesOnlyAtTransportInitialReadRefusesWithoutPackets() throws {
        let pair = try directions()
        let field = Field(pid: 8825, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field, beforeNativeObservation: {
            field.text = "A\nghbdtn Y"
        })

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.text, "A\nghbdtn Y")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(field.queuedSelection, 0)
        XCTAssertFalse(converter.hasUnconfirmedAXEdit)
    }

    @MainActor
    func testSourceChangeAfterPreparationRefusesBeforeQueue() throws {
        let pair = try directions()
        let field = Field(pid: 8809, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        let converter = converter(field)

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)),
            sourceBeforeTransactionObservation: pair.en)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.text, "A\nghbdtn Z")
        XCTAssertEqual(field.queuedText, 0)
    }

    @MainActor
    func testEntireFinalParagraphPhraseReversesWithoutReselectAndRedoes() throws {
        let pair = try directions()
        let source = "ghbdtn rfr ltkf lead/🙂\nghbdtn rfr ltkf"
        let prefix = "ghbdtn rfr ltkf lead/🙂\n"
        for (index, byText) in [false, true].enumerated() {
            let field = Field(pid: Int32(8811 + index), text: source)
            field.caret = prefix.utf16.count
            field.selection = "ghbdtn rfr ltkf".utf16.count
            let converter = converter(field, convertByText: byText,
                smartConversion: !byText)
            let monitor = KeyboardMonitor()

            let first = try run(field, monitor: monitor, converter: converter,
                context: pair.context, sourceID: pair.ru,
                firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
            XCTAssertEqual(first.outcome, .confirmed(resultID: pair.ru))
            XCTAssertEqual(field.text, prefix + "привет как дела")
            XCTAssertEqual(field.queuedText, 1)

            let undo = try run(field, monitor: monitor, converter: converter,
                context: pair.context.reversed, sourceID: pair.en,
                firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
            XCTAssertEqual(undo.outcome, .confirmed(resultID: pair.en))
            XCTAssertEqual(field.text, source)
            XCTAssertEqual(field.queuedText, 2)

            let redo = try run(field, monitor: monitor, converter: converter,
                context: pair.context, sourceID: pair.ru,
                firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
            XCTAssertEqual(redo.outcome, .confirmed(resultID: pair.ru))
            XCTAssertEqual(field.text, prefix + "привет как дела")
            XCTAssertEqual(field.queuedText, 3)
            XCTAssertFalse(converter.hasUnconfirmedAXEdit)
        }
    }

    @MainActor
    func testUnknownPostRetainsFormattedOriginalAndBlocksReplay() throws {
        let pair = try directions()
        let field = Field(pid: 8810, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        field.dropInsertion = true
        let converter = converter(field)
        let monitor = KeyboardMonitor()

        let first = try run(field, monitor: monitor, converter: converter,
            context: pair.context, sourceID: pair.ru,
            firstFocus: richFocus(field, paragraphBoundaryProof: syntheticParagraphProof(field)))
        XCTAssertEqual(first.outcome, .stopped)
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(field.text, "A\nghbdtn Z")
        XCTAssertEqual(converter.unconfirmedOriginals.first?.text, "A\nghbdtn Z")
        XCTAssertTrue(converter.hasUnconfirmedAXEdit)

        field.dropInsertion = false
        let second = try run(field, monitor: monitor, converter: converter,
            context: pair.context, sourceID: pair.ru)
        XCTAssertEqual(second.outcome, .stopped)
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(field.text, "A\nghbdtn Z")
    }

    @MainActor
    func testRichSelectionSecureReadOnlyAndExpiredLeaseRefuseWithoutWrite() throws {
        let pair = try directions()
        for kind in 0..<3 {
            let field = Field(pid: Int32(8815 + kind), text: "A\nghbdtn Z")
            field.caret = "A\n".utf16.count
            field.selection = "ghbdtn".utf16.count
            switch kind {
            case 0: field.subrole = (.success, kAXSecureTextFieldSubrole as NSString)
            case 1: field.readOnly = true
            default: field.leaseDeadline = field.clock
            }
            let converter = converter(field)
            let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
                context: pair.context, sourceID: pair.ru)
            XCTAssertEqual(result.outcome, .stopped)
            XCTAssertEqual(field.text, "A\nghbdtn Z")
            XCTAssertEqual(field.queuedText, 0)
            XCTAssertFalse(converter.hasUnconfirmedAXEdit)
        }
    }

    @MainActor
    func testNoneditableDocumentNeverStartsFullMarkerProbe() throws {
        let pair = try directions()
        let field = Field(pid: 8818, text: "A\nghbdtn Z")
        field.caret = "A\n".utf16.count
        field.selection = "ghbdtn".utf16.count
        field.readOnly = true
        let converter = converter(field)
        var markerReads = 0
        let focus = richFocus(field, fullMarkerRange: {
            markerReads += 1
            return true
        }, fullMarkerText: { "Aghbdtn Z" })

        let result = try run(field, monitor: KeyboardMonitor(), converter: converter,
            context: pair.context, sourceID: pair.ru, firstFocus: focus)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(markerReads, 0)
        XCTAssertEqual(field.queuedText, 0)
    }
}
