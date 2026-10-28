import XCTest
@testable import RuSwitcher

final class CorrectionExceptionOfferTests: XCTestCase {
    func testOversizedPersonalDictionaryIsPreservedAndReportsSizeLimit() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("PersonalDictionary.json")
        let data = Data(repeating: 0x61, count: 1_048_577)
        try data.write(to: file)
        let store = PersonalWordStore(fileURL: file)
        XCTAssertEqual(store.readOnlyError, PersonalWordStore.StoreError.tooLarge.localizedDescription)
        XCTAssertThrowsError(try store.addWord("example", language: "en"))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    @MainActor
    func testOnlyExplicitAcceptancePersistsPhraseAfterConfirmedUndoOffer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalWordStore(fileURL: directory.appendingPathComponent("PersonalDictionary.json"))
        let policy = CorrectionExceptionOfferPolicy(store: store)
        let notice = ConfirmedCorrectionNotice(id: UUID(), original: "ghbdtn",
            replacement: "привет", sourceLanguage: "en")

        XCTAssertTrue(policy.stage(notice))
        XCTAssertTrue(store.phrases().isEmpty)
        policy.dismiss()
        XCTAssertTrue(store.phrases().isEmpty)
        XCTAssertFalse(policy.stage(notice))

        let another = ConfirmedCorrectionNotice(id: UUID(), original: "rjvgr",
            replacement: "комик", sourceLanguage: "en")
        XCTAssertTrue(policy.stage(another))
        XCTAssertTrue(try policy.accept())
        XCTAssertEqual(store.phrases().count, 1)
        XCTAssertTrue(store.containsPhrase(original: "rjvgr", sourceLanguage: "en"))
        XCTAssertFalse(try policy.accept())
    }

    @MainActor
    func testFailedSaveDoesNotLearnPhrase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("PersonalDictionary.json")
        try Data("not a dictionary".utf8).write(to: file)
        let store = PersonalWordStore(fileURL: file)
        let policy = CorrectionExceptionOfferPolicy(store: store)
        let notice = ConfirmedCorrectionNotice(id: UUID(), original: "ghbdtn",
            replacement: "привет", sourceLanguage: "en")
        XCTAssertTrue(policy.stage(notice))
        XCTAssertThrowsError(try policy.accept())
        XCTAssertTrue(store.phrases().isEmpty)
        XCTAssertNil(policy.pending)
    }
}
