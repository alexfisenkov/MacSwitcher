import XCTest
@testable import RuSwitcher

final class SearchOverlayTargetTests: XCTestCase {
    func testOrdinaryHostFocusReturnsAbsentWithoutOverlayReads() {
        let host: Int32 = 68786
        let element = AXUIElementCreateApplication(host)
        var directReads = 0
        var capabilityReads = 0
        var windowReads = 0
        var selectionReads = 0
        let ordinary = SearchOverlayTarget.Probe(now: { 0 }, frontPID: { host },
            bundleID: { _ in "com.example.editor" },
            systemFocus: { _ in (host, element) },
            directFocus: { _, _ in directReads += 1; return nil },
            editable: { _, _ in capabilityReads += 1; return false },
            windows: { _ in windowReads += 1; return nil },
            focusedWindowBounds: { _, _ in nil },
            selection: { _, _ in selectionReads += 1; return nil })
        if case .absent = SearchOverlayTarget.capture(hostPID: host, probe: ordinary) {} else {
            XCTFail("Ordinary frontmost focus must retain the caller's existing path")
        }
        XCTAssertEqual([directReads, capabilityReads, windowReads, selectionReads], [0, 0, 0, 0])

        let unavailable = SearchOverlayTarget.Probe(now: { 0 }, frontPID: { host },
            bundleID: ordinary.bundleID, systemFocus: { _ in nil },
            directFocus: ordinary.directFocus, editable: ordinary.editable,
            windows: ordinary.windows, focusedWindowBounds: ordinary.focusedWindowBounds,
            selection: ordinary.selection)
        if case .unverified = SearchOverlayTarget.capture(hostPID: host, probe: unavailable) {} else {
            XCTFail("Unknown system focus must not authorize an underlay target")
        }
        XCTAssertEqual([directReads, capabilityReads, windowReads, selectionReads], [0, 0, 0, 0])
    }

    func testInjectedCaptureBindsGenericFieldAndRefusesExpiredBudget() {
        let element = AXUIElementCreateApplication(854)
        let focus = CombinedShiftFocus(processID: 854, element: element,
            initialSelection: CFRange(location: 0, length: 0))
        var clock: TimeInterval = 0
        let window = SearchOverlayTargetPolicy.WindowEvidence(processID: 854,
            windowID: 1234, bundleID: "com.example.launcher", ownerName: "Launcher")
        let probe = SearchOverlayTarget.Probe(
            now: { clock }, frontPID: { 68786 }, bundleID: { _ in "com.example.launcher" },
            systemFocus: { _ in (854, element) }, directFocus: { _, _ in focus },
            editable: { _, _ in true }, windows: { _ in [window] },
            focusedWindowBounds: { _, _ in nil }, selection: { _, _ in CFRange(location: 0, length: 0) })
        if case .verified(let captured) = SearchOverlayTarget.capture(hostPID: 68786, probe: probe) {
            XCTAssertEqual(captured.processID, 854)
        } else { XCTFail("Generic target should bind") }
        clock = 1
        let expired = SearchOverlayTarget.Probe(
            now: { clock }, frontPID: { 68786 }, bundleID: { _ in "com.example.launcher" },
            systemFocus: { _ in clock += 0.050; return (854, element) },
            directFocus: { _, _ in focus }, editable: { _, _ in true },
            windows: { _ in [window] }, focusedWindowBounds: { _, _ in nil },
            selection: { _, _ in CFRange(location: 0, length: 0) })
        if case .unverified = SearchOverlayTarget.capture(hostPID: 68786, probe: expired) {
            // Good: a late AX response cannot authorize the second gesture.
        } else { XCTFail("Expired capture must refuse") }
    }

    func testInjectedCaptureAndRevalidationRejectMissingCapabilityWindowAndFocus() {
        let element = AXUIElementCreateApplication(854)
        let changed = AXUIElementCreateApplication(999)
        let focus = CombinedShiftFocus(processID: 854, element: element,
            initialSelection: CFRange(location: 0, length: 0))
        let window = SearchOverlayTargetPolicy.WindowEvidence(processID: 854,
            windowID: 1234, bundleID: "com.example.launcher", ownerName: "Launcher")
        var host: Int32 = 68786
        var bundle = "com.example.launcher"
        var systemElement = element
        var editable = true
        var visible = [window]
        var selectionAvailable = true
        let probe = SearchOverlayTarget.Probe(now: { 0 }, frontPID: { host },
            bundleID: { _ in bundle }, systemFocus: { _ in (854, systemElement) },
            directFocus: { _, _ in focus }, editable: { _, _ in editable },
            windows: { _ in visible }, focusedWindowBounds: { _, _ in nil },
            selection: { _, _ in selectionAvailable ? CFRange(location: 0, length: 0) : nil })
        guard case .verified(let captured) = SearchOverlayTarget.capture(hostPID: host, probe: probe),
              let binding = captured.searchOverlay else { XCTFail("Expected bound target"); return }
        XCTAssertTrue(SearchOverlayTarget.isCurrent(captured, binding: binding, probe: probe))
        visible = []
        XCTAssertFalse(SearchOverlayTarget.isCurrent(captured, binding: binding, probe: probe))
        visible = [window]
        editable = false // secure, read-only or absent positive capability
        if case .unverified = SearchOverlayTarget.capture(hostPID: host, probe: probe) {} else {
            XCTFail("Unreadable or read-only field must refuse")
        }
        XCTAssertFalse(SearchOverlayTarget.isCurrent(captured, binding: binding, probe: probe))
        editable = true
        systemElement = changed
        XCTAssertFalse(SearchOverlayTarget.isCurrent(captured, binding: binding, probe: probe))
        systemElement = element
        selectionAvailable = false
        XCTAssertFalse(SearchOverlayTarget.isCurrent(captured, binding: binding, probe: probe))
        selectionAvailable = true
        bundle = "com.example.changed"
        XCTAssertNil(SearchOverlayTarget.currentProcessID(for: binding, probe: probe))
        bundle = "com.example.launcher"
        host = 999
        XCTAssertFalse(SearchOverlayTarget.isCurrent(captured, binding: binding, probe: probe))
    }

    func testWindowListPastAggregateDeadlineStopsBeforeSelectionRead() {
        let element = AXUIElementCreateApplication(854)
        let focus = CombinedShiftFocus(processID: 854, element: element)
        let window = SearchOverlayTargetPolicy.WindowEvidence(processID: 854,
            windowID: 1234, bundleID: "com.example.launcher", ownerName: "Launcher")
        var clock: TimeInterval = 0
        var selectionReads = 0
        let probe = SearchOverlayTarget.Probe(now: { clock }, frontPID: { 68786 },
            bundleID: { _ in "com.example.launcher" },
            systemFocus: { _ in (854, element) }, directFocus: { _, _ in focus },
            editable: { _, _ in true }, windows: { _ in clock = 0.050; return [window] },
            focusedWindowBounds: { _, _ in nil }, selection: { _, _ in
                selectionReads += 1; return CFRange(location: 0, length: 0)
            })
        if case .unverified = SearchOverlayTarget.capture(hostPID: 68786, probe: probe) {} else {
            XCTFail("Late window list cannot authorize capture")
        }
        XCTAssertEqual(selectionReads, 0)
    }

    func testBudgetStopsDependentCapabilityAndGeometryReads() {
        let element = AXUIElementCreateApplication(854)
        let focus = CombinedShiftFocus(processID: 854, element: element)
        let first = SearchOverlayTargetPolicy.WindowEvidence(processID: 854,
            windowID: 1234, bundleID: "com.example.launcher", ownerName: "Launcher",
            bounds: CGRect(x: 0, y: 0, width: 700, height: 500))
        let second = SearchOverlayTargetPolicy.WindowEvidence(processID: 854,
            windowID: 1235, bundleID: "com.example.launcher", ownerName: "Launcher",
            bounds: CGRect(x: 100, y: 100, width: 450, height: 80))
        var clock: TimeInterval = 0
        var capabilityReads = 0
        var geometryReads = 0
        var selectionReads = 0
        var expireInCapability = true
        let probe = SearchOverlayTarget.Probe(now: { clock }, frontPID: { 68786 },
            bundleID: { _ in "com.example.launcher" },
            systemFocus: { _ in (854, element) }, directFocus: { _, _ in focus },
            editable: { _, budget in
                guard budget.timeout() != nil else { return false }
                capabilityReads += 1
                if expireInCapability { clock = 0.041 }
                guard budget.timeout() != nil else { return false }
                capabilityReads += 1
                return true
            }, windows: { _ in [first, second] },
            focusedWindowBounds: { _, budget in
                guard budget.timeout() != nil else { return nil }
                geometryReads += 1
                clock = 0.041
                guard budget.timeout() != nil else { return nil }
                geometryReads += 1
                return second.bounds
            }, selection: { _, _ in
                selectionReads += 1; return CFRange(location: 0, length: 0)
            })
        if case .unverified = SearchOverlayTarget.capture(hostPID: 68786, probe: probe) {} else {
            XCTFail("Capability over budget must refuse")
        }
        XCTAssertEqual(capabilityReads, 1)
        XCTAssertEqual(geometryReads, 0)
        clock = 0
        expireInCapability = false
        if case .unverified = SearchOverlayTarget.capture(hostPID: 68786, probe: probe) {} else {
            XCTFail("Geometry over budget must refuse")
        }
        XCTAssertEqual(geometryReads, 1)
        XCTAssertEqual(selectionReads, 0)
    }

    func testGenericFloatingTextWindowCanBindWithoutKnownAppName() {
        let window = SearchOverlayTargetPolicy.WindowEvidence(
            processID: 854, windowID: 1234, bundleID: "com.example.launcher", ownerName: "Launcher")
        let selected = SearchOverlayTargetPolicy.uniqueWindow(
            focusedPID: 854, windows: [window])
        XCTAssertEqual(selected?.bundleID, "com.example.launcher")
        XCTAssertEqual(selected?.windowID, 1234)
        XCTAssertNil(SearchOverlayTargetPolicy.uniqueWindow(focusedPID: 854,
            windows: [window, .init(processID: 854, windowID: 1235,
                                    bundleID: "com.example.launcher", ownerName: "Launcher")]))
        XCTAssertNil(SearchOverlayTargetPolicy.uniqueWindow(focusedPID: 855, windows: [window]))
    }

    func testMultipleVisibleWindowsSelectOnlyExactFocusedWindowFrame() {
        let chat = SearchOverlayTargetPolicy.WindowEvidence(
            processID: 854, windowID: 1234, bundleID: "com.example.launcher",
            ownerName: "Launcher", bounds: CGRect(x: 0, y: 0, width: 700, height: 500))
        let search = SearchOverlayTargetPolicy.WindowEvidence(
            processID: 854, windowID: 1235, bundleID: "com.example.launcher",
            ownerName: "Launcher", bounds: CGRect(x: 100, y: 100, width: 450, height: 80))
        XCTAssertEqual(SearchOverlayTargetPolicy.uniqueWindow(focusedPID: 854,
            windows: [chat, search], focusedWindowBounds: search.bounds)?.windowID, 1235)
        XCTAssertNil(SearchOverlayTargetPolicy.uniqueWindow(focusedPID: 854,
            windows: [chat, search], focusedWindowBounds: nil))
        XCTAssertNil(SearchOverlayTargetPolicy.uniqueWindow(focusedPID: 854,
            windows: [chat, search], focusedWindowBounds: CGRect(x: 50, y: 50, width: 450, height: 80)))
        XCTAssertNil(SearchOverlayTargetPolicy.uniqueWindow(focusedPID: 854,
            windows: [search, search], focusedWindowBounds: search.bounds))
    }

    func testVerifiedOverlayBindsItsOwnPIDInsteadOfFrontmostHost() {
        XCTAssertEqual(SearchOverlayTargetPolicy.resolve(
            hostPID: 68786, visibleProviderPIDs: [854], systemFocusedPID: 854,
            directFocusedPID: 854, sameField: true, editableTextField: true), 854)
        XCTAssertNil(SearchOverlayTargetPolicy.resolve(
            hostPID: 68786, visibleProviderPIDs: [854], systemFocusedPID: 68786,
            directFocusedPID: 854, sameField: true, editableTextField: true))
    }

    func testVisibleOverlayNeverAuthorizesUnderlayOrAmbiguousField() {
        let host: Int32 = 68786
        let overlay: Int32 = 854
        let cases: [([Int32], Int32?, Int32?, Bool, Bool)] = [
            ([], overlay, overlay, true, true),          // closed or hidden
            ([overlay, 999], overlay, overlay, true, true), // ambiguous providers
            ([999], overlay, overlay, true, true),       // changed window PID
            ([overlay], host, overlay, true, true),      // underlay owns system focus
            ([overlay], overlay, host, true, true),      // direct field is elsewhere
            ([overlay], overlay, overlay, false, true), // different AX element
            ([overlay], overlay, overlay, true, false)  // disabled, secure or read-only
        ]
        for (visible, system, direct, same, editable) in cases {
            XCTAssertNil(SearchOverlayTargetPolicy.resolve(hostPID: host,
                visibleProviderPIDs: visible, systemFocusedPID: system,
                directFocusedPID: direct, sameField: same, editableTextField: editable))
        }
    }

    func testInactiveFloatingWindowDoesNotBlockOrdinarySystemFocus() {
        XCTAssertFalse(SearchOverlayTargetPolicy.mayBeNonFrontmost(
            hostPID: 68786, systemFocusedPID: 68786))
        XCTAssertTrue(SearchOverlayTargetPolicy.mayBeNonFrontmost(
            hostPID: 68786, systemFocusedPID: 854))
        XCTAssertTrue(SearchOverlayTargetPolicy.mayBeNonFrontmost(
            hostPID: 68786, systemFocusedPID: nil))
    }
}
