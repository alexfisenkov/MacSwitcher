import ApplicationServices
import Foundation

/// Optional evidence for a single complete text leaf at a generated paragraph
/// boundary. Call only when the numeric/formatted projection is ambiguous.
/// The normal path never invokes these additional AX capabilities.
enum NativeParagraphBoundaryWitness {
    enum Side {
        case selectedWholeLeaf
        case selectedLeafStart
        case collapsedLeafEnd
    }

    static func prove(focus: CombinedShiftFocus, rawRange: CFRange,
                      expectedFlat: String, expectedLeafText: String,
                      expectedSide: Side, phaseDeadline: TimeInterval,
                      prepareRead: @escaping () -> Bool) -> Bool {
        guard focus.fieldBoundary == nil, phaseDeadline.isFinite,
              ProcessInfo.processInfo.systemUptime < phaseDeadline else { return false }
        let reader = AXReader(processID: focus.processID, deadline: phaseDeadline,
                              prepareRead: prepareRead)
        return prove(field: AXElement(focus.element), rawRange: rawRange,
                     expectedFlat: expectedFlat, expectedLeafText: expectedLeafText,
                     expectedSide: expectedSide, reader: reader)
    }

    /// An injectable, read-only capability surface. Its production adapter
    /// gates and bounds every remote operation; tests use synthetic markers.
    static func prove<R: NativeParagraphBoundaryReader>(field: R.Element, rawRange: CFRange,
                                 expectedFlat: String, expectedLeafText: String,
                                 expectedSide: Side, reader: R) -> Bool {
        let flatCount = expectedFlat.utf16.count
        let leafCount = expectedLeafText.utf16.count
        guard flatCount <= NativeFieldEditPlan.maximumFieldUnits,
              leafCount > 0, leafCount <= NativeFieldEditPlan.maximumFieldUnits else { return false }
        let flat = Array(expectedFlat.utf16)
        let leaf = Array(expectedLeafText.utf16)
        guard
              NativeFieldEditPlan.isWellFormedUTF16(flat),
              NativeFieldEditPlan.isWellFormedUTF16(leaf),
              !flat.contains(0x000A), !flat.contains(0x000D),
              !leaf.contains(0x000A), !leaf.contains(0x000D),
              rawRange.location >= 0, rawRange.length >= 0,
              rawRange.location <= flat.count,
              rawRange.length <= flat.count - rawRange.location,
              reader.supports(field: field),
              let fieldRange = reader.range(for: field, within: field),
              let fieldStart = reader.start(of: fieldRange),
              reader.text(in: fieldRange, within: field)?.utf16.elementsEqual(flat) == true,
              let selectedRange = reader.selectedRange(of: field),
              let selectedStart = reader.start(of: selectedRange),
              let selectedEnd = reader.end(of: selectedRange),
              let ordered = reader.range(between: selectedStart, and: selectedEnd, within: field),
              let actualStart = reader.start(of: ordered),
              let actualEnd = reader.end(of: ordered) else { return false }

        switch expectedSide {
        case .selectedLeafStart:
            // The raw start may describe both the previous leaf's end and
            // this leaf's start. Require the actual marker to be this leaf's
            // own start; the selected end must remain inside that same leaf.
            let selectedUnits = flat[rawRange.location..<(rawRange.location + rawRange.length)]
            guard rawRange.length > 0, rawRange.length <= leaf.count,
                  leaf.prefix(rawRange.length).elementsEqual(selectedUnits),
                  let startLeaf = reader.element(for: actualStart, within: field),
                  let endLeaf = reader.element(for: actualEnd, within: field),
                  startLeaf == endLeaf, startLeaf != field,
                  descendant(startLeaf, of: field, reader: reader),
                  reader.role(of: startLeaf) == kAXStaticTextRole,
                  let leafRange = reader.range(for: startLeaf, within: field),
                  let leafStart = reader.start(of: leafRange),
                  actualStart == leafStart,
                  reader.text(in: leafRange, within: field)?.utf16.elementsEqual(leaf) == true,
                  reader.text(in: ordered, within: field)?.utf16.elementsEqual(selectedUnits) == true else {
                return false
            }
            return prefixMatches(from: fieldStart, to: actualStart, rawOffset: rawRange.location,
                                 flat: flat, field: field, reader: reader)

        case .selectedWholeLeaf:
            guard rawRange.length == leaf.count,
                  flat[rawRange.location..<(rawRange.location + rawRange.length)].elementsEqual(leaf),
                  let startLeaf = reader.element(for: actualStart, within: field),
                  let endLeaf = reader.element(for: actualEnd, within: field),
                  startLeaf == endLeaf, startLeaf != field,
                  descendant(startLeaf, of: field, reader: reader),
                  reader.role(of: startLeaf) == kAXStaticTextRole,
                  reader.text(in: ordered, within: field)?.utf16.elementsEqual(leaf) == true,
                  let leafRange = reader.range(for: startLeaf, within: field),
                  let leafStart = reader.start(of: leafRange),
                  let leafEnd = reader.end(of: leafRange),
                  actualStart == leafStart, actualEnd == leafEnd,
                  reader.text(in: leafRange, within: field)?.utf16.elementsEqual(leaf) == true else {
                return false
            }
            return prefixMatches(from: fieldStart, to: actualStart, rawOffset: rawRange.location,
                                 flat: flat, field: field, reader: reader)

        case .collapsedLeafEnd:
            guard rawRange.length == 0, rawRange.location >= leaf.count,
                  flat[(rawRange.location - leaf.count)..<rawRange.location].elementsEqual(leaf),
                  actualStart == actualEnd,
                  let caretLeaf = reader.element(for: actualEnd, within: field),
                  caretLeaf != field,
                  descendant(caretLeaf, of: field, reader: reader),
                  reader.role(of: caretLeaf) == kAXStaticTextRole,
                  let leafRange = reader.range(for: caretLeaf, within: field),
                  let leafEnd = reader.end(of: leafRange),
                  actualEnd == leafEnd,
                  reader.text(in: leafRange, within: field)?.utf16.elementsEqual(leaf) == true else {
                return false
            }
            return prefixMatches(from: fieldStart, to: actualEnd, rawOffset: rawRange.location,
                                 flat: flat, field: field, reader: reader)
        }
    }

    private static func descendant<R: NativeParagraphBoundaryReader>(_ leaf: R.Element, of field: R.Element,
                                               reader: R) -> Bool {
        var current = leaf
        var seen = [leaf]
        for _ in 0..<6 {
            guard let parent = reader.parent(of: current), !seen.contains(parent) else { return false }
            if parent == field { return true }
            guard reader.safeIntermediate(parent) else { return false }
            seen.append(parent)
            current = parent
        }
        return false
    }

    private static func prefixMatches<R: NativeParagraphBoundaryReader>(from fieldStart: R.Marker,
                                                  to marker: R.Marker, rawOffset: Int,
                                                  flat: [UInt16], field: R.Element,
                                                  reader: R) -> Bool {
        guard let prefixRange = reader.range(between: fieldStart, and: marker, within: field),
              let prefix = reader.text(in: prefixRange, within: field) else { return false }
        return prefix.utf16.elementsEqual(flat[..<rawOffset])
    }
}

protocol NativeParagraphBoundaryReader {
    associatedtype Element: Equatable
    associatedtype Marker: Equatable
    associatedtype MarkerRange

    func supports(field: Element) -> Bool
    func selectedRange(of field: Element) -> MarkerRange?
    func range(for element: Element, within field: Element) -> MarkerRange?
    func range(between first: Marker, and second: Marker, within field: Element) -> MarkerRange?
    func start(of range: MarkerRange) -> Marker?
    func end(of range: MarkerRange) -> Marker?
    func element(for marker: Marker, within field: Element) -> Element?
    func parent(of element: Element) -> Element?
    func safeIntermediate(_ element: Element) -> Bool
    func role(of element: Element) -> String?
    func text(in range: MarkerRange, within field: Element) -> String?
}

private struct AXElement: Equatable {
    let value: AXUIElement
    init(_ value: AXUIElement) { self.value = value }
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.value, rhs.value) }
}

private struct AXMarker: Equatable {
    let value: AXTextMarker
    init(_ value: AXTextMarker) { self.value = value }
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.value, rhs.value) }
}

private struct AXReader: NativeParagraphBoundaryReader {
    typealias Element = AXElement
    typealias Marker = AXMarker
    typealias MarkerRange = AXTextMarkerRange

    let processID: Int32
    let deadline: TimeInterval
    let prepareRead: () -> Bool

    private func admit(_ target: AXUIElement) -> Bool {
        guard prepareRead(),
              let timeout = NativeAXMessagingPolicy.remainingTimeout(until: deadline,
                  now: ProcessInfo.processInfo.systemUptime,
                  configuredTimeout: NativeAXMessagingPolicy.defaultTimeout),
              AXUIElementSetMessagingTimeout(target, timeout) == .success,
              prepareRead(), ProcessInfo.processInfo.systemUptime < deadline else { return false }
        return true
    }

    func supports(field: Element) -> Bool {
        var attributes: CFArray?
        guard admit(field.value),
              AXUIElementCopyAttributeNames(field.value, &attributes) == .success,
              let names = attributes as? [String], names.contains("AXSelectedTextMarkerRange") else { return false }
        var parameters: CFArray?
        guard admit(field.value),
              AXUIElementCopyParameterizedAttributeNames(field.value, &parameters) == .success,
              let supported = parameters as? [String] else { return false }
        let needed = ["AXUIElementForTextMarker", "AXTextMarkerRangeForUIElement",
                      "AXStringForTextMarkerRange", "AXTextMarkerRangeForUnorderedTextMarkers"]
        return needed.allSatisfy(supported.contains)
    }

    func selectedRange(of field: Element) -> MarkerRange? {
        var raw: AnyObject?
        guard admit(field.value),
              AXUIElementCopyAttributeValue(field.value,
                  "AXSelectedTextMarkerRange" as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (raw as! AXTextMarkerRange)
    }

    func range(for element: Element, within field: Element) -> MarkerRange? {
        var raw: AnyObject?
        guard admit(field.value),
              AXUIElementCopyParameterizedAttributeValue(field.value,
                  "AXTextMarkerRangeForUIElement" as CFString,
                  element.value, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (raw as! AXTextMarkerRange)
    }

    func range(between first: Marker, and second: Marker, within field: Element) -> MarkerRange? {
        var raw: AnyObject?
        let markers = [first.value, second.value] as CFArray
        guard admit(field.value),
              AXUIElementCopyParameterizedAttributeValue(field.value,
                  "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
                  markers, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (raw as! AXTextMarkerRange)
    }

    func start(of range: MarkerRange) -> Marker? {
        AXMarker(AXTextMarkerRangeCopyStartMarker(range))
    }

    func end(of range: MarkerRange) -> Marker? {
        AXMarker(AXTextMarkerRangeCopyEndMarker(range))
    }

    func element(for marker: Marker, within field: Element) -> Element? {
        var raw: AnyObject?
        guard admit(field.value),
              AXUIElementCopyParameterizedAttributeValue(field.value,
                  "AXUIElementForTextMarker" as CFString,
                  marker.value, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        var pid: pid_t = 0
        guard admit(element), AXUIElementGetPid(element, &pid) == .success,
              pid == processID else { return nil }
        return AXElement(element)
    }

    func parent(of element: Element) -> Element? {
        var raw: AnyObject?
        guard admit(element.value),
              AXUIElementCopyAttributeValue(element.value,
                  kAXParentAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXElement(raw as! AXUIElement)
    }

    func safeIntermediate(_ element: Element) -> Bool {
        // Only transparent containers may occur between a text leaf and the
        // captured edit field. Another editor/window/document is never crossed.
        guard let role = role(of: element),
              role == kAXGroupRole || role == "AXParagraph" else { return false }
        var editable: AnyObject?
        guard admit(element.value) else { return false }
        let editStatus = AXUIElementCopyAttributeValue(element.value,
            "AXEditable" as CFString, &editable)
        switch editStatus {
        case .success:
            guard let editable, CFGetTypeID(editable) == CFBooleanGetTypeID(),
                  !CFBooleanGetValue((editable as! CFBoolean)) else { return false }
        case .attributeUnsupported, .noValue: break
        default: return false
        }
        var subrole: AnyObject?
        guard admit(element.value) else { return false }
        let subroleStatus = AXUIElementCopyAttributeValue(element.value,
            kAXSubroleAttribute as CFString, &subrole)
        switch subroleStatus {
        case .success:
            guard let subrole, CFGetTypeID(subrole) == CFStringGetTypeID(),
                  (subrole as? String) != kAXSecureTextFieldSubrole else { return false }
        case .attributeUnsupported, .noValue: break
        default: return false
        }
        var readOnly: AnyObject?
        guard admit(element.value) else { return false }
        let readOnlyStatus = AXUIElementCopyAttributeValue(element.value,
            "AXReadOnly" as CFString, &readOnly)
        switch readOnlyStatus {
        case .success:
            guard let readOnly, CFGetTypeID(readOnly) == CFBooleanGetTypeID(),
                  !CFBooleanGetValue((readOnly as! CFBoolean)) else { return false }
        case .attributeUnsupported, .noValue: break
        default: return false
        }
        return true
    }

    func role(of element: Element) -> String? {
        var raw: AnyObject?
        guard admit(element.value),
              AXUIElementCopyAttributeValue(element.value,
                  kAXRoleAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return raw as? String
    }

    func text(in range: MarkerRange, within field: Element) -> String? {
        var raw: AnyObject?
        guard admit(field.value),
              AXUIElementCopyParameterizedAttributeValue(field.value,
                  "AXStringForTextMarkerRange" as CFString, range, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        let string = raw as! CFString
        let count = CFStringGetLength(string)
        guard count <= NativeFieldEditPlan.maximumFieldUnits else { return nil }
        var units = [UInt16](repeating: 0, count: count)
        if count > 0 {
            units.withUnsafeMutableBufferPointer {
                CFStringGetCharacters(string, CFRange(location: 0, length: count), $0.baseAddress!)
            }
        }
        guard NativeFieldEditPlan.isWellFormedUTF16(units) else { return nil }
        return String(decoding: units, as: UTF16.self)
    }
}
