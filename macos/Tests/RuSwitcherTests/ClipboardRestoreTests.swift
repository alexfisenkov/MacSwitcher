import AppKit
import XCTest
@testable import RuSwitcher

final class ClipboardRestoreTests: XCTestCase {
    @MainActor
    private func isolatedPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("MacSwitcher.ClipboardTests.\(UUID().uuidString)"))
    }

    @MainActor
    func testRestoreReturnsOriginalOnlyWhileTemporaryValueIsOurs() {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.setString("initial", forType: .string)
        let session = ClipboardRestoreSession(pasteboard: pasteboard)
        XCTAssertTrue(session.begin())
        XCTAssertTrue(session.writeTemporaryText("converted"))
        XCTAssertTrue(session.restoreIfOwned())
        XCTAssertEqual(pasteboard.string(forType: .string), "initial")
        XCTAssertFalse(session.hasSnapshot)
    }

    @MainActor
    func testUserCopySurvivesBothDelayedRestoreAndFlush() {
        for _ in 0..<2 { // timer and flush share this exact restore entry point
            let pasteboard = isolatedPasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents(); pasteboard.setString("initial", forType: .string)
            let session = ClipboardRestoreSession(pasteboard: pasteboard)
            XCTAssertTrue(session.begin())
            XCTAssertTrue(session.writeTemporaryText("converted"))
            pasteboard.clearContents(); pasteboard.setString("new user copy", forType: .string)
            let userVersion = pasteboard.changeCount
            XCTAssertFalse(session.restoreIfOwned())
            XCTAssertEqual(pasteboard.changeCount, userVersion)
            XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
            XCTAssertFalse(session.hasSnapshot)
        }
    }

    @MainActor
    func testRapidReconvertPreservesFirstSnapshotButNewCopyStartsFreshTransaction() {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.setString("initial", forType: .string)
        let session = ClipboardRestoreSession(pasteboard: pasteboard)
        XCTAssertTrue(session.begin())
        XCTAssertTrue(session.writeTemporaryText("converted"))
        XCTAssertTrue(session.begin())
        XCTAssertTrue(session.writeTemporaryText("reconverted"))
        XCTAssertTrue(session.restoreIfOwned())
        XCTAssertEqual(pasteboard.string(forType: .string), "initial")

        XCTAssertTrue(session.begin())
        XCTAssertTrue(session.writeTemporaryText("second conversion"))
        pasteboard.clearContents(); pasteboard.setString("new user copy", forType: .string)
        XCTAssertTrue(session.begin()) // stale original must be discarded before reconvert
        XCTAssertTrue(session.writeTemporaryText("second reconversion"))
        XCTAssertTrue(session.restoreIfOwned())
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    @MainActor
    func testUnknownClipboardWriteCannotBeClearedByRetryOrPaste() {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.setString("initial", forType: .string)
        let session = ClipboardRestoreSession(pasteboard: pasteboard)
        XCTAssertTrue(session.begin())
        XCTAssertNotNil(session.clearForCopy())
        pasteboard.clearContents(); pasteboard.setString("unknown new copy", forType: .string)
        let newVersion = pasteboard.changeCount
        XCTAssertFalse(session.permitsPaste())
        XCTAssertNil(session.clearForCopy())
        XCTAssertFalse(session.writeTemporaryText("must not write"))
        XCTAssertFalse(session.restoreIfOwned())
        XCTAssertEqual(pasteboard.changeCount, newVersion)
        XCTAssertEqual(pasteboard.string(forType: .string), "unknown new copy")
    }

    @MainActor
    func testVerifiedCopyVersionCanBeClaimedButStaleObservedCountCannot() {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.setString("initial", forType: .string)
        let session = ClipboardRestoreSession(pasteboard: pasteboard)
        XCTAssertTrue(session.begin())
        XCTAssertNotNil(session.clearForCopy())
        pasteboard.clearContents(); pasteboard.setString("verified selection", forType: .string)
        let verifiedCount = pasteboard.changeCount
        XCTAssertTrue(session.claimVerifiedCopy(changeCount: verifiedCount))
        XCTAssertTrue(session.writeTemporaryText("converted"))
        pasteboard.clearContents(); pasteboard.setString("new user copy", forType: .string)
        XCTAssertFalse(session.claimVerifiedCopy(changeCount: verifiedCount))
        XCTAssertFalse(session.restoreIfOwned())
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }
}
