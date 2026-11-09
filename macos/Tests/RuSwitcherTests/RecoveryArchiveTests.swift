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

    func testSyncFailureNeverProducesReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RecoveryArchive.Source(id: UUID(), text: "synthetic")
        XCTAssertThrowsError(try RecoveryArchive.saveVerified([source], in: directory,
            syncer: { _, isDirectory in
                if !isDirectory { throw RecoveryArchive.Failure.syncFailed }
            }))
        for _ in 0..<260 {
            XCTAssertThrowsError(try RecoveryArchive.saveVerified([source], in: directory,
                syncer: { _, isDirectory in
                    if !isDirectory { throw RecoveryArchive.Failure.syncFailed }
                }))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 0,
            "Failed exports must not spend the 256-file quota")
    }

    func testArchiveFileCountLimitRefusesWithoutDeletingPriorExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<256 {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("existing-\(index)"),
                withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try RecoveryArchive.saveVerified([.init(id: UUID(), text: "synthetic")], in: directory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 256)
    }

    func testExplicitReadRejectsReplacedOrOversizedArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RecoveryArchive.Source(id: UUID(), text: "synthetic")
        let receipt = try RecoveryArchive.saveVerified([source], in: directory)
        XCTAssertEqual(try RecoveryArchive.original(id: source.id, receipt: receipt), source.text)
        try Data(repeating: 65, count: receipt.payloadBytes + 1).write(to: receipt.file, options: .atomic)
        XCTAssertThrowsError(try RecoveryArchive.original(id: source.id, receipt: receipt))
    }
}
