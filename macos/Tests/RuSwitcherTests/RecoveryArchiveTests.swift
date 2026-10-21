import XCTest
@testable import RuSwitcher

final class RecoveryArchiveTests: XCTestCase {
    func testAllOriginalsRoundTripExactlyAndStayPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = [RecoveryArchive.Source(id: UUID(), text: "😀 e\u{301} ghbdtn\nfirst"),
                         RecoveryArchive.Source(id: UUID(), text: "second привет\n\n")]
        let file = try RecoveryArchive.save(originals, in: directory)
        let payload = try JSONDecoder().decode(RecoveryArchive.Payload.self, from: Data(contentsOf: file))
        XCTAssertEqual(payload.originals, originals)
        XCTAssertEqual(payload.schema, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let secondFile = try RecoveryArchive.save(originals, in: directory)
        XCTAssertNotEqual(file, secondFile)
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: secondFile))
    }

    func testInvalidAndUnwritableDestinationsCannotReportASavedArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try RecoveryArchive.save([], in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let source = RecoveryArchive.Source(id: UUID(), text: "synthetic")
        XCTAssertThrowsError(try RecoveryArchive.save(Array(repeating: source, count: 9), in: directory))
        try Data("not a directory".utf8).write(to: directory)
        XCTAssertThrowsError(try RecoveryArchive.save([source], in: directory))
    }
}
