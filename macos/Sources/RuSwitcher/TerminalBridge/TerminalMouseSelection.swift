import AppKit
import ApplicationServices

/// Read-only proof that an AX mouse selection belongs to the visible, current
/// shell BUFFER tail. No transcript prefix, AXValue or clipboard is read.
enum TerminalMouseSelection {
    static let maximumBufferUTF16 = 4_096
    private static let maximumDuration: TimeInterval = 0.120
    private static let maximumAXCall: Float = 0.010

    struct Budget {
        let deadline: TimeInterval
        let now: () -> TimeInterval

        func timeout() -> Float? {
            let left = deadline - now()
            guard left.isFinite, left > 0 else { return nil }
            return Float(min(Double(maximumAXCall), left))
        }
    }

    /// The production reader uses only bounded AX metadata/parameterized reads.
    /// A synthetic reader exercises the same fail-closed proof in tests.
    struct Reader {
        let now: () -> TimeInterval
        let window: (CombinedShiftFocus, Budget) -> AXUIElement?
        let secure: (CombinedShiftFocus, Budget) -> Bool?
        let numberOfCharacters: (CombinedShiftFocus, Budget) -> Int?
        let selection: (CombinedShiftFocus, Budget) -> CFRange?
        let stringForRange: (CombinedShiftFocus, CFRange, Budget) -> String?
        let boundsForRange: (CombinedShiftFocus, CFRange, Budget) -> CGRect?

        static var live: Self {
            Self(now: { ProcessInfo.processInfo.systemUptime },
                 window: { liveWindow($0, $1) },
                 secure: { liveSecure($0, $1) },
                 numberOfCharacters: { liveNumber($0, $1) },
                 selection: { liveSelection($0, $1) },
                 stringForRange: { liveParameterizedString($0, $1, $2) },
                 boundsForRange: { liveParameterizedBounds($0, $1, $2) })
        }
    }

    struct Proof: @unchecked Sendable {
        let scalarRange: Range<Int>
        private let focus: CombinedShiftFocus
        private let window: AXUIElement
        private let expectedBuffer: String
        private let selection: CFRange
        private let reader: Reader

        fileprivate init(scalarRange: Range<Int>, focus: CombinedShiftFocus, window: AXUIElement,
                         expectedBuffer: String, selection: CFRange, reader: Reader) {
            self.scalarRange = scalarRange
            self.focus = focus
            self.window = window
            self.expectedBuffer = expectedBuffer
            self.selection = selection
            self.reader = reader
        }

        /// Called in precommit authorization, after the shell snapshot/TTY/nonce
        /// are also revalidated by their own existing contracts.
        func isCurrent() -> Bool {
            guard let observed = TerminalMouseSelection.observe(focus: focus,
                expectedBuffer: expectedBuffer, originalSelection: selection,
                originalWindow: window, reader: reader) else { return false }
            return observed.scalarRange == scalarRange
        }
    }

    static func capture(focus: CombinedShiftFocus, expectedBuffer: String,
                        reader: Reader = .live) -> Proof? {
        guard let initial = focus.initialSelection, initial.length > 0,
              let observed = observe(focus: focus, expectedBuffer: expectedBuffer,
                                     originalSelection: initial, originalWindow: nil,
                                     reader: reader) else { return nil }
        return Proof(scalarRange: observed.scalarRange, focus: focus, window: observed.window,
                     expectedBuffer: expectedBuffer, selection: initial, reader: reader)
    }

    private struct Observation {
        let scalarRange: Range<Int>
        let window: AXUIElement
    }

    private static func observe(focus: CombinedShiftFocus, expectedBuffer: String,
                                originalSelection: CFRange, originalWindow: AXUIElement?,
                                reader: Reader) -> Observation? {
        let length = expectedBuffer.utf16.count
        guard focus.searchOverlay == nil, focus.processID > 0,
              length > 0, length <= maximumBufferUTF16,
              !expectedBuffer.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }),
              originalSelection.location >= 0, originalSelection.length > 0,
              originalSelection.location <= Int.max - originalSelection.length else { return nil }
        let budget = Budget(deadline: reader.now() + maximumDuration, now: reader.now)
        guard budget.timeout() != nil,
              let window = reader.window(focus, budget), budget.timeout() != nil,
              originalWindow.map({ CFEqual($0, window) }) ?? true,
              reader.secure(focus, budget) == false, budget.timeout() != nil,
              let count = reader.numberOfCharacters(focus, budget), budget.timeout() != nil,
              count >= length else { return nil }
        let tailStart = count - length
        let tailRange = CFRange(location: tailStart, length: length)
        guard originalSelection.location >= tailStart,
              originalSelection.location + originalSelection.length <= count,
              let selection = reader.selection(focus, budget),
              same(selection, originalSelection), budget.timeout() != nil,
              reader.stringForRange(focus, tailRange, budget) == expectedBuffer,
              budget.timeout() != nil,
              let scalarRange = scalarRange(in: expectedBuffer,
                    lowerUTF16: selection.location - tailStart,
                    upperUTF16: selection.location + selection.length - tailStart),
              let selected = reader.stringForRange(focus, selection, budget),
              selected == scalarSlice(expectedBuffer, scalarRange), budget.timeout() != nil else { return nil }

        // AX transcript offsets may represent wrapped or scrolled output. The
        // command's first and last glyph must share one positive visual row.
        let firstLength = expectedBuffer.unicodeScalars.first!.utf16.count
        let lastLength = expectedBuffer.unicodeScalars.last!.utf16.count
        let first = CFRange(location: tailStart, length: firstLength)
        let last = CFRange(location: count - lastLength, length: lastLength)
        guard let firstBounds = reader.boundsForRange(focus, first, budget),
              let lastBounds = reader.boundsForRange(focus, last, budget),
              sameRow(firstBounds, lastBounds), budget.timeout() != nil,
              reader.numberOfCharacters(focus, budget) == count, budget.timeout() != nil,
              let afterSelection = reader.selection(focus, budget),
              same(afterSelection, selection), budget.timeout() != nil,
              reader.stringForRange(focus, tailRange, budget) == expectedBuffer,
              budget.timeout() != nil else { return nil }
        return Observation(scalarRange: scalarRange, window: window)
    }

    private static func same(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }

    private static func sameRow(_ first: CGRect, _ last: CGRect) -> Bool {
        guard [first.minX, first.minY, first.width, first.height,
               last.minX, last.minY, last.width, last.height].allSatisfy(\.isFinite),
              first.width > 0, first.height > 0, last.width > 0, last.height > 0 else { return false }
        return abs(first.minY - last.minY) <= 2 && abs(first.height - last.height) <= 2
    }

    private static func scalarRange(in buffer: String, lowerUTF16: Int,
                                    upperUTF16: Int) -> Range<Int>? {
        guard lowerUTF16 >= 0, lowerUTF16 < upperUTF16,
              upperUTF16 <= buffer.utf16.count else { return nil }
        var offsets: [Int: Int] = [0: 0]
        var utf16 = 0, scalar = 0
        for value in buffer.unicodeScalars {
            utf16 += value.utf16.count
            scalar += 1
            offsets[utf16] = scalar
        }
        guard let lower = offsets[lowerUTF16], let upper = offsets[upperUTF16] else { return nil }
        // Do not split a displayed grapheme even when both endpoints are scalar boundaries.
        var graphemeOffsets: Set<Int> = [0]
        utf16 = 0
        for character in buffer {
            utf16 += String(character).utf16.count
            graphemeOffsets.insert(utf16)
        }
        guard graphemeOffsets.contains(lowerUTF16), graphemeOffsets.contains(upperUTF16) else { return nil }
        return lower..<upper
    }

    private static func scalarSlice(_ text: String, _ range: Range<Int>) -> String {
        String(String.UnicodeScalarView(Array(text.unicodeScalars)[range]))
    }

    private static func read(_ element: AXUIElement, attribute: CFString,
                             budget: Budget) -> (AXError, AnyObject?)? {
        guard let timeout = budget.timeout(),
              AXUIElementSetMessagingTimeout(element, timeout) == .success,
              let current = budget.timeout(),
              AXUIElementSetMessagingTimeout(element, current) == .success else { return nil }
        var raw: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard budget.timeout() != nil else { return nil }
        return (status, raw)
    }

    private static func parameterized(_ focus: CombinedShiftFocus, attribute: CFString,
                                      range: CFRange, budget: Budget) -> AnyObject? {
        guard range.location >= 0, range.length > 0 else { return nil }
        var requested = range
        guard let value = AXValueCreate(.cfRange, &requested),
              let timeout = budget.timeout(),
              focus.setMessagingTimeout(timeout) == .success,
              let current = budget.timeout(),
              focus.setMessagingTimeout(current) == .success else { return nil }
        var raw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(focus.element, attribute,
              value, &raw) == .success, budget.timeout() != nil else { return nil }
        return raw
    }

    private static func liveWindow(_ focus: CombinedShiftFocus, _ budget: Budget) -> AXUIElement? {
        let app = AXUIElementCreateApplication(focus.processID)
        guard !AutoSwitchPolicy.secureInputActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID,
              let (fieldStatus, fieldRaw) = read(app,
                  attribute: kAXFocusedUIElementAttribute as CFString, budget: budget),
              fieldStatus == .success, let fieldRaw,
              CFGetTypeID(fieldRaw) == AXUIElementGetTypeID(),
              CFEqual(fieldRaw, focus.element),
              let (frontWindowStatus, frontWindowRaw) = read(app,
                  attribute: kAXFocusedWindowAttribute as CFString, budget: budget),
              frontWindowStatus == .success, let frontWindowRaw,
              CFGetTypeID(frontWindowRaw) == AXUIElementGetTypeID(),
              let (windowStatus, windowRaw) = read(focus.element,
                  attribute: kAXWindowAttribute as CFString, budget: budget),
              windowStatus == .success, let windowRaw,
              CFGetTypeID(windowRaw) == AXUIElementGetTypeID(),
              CFEqual(frontWindowRaw, windowRaw) else { return nil }
        let window = windowRaw as! AXUIElement
        var pid: pid_t = 0, windowPID: pid_t = 0
        guard let timeout = budget.timeout(),
              AXUIElementSetMessagingTimeout(focus.element, timeout) == .success,
              budget.timeout() != nil,
              AXUIElementGetPid(focus.element, &pid) == .success,
              pid == focus.processID, budget.timeout() != nil,
              let windowTimeout = budget.timeout(),
              AXUIElementSetMessagingTimeout(window, windowTimeout) == .success,
              budget.timeout() != nil,
              AXUIElementGetPid(window, &windowPID) == .success,
              windowPID == focus.processID, budget.timeout() != nil else { return nil }
        return window
    }

    private static func liveSecure(_ focus: CombinedShiftFocus, _ budget: Budget) -> Bool? {
        guard !AutoSwitchPolicy.secureInputActive,
              let (status, raw) = read(focus.element,
                  attribute: kAXSubroleAttribute as CFString, budget: budget) else { return nil }
        switch status {
        case .success:
            guard let role = raw as? String else { return nil }
            return role == kAXSecureTextFieldSubrole
        case .attributeUnsupported, .noValue:
            return false
        default:
            return nil
        }
    }

    private static func liveNumber(_ focus: CombinedShiftFocus, _ budget: Budget) -> Int? {
        guard let (status, raw) = read(focus.element,
            attribute: "AXNumberOfCharacters" as CFString, budget: budget), status == .success,
            let number = raw as? NSNumber, number.intValue >= 0 else { return nil }
        return number.intValue
    }

    private static func liveSelection(_ focus: CombinedShiftFocus, _ budget: Budget) -> CFRange? {
        guard let (status, raw) = read(focus.element,
            attribute: kAXSelectedTextRangeAttribute as CFString, budget: budget), status == .success,
            let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range),
              range.location >= 0, range.length > 0 else { return nil }
        return range
    }

    private static func liveParameterizedString(_ focus: CombinedShiftFocus,
                                                 _ range: CFRange, _ budget: Budget) -> String? {
        parameterized(focus, attribute: kAXStringForRangeParameterizedAttribute as CFString,
                      range: range, budget: budget) as? String
    }

    private static func liveParameterizedBounds(_ focus: CombinedShiftFocus,
                                                 _ range: CFRange, _ budget: Budget) -> CGRect? {
        guard let raw = parameterized(focus,
            attribute: kAXBoundsForRangeParameterizedAttribute as CFString,
            range: range, budget: budget), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &bounds) else { return nil }
        return bounds
    }
}
