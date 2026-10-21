import XCTest
@testable import RuSwitcher

final class DiagnosticFixtureInputDriverTests: XCTestCase {
    @MainActor
    func testBackgroundActualTISSnapshotHopsToMainWithoutPostingEvents() async {
        let observation: (Bool, DiagnosticFixtureInputSource.Snapshot) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning:
                    (Thread.isMainThread, DiagnosticFixtureInputSource.snapshot(keyCode: 5)))
            }
        }
        let (startedOnMain, snapshot) = observation
        XCTAssertFalse(startedOnMain)
        XCTAssertFalse(snapshot.sourceID?.isEmpty ?? true)
        if let payload = snapshot.payload { XCTAssertFalse(payload.isEmpty) }
    }

    @MainActor
    func testActualTISSnapshotOnMainReturnsWithoutSynchronousRedispatch() {
        XCTAssertTrue(Thread.isMainThread)
        let snapshot = DiagnosticFixtureInputSource.snapshot(keyCode: 5)
        XCTAssertFalse(snapshot.sourceID?.isEmpty ?? true)
        if let payload = snapshot.payload { XCTAssertFalse(payload.isEmpty) }
    }

    func testLocationAcceptsKnownFixtureThroughTmpAlias() {
        XCTAssertTrue(DiagnosticFixtureLocation.matches(actual: URL(fileURLWithPath:
            "/tmp/MacSwitcherInputFixture.app/Contents/MacOS/InputFixture")))
    }

    func testLocationNormalizesBothSidesWithSymlinkSpacesAndEmoji() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("fixture-location-" + UUID().uuidString)
        let real = root.appendingPathComponent("Fixture Space 😀")
        let alias = root.appendingPathComponent("Fixture Alias 🚀")
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let executable = real.appendingPathComponent("InputFixture")
        try Data("synthetic fixture".utf8).write(to: executable)
        try manager.createSymbolicLink(at: alias, withDestinationURL: real)
        let aliasedExecutable = alias.appendingPathComponent("InputFixture")
        XCTAssertTrue(DiagnosticFixtureLocation.matches(actual: executable, expectedURL: aliasedExecutable))
        XCTAssertTrue(DiagnosticFixtureLocation.matches(actual: aliasedExecutable, expectedURL: executable))
    }

    func testLocationRejectsMissingURLAndDifferentExecutable() {
        XCTAssertFalse(DiagnosticFixtureLocation.matches(actual: nil))
        XCTAssertFalse(DiagnosticFixtureLocation.matches(actual: URL(fileURLWithPath:
            "/tmp/MacSwitcherInputFixture.app/Contents/MacOS/OtherFixture")))
    }

    func testFastTypesExactlySixPhysicalKeysAt15msIntervals() {
        let downs = DiagnosticFixturePlan.fast.edges.filter(\.isDown)
        XCTAssertEqual(downs.map(\.keyCode), [5, 4, 11, 2, 17, 45])
        XCTAssertEqual(downs.map(\.atMilliseconds), [0, 15, 30, 45, 60, 75])
    }

    func testContinuationPauses180msAfterFourthKeyBeforeFinalPair() {
        let downs = DiagnosticFixturePlan.continuation.edges.filter(\.isDown)
        XCTAssertEqual(downs.map(\.keyCode), [5, 4, 11, 2, 17, 45])
        XCTAssertEqual(downs.map(\.atMilliseconds), [0, 15, 30, 45, 225, 240])
    }

    func testTabAt110msThenPhysicalXMovesBetweenFixtureFields() {
        let downs = DiagnosticFixturePlan.tab.edges.filter(\.isDown)
        XCTAssertEqual(downs.map(\.keyCode), [5, 4, 11, 2, 48, 7])
        XCTAssertEqual(downs.map(\.atMilliseconds), [0, 15, 30, 45, 110, 150])
    }

    func testMixedDoubleShiftIsFastAndBothEdgesAreModifierEvents() {
        let edges = DiagnosticFixturePlan.doubleShift.edges
        XCTAssertEqual(edges.map(\.keyCode), [56, 56, 60, 60])
        XCTAssertEqual(edges.map(\.atMilliseconds), [0, 20, 60, 80])
        XCTAssertEqual(edges.map(\.isDown), [true, false, true, false])
        XCTAssertTrue(edges.allSatisfy(\.isShift))
    }

    func testTwoSinglesHave250msThinkingPauseAfterFirstRelease() {
        let edges = DiagnosticFixturePlan.twoSingles.edges
        XCTAssertEqual(edges.map(\.keyCode), [56, 56, 60, 60])
        XCTAssertEqual(edges.map(\.atMilliseconds), [0, 20, 270, 290])
        XCTAssertEqual(edges.map(\.isDown), [true, false, true, false])
        XCTAssertTrue(edges.allSatisfy(\.isShift))
    }

    func testEveryFixedPlanIsPairedOrderedAndContainsNoReturnOrCommand() {
        let allowed: Set<UInt16> = [5, 4, 11, 2, 17, 45, 48, 7, 56, 60]
        for plan in DiagnosticFixturePlan.allCases {
            let edges = plan.edges
            XCTAssertFalse(edges.isEmpty)
            XCTAssertEqual(edges.count % 2, 0)
            for index in stride(from: 0, to: edges.count, by: 2) {
                let down = edges[index]
                let up = edges[index + 1]
                XCTAssertTrue(allowed.contains(down.keyCode))
                XCTAssertTrue(down.isDown)
                XCTAssertFalse(up.isDown)
                XCTAssertEqual(down.keyCode, up.keyCode)
                XCTAssertEqual(down.isShift, up.isShift)
                XCTAssertGreaterThan(up.atMilliseconds, down.atMilliseconds)
                XCTAssertLessThanOrEqual(up.atMilliseconds - down.atMilliseconds, 250)
                if index > 0 { XCTAssertGreaterThan(down.atMilliseconds, edges[index - 1].atMilliseconds) }
            }
        }
    }

    func testFocusRequiresSameFrontmostProcessAndExactFrontWindow() {
        XCTAssertTrue(DiagnosticFixtureFocus.matches(expectedPID: 42, expectedWindowID: 77,
            frontmostPID: 42, frontWindowPID: 42, frontWindowID: 77))
        XCTAssertNil(DiagnosticFixtureFocus.failure(expectedPID: 42, expectedWindowID: 77,
            frontmostPID: 42, frontWindowPID: 42, frontWindowID: 77))
        for (pid, owner, window, expected): (Int32?, Int32?, UInt32?, DiagnosticFixtureFocusFailure) in [
            (43, 42, 77, .foregroundProcess), (42, 43, 77, .frontWindowOwner),
            (42, 42, 78, .frontWindowIdentity), (nil, 42, 77, .foregroundProcess),
            (42, nil, 77, .frontWindowUnavailable), (42, 42, nil, .frontWindowUnavailable)
        ] {
            XCTAssertFalse(DiagnosticFixtureFocus.matches(expectedPID: 42, expectedWindowID: 77,
                frontmostPID: pid, frontWindowPID: owner, frontWindowID: window))
            XCTAssertEqual(DiagnosticFixtureFocus.failure(expectedPID: 42, expectedWindowID: 77,
                frontmostPID: pid, frontWindowPID: owner, frontWindowID: window), expected)
        }
    }

    func testFixtureIdentityFailurePrecedesOtherFocusMismatches() {
        XCTAssertEqual(DiagnosticFixtureFocus.failure(expectedPID: 42, expectedWindowID: 77,
            fixtureIdentityMatches: false, frontmostPID: 43, frontWindowPID: nil, frontWindowID: nil),
            .fixtureIdentity)
    }

    func testForegroundFailurePrecedesUnavailableFrontWindow() {
        XCTAssertEqual(DiagnosticFixtureFocus.failure(expectedPID: 42, expectedWindowID: 77,
            frontmostPID: 43, frontWindowPID: nil, frontWindowID: nil), .foregroundProcess)
    }

    func testMissingExpectedProcessOrWindowCannotAuthorizeGlobalPosting() {
        XCTAssertFalse(DiagnosticFixtureFocus.matches(expectedPID: 0, expectedWindowID: 77,
            frontmostPID: 0, frontWindowPID: 0, frontWindowID: 77))
        XCTAssertEqual(DiagnosticFixtureFocus.failure(expectedPID: 0, expectedWindowID: 77,
            frontmostPID: 0, frontWindowPID: 0, frontWindowID: 77), .fixtureIdentity)
        XCTAssertFalse(DiagnosticFixtureFocus.matches(expectedPID: 42, expectedWindowID: 0,
            frontmostPID: 42, frontWindowPID: 42, frontWindowID: 0))
        XCTAssertEqual(DiagnosticFixtureFocus.failure(expectedPID: 42, expectedWindowID: 0,
            frontmostPID: 42, frontWindowPID: 42, frontWindowID: 0), .frontWindowIdentity)
    }
}
