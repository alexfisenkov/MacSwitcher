import XCTest
import CoreGraphics
@testable import RuSwitcher

final class RivalKeyboardTapWatchTests: XCTestCase {
    private let keyDown = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
    private let mouseOnly = CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue)

    private func tap(pid: pid_t = 500, enabled: Bool = true, active: Bool = true,
                     target: pid_t = 0, point: CGEventTapLocation = .cghidEventTap,
                     mask: CGEventMask? = nil, path: String? = "/Applications/Other.app/Contents/MacOS/Other")
        -> RivalKeyboardTapWatch.TapSnapshot {
        .init(processID: pid, enabled: enabled, isActiveFilter: active, targetProcessID: target,
              location: point, eventMask: mask ?? keyDown, executablePath: path)
    }

    func testActiveForeignKeyTapIsRival() {
        let state = RivalKeyboardTapWatch.classify([tap()], ownProcessID: 100)
        XCTAssertEqual(state, .active(programName: "Other"))
    }

    func testSessionLevelTapIsRivalToo() {
        XCTAssertNotEqual(RivalKeyboardTapWatch.classify([tap(point: .cgSessionEventTap)], ownProcessID: 100), .none)
    }

    func testOwnDisabledListenOnlyTargetedMouseAndAnnotatedTapsAreIgnored() {
        let ignored = [
            tap(pid: 100), tap(enabled: false), tap(active: false), tap(target: 77),
            tap(point: .cgAnnotatedSessionEventTap), tap(mask: mouseOnly),
        ]
        for item in ignored {
            XCTAssertEqual(RivalKeyboardTapWatch.classify([item], ownProcessID: 100), .none)
        }
    }

    func testSystemPathsAreExcluded() {
        for path in ["/System/Library/CoreServices/universalaccessd",
                     "/usr/libexec/hidd", "/usr/sbin/coreaudiod", "/usr/bin/x", "/sbin/y", "/bin/z"] {
            XCTAssertEqual(RivalKeyboardTapWatch.classify([tap(path: path)], ownProcessID: 100), .none, path)
        }
    }

    func testUnknownPathIsNotReportedAsRival() {
        XCTAssertEqual(RivalKeyboardTapWatch.classify([tap(path: nil)], ownProcessID: 100), .none)
    }

    func testSystemTapDoesNotHideARivalInTheSameList() {
        let state = RivalKeyboardTapWatch.classify(
            [tap(path: "/usr/libexec/hidd"), tap(pid: 600, path: "/Applications/Punto.app/Contents/MacOS/Punto")],
            ownProcessID: 100)
        XCTAssertEqual(state, .active(programName: "Punto"))
    }

    func testCodeIsLoggedOncePerAppearanceAndNeverCarriesName() {
        var codes: [RuntimeDiagnosticEvent] = []
        var state = RivalTapState.active(programName: "Other")
        var now: TimeInterval = 0
        let watch = RivalKeyboardTapWatch(source: { state }, now: { now }, record: { codes.append($0) })
        _ = watch.scan()
        now = 7; _ = watch.scan()
        XCTAssertEqual(codes, [.rivalKeyboardTapActive])
        state = .none; now = 14; _ = watch.scan()
        state = .active(programName: "Other"); now = 21; _ = watch.scan()
        XCTAssertEqual(codes, [.rivalKeyboardTapActive, .rivalKeyboardTapActive])
    }

    func testScanIsCachedBetweenPolls() {
        var calls = 0
        var now: TimeInterval = 0
        let watch = RivalKeyboardTapWatch(source: { calls += 1; return .none }, now: { now }, record: { _ in })
        _ = watch.scan(); now = 2; _ = watch.scan(); now = 4; _ = watch.scan()
        XCTAssertEqual(calls, 1)
        now = 6; _ = watch.scan()
        XCTAssertEqual(calls, 2)
    }

    func testHintAppearsOnlyOncePerLaunch() {
        let watch = RivalKeyboardTapWatch(source: { .none }, now: { 0 }, record: { _ in })
        XCTAssertNil(watch.takeHint(for: .none))
        XCTAssertEqual(watch.takeHint(for: .active(programName: "Other")), "Other")
        XCTAssertNil(watch.takeHint(for: .active(programName: "Other")))
        XCTAssertNil(watch.takeHint(for: .active(programName: "Second")))
    }

    func testHintWithoutProgramNameStillCountsAsShown() {
        let watch = RivalKeyboardTapWatch(source: { .none }, now: { 0 }, record: { _ in })
        XCTAssertEqual(watch.takeHint(for: .active(programName: nil)), "")
        XCTAssertNil(watch.takeHint(for: .active(programName: "Other")))
    }
}
