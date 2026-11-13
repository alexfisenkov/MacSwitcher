import XCTest
@testable import RuSwitcher

final class RuntimeSelfCheckTests: XCTestCase {
    func testAllSyntheticProductionChecksPass() {
        let results = RuntimeSelfCheck.run()
        XCTAssertEqual(results.map(\.id), RuntimeSelfCheck.ID.allCases)
        XCTAssertTrue(results.allSatisfy(\.passed))
    }
}
