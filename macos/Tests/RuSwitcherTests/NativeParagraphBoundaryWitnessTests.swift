import ApplicationServices
import XCTest
@testable import RuSwitcher

final class NativeParagraphBoundaryWitnessTests: XCTestCase {
    private final class Reader: NativeParagraphBoundaryReader {
        enum RangeKind: Equatable { case field, selected, leaf, prefix(Int) }
        struct Range { let kind: RangeKind; let start: Int; let end: Int }

        var supported = true
        var fieldText = "ABC"
        var selectedText = "B"
        var leafText = "B"
        var prefixText = "A"
        var selectedStart = 10
        var selectedEnd = 11
        var startOwner = 2
        var endOwner = 2
        var leafParent = 1
        var nestedParent: Int? = nil
        var intermediateSafe = false
        var leafStart = 10
        var leafEnd = 11
        var leafRole = kAXStaticTextRole
        var textReads: [RangeKind] = []
        var gateOpen = true
        var dropGateAfterSelectedRange = false

        func supports(field: Int) -> Bool { gateOpen && supported && field == 1 }
        func selectedRange(of field: Int) -> Range? {
            guard gateOpen, field == 1 else { return nil }
            let result = Range(kind: .selected, start: selectedStart, end: selectedEnd)
            if dropGateAfterSelectedRange { gateOpen = false }
            return result
        }
        func range(for element: Int, within field: Int) -> Range? {
            guard gateOpen, field == 1 else { return nil }
            switch element {
            case 1: return Range(kind: .field, start: 0, end: 100)
            case 2: return Range(kind: .leaf, start: leafStart, end: leafEnd)
            default: return nil
            }
        }
        func range(between first: Int, and second: Int, within field: Int) -> Range? {
            guard gateOpen, field == 1 else { return nil }
            if first == 0 { return Range(kind: .prefix(second), start: first, end: second) }
            return Range(kind: .selected, start: min(first, second), end: max(first, second))
        }
        func start(of range: Range) -> Int? { range.start }
        func end(of range: Range) -> Int? { range.end }
        func element(for marker: Int, within field: Int) -> Int? {
            guard gateOpen, field == 1 else { return nil }
            if marker == selectedStart { return startOwner }
            if marker == selectedEnd { return endOwner }
            return nil
        }
        func parent(of element: Int) -> Int? {
            guard gateOpen else { return nil }
            if element == 2 { return leafParent }
            if element == 3 { return nestedParent }
            return nil
        }
        func safeIntermediate(_ element: Int) -> Bool { gateOpen && element == 3 && intermediateSafe }
        func role(of element: Int) -> String? { gateOpen && element == 2 ? leafRole : nil }
        func text(in range: Range, within field: Int) -> String? {
            guard gateOpen, field == 1 else { return nil }
            textReads.append(range.kind)
            switch range.kind {
            case .field: return fieldText
            case .selected: return selectedStart == selectedEnd ? "" : selectedText
            case .leaf: return leafText
            case .prefix: return prefixText
            }
        }
    }

    private func selected(_ reader: Reader, raw: CFRange = CFRange(location: 1, length: 1),
                          flat: String = "ABC", leaf: String = "B") -> Bool {
        NativeParagraphBoundaryWitness.prove(field: 1, rawRange: raw,
            expectedFlat: flat, expectedLeafText: leaf,
            expectedSide: .selectedWholeLeaf, reader: reader)
    }

    func testCompleteInnerParagraphRequiresBothLeafEndpointsAndFlatPrefix() {
        let reader = Reader()
        XCTAssertTrue(selected(reader))
        XCTAssertEqual(reader.textReads, [.field, .selected, .leaf, .prefix(10)])
    }

    func testAmbiguousStartAllowsOnlyActualBeginningOfPartialLeaf() {
        let reader = Reader()
        reader.fieldText = "ABxx"
        reader.leafText = "Bxx"
        XCTAssertTrue(NativeParagraphBoundaryWitness.prove(field: 1,
            rawRange: CFRange(location: 1, length: 1), expectedFlat: "ABxx",
            expectedLeafText: "Bxx", expectedSide: .selectedLeafStart, reader: reader))
        XCTAssertEqual(reader.textReads, [.field, .leaf, .selected, .prefix(10)])
    }

    func testAmbiguousStartOnPreviousSiblingRefusesEvenWhenFlatPayloadMatches() {
        let reader = Reader()
        reader.fieldText = "ABxx"
        reader.leafText = "Bxx"
        reader.startOwner = 3  // end of A, while the numeric flat slice is B
        XCTAssertFalse(NativeParagraphBoundaryWitness.prove(field: 1,
            rawRange: CFRange(location: 1, length: 1), expectedFlat: "ABxx",
            expectedLeafText: "Bxx", expectedSide: .selectedLeafStart, reader: reader))
        XCTAssertEqual(reader.textReads, [.field])
    }

    func testAmbiguousStartRequiresExactLeafPrefixAndFieldPrefix() {
        let reader = Reader()
        reader.fieldText = "ABxx"
        reader.leafText = "Bxx"
        reader.prefixText = "X"
        XCTAssertFalse(NativeParagraphBoundaryWitness.prove(field: 1,
            rawRange: CFRange(location: 1, length: 1), expectedFlat: "ABxx",
            expectedLeafText: "Bxx", expectedSide: .selectedLeafStart, reader: reader))
        reader.prefixText = "A"
        reader.selectedText = "X"
        XCTAssertFalse(NativeParagraphBoundaryWitness.prove(field: 1,
            rawRange: CFRange(location: 1, length: 1), expectedFlat: "ABxx",
            expectedLeafText: "Bxx", expectedSide: .selectedLeafStart, reader: reader))
    }

    func testRepeatedParagraphBindsMarkerToNumericOffsetByExactPrefix() {
        let reader = Reader()
        reader.fieldText = "ABB"
        reader.prefixText = "AB"
        XCTAssertTrue(selected(reader, raw: CFRange(location: 2, length: 1), flat: "ABB"))
        reader.prefixText = "A"
        XCTAssertFalse(selected(reader, raw: CFRange(location: 2, length: 1), flat: "ABB"))
    }

    func testForeignLeafRefusesBeforeSelectedOrLeafTextRead() {
        let reader = Reader()
        reader.leafParent = 3
        XCTAssertFalse(selected(reader))
        XCTAssertEqual(reader.textReads, [.field])
    }

    func testDifferentLeafWrongEndAndMissingCapabilityRefuse() {
        let other = Reader()
        other.endOwner = 3
        XCTAssertFalse(selected(other))
        let wrongEnd = Reader()
        wrongEnd.leafEnd = 12
        XCTAssertFalse(selected(wrongEnd))
        let unsupported = Reader()
        unsupported.supported = false
        XCTAssertFalse(selected(unsupported))
        XCTAssertTrue(unsupported.textReads.isEmpty)
    }

    func testNestedEditableOrDocumentCannotBorrowOuterFieldProof() {
        let reader = Reader()
        reader.leafParent = 3
        reader.nestedParent = 1
        XCTAssertFalse(selected(reader))
        XCTAssertEqual(reader.textReads, [.field])
        reader.intermediateSafe = true
        XCTAssertTrue(selected(reader))
    }

    func testGateLossAfterSelectedMarkerRequestRefusesBeforeLeafText() {
        let reader = Reader()
        reader.dropGateAfterSelectedRange = true
        XCTAssertFalse(selected(reader))
        XCTAssertEqual(reader.textReads, [.field])
    }

    func testCollapsedPostWriteCaretMustBeLeafEndAndSameFlatPrefix() {
        let reader = Reader()
        reader.fieldText = "AприветC"
        reader.leafText = "привет"
        reader.prefixText = "Aпривет"
        reader.selectedStart = 11
        reader.selectedEnd = 11
        XCTAssertTrue(NativeParagraphBoundaryWitness.prove(field: 1,
            rawRange: CFRange(location: 7, length: 0), expectedFlat: "AприветC",
            expectedLeafText: "привет", expectedSide: .collapsedLeafEnd, reader: reader))
        reader.leafEnd = 12
        XCTAssertFalse(NativeParagraphBoundaryWitness.prove(field: 1,
            rawRange: CFRange(location: 7, length: 0), expectedFlat: "AприветC",
            expectedLeafText: "привет", expectedSide: .collapsedLeafEnd, reader: reader))
    }

    func testCollapsedCaretOnNextLeafOrWrongPrefixRefuses() {
        let reader = Reader()
        reader.fieldText = "AприветC"
        reader.leafText = "привет"
        reader.prefixText = "Aпривет"
        reader.selectedStart = 11
        reader.selectedEnd = 11
        reader.startOwner = 3
        reader.endOwner = 3
        XCTAssertFalse(NativeParagraphBoundaryWitness.prove(field: 1,
            rawRange: CFRange(location: 7, length: 0), expectedFlat: "AприветC",
            expectedLeafText: "привет", expectedSide: .collapsedLeafEnd, reader: reader))
        reader.startOwner = 2
        reader.endOwner = 2
        reader.prefixText = "Xпривет"
        XCTAssertFalse(NativeParagraphBoundaryWitness.prove(field: 1,
            rawRange: CFRange(location: 7, length: 0), expectedFlat: "AприветC",
            expectedLeafText: "привет", expectedSide: .collapsedLeafEnd, reader: reader))
    }
}
