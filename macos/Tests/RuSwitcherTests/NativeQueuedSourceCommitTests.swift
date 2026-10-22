import XCTest
@testable import RuSwitcher

final class NativeQueuedSourceCommitTests: XCTestCase {
    @MainActor
    func testExplicitCommitRequestsObservedSource() {
        var source = "en"
        let commit = NativeQueuedSourceCommit(isCurrent: { true }, request: { target in
            source = target
            return .confirmed
        })
        // The production caller invokes this only after text ACK, while its
        // input lease still holds physical events.
        commit.textQueued(targetID: "ru")
        XCTAssertEqual(source, "ru")
        XCTAssertEqual(commit.confirmedLayoutID, "ru")
        XCTAssertEqual(commit.outcome, .confirmed)
    }

    @MainActor
    func testNoTextQueuedAndDuplicateReceiptsNeverMakeExtraSourceRequests() {
        var requests = 0
        let commit = NativeQueuedSourceCommit(isCurrent: { true }, request: { _ in
            requests += 1
            return .confirmed
        })
        XCTAssertEqual(requests, 0)
        commit.textQueued(targetID: "")
        XCTAssertEqual(requests, 0)
        commit.textQueued(targetID: "ru")
        commit.textQueued(targetID: "en")
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(commit.confirmedLayoutID, "ru")
    }

    @MainActor
    func testInvalidLeaseNeverRequestsSourceAndRefusalIsNotConfirmed() {
        let invalid = NativeQueuedSourceCommit(isCurrent: { false }, request: { _ in
            XCTFail("No source request outside the original input lease")
            return .confirmed
        })
        invalid.textQueued(targetID: "ru")
        XCTAssertEqual(invalid.outcome, .refused)
        XCTAssertNil(invalid.confirmedLayoutID)
        let refused = NativeQueuedSourceCommit(isCurrent: { true }, request: { _ in .refused })
        refused.textQueued(targetID: "ru")
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertNil(refused.confirmedLayoutID)
    }

    @MainActor
    func testUnconfirmedOrExpiredSourceRequestRetainsLateTransitionTracking() {
        for expires in [false, true] {
            var current = true
            var pending: [String] = []
            let commit = NativeQueuedSourceCommit(isCurrent: { current }, request: { _ in
                if expires { current = false }
                return expires ? .confirmed : .unconfirmed
            }, onUnconfirmed: { pending.append($0) })
            commit.textQueued(targetID: "ru")
            XCTAssertEqual(commit.outcome, .unconfirmed)
            XCTAssertEqual(pending, ["ru"])
            XCTAssertNil(commit.confirmedLayoutID)
        }
    }
}
