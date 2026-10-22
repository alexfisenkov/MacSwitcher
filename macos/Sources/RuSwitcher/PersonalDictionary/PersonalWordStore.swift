import Foundation
import Darwin

/// Explicit, local user entries. No typed text is learned or logged.
final class PersonalWordStore: @unchecked Sendable {
    struct PersonalWord: Codable, Hashable, Sendable {
        let word: String
        let language: String
    }

    struct PhraseException: Codable, Hashable, Sendable {
        let original: String
        let replacement: String
        let sourceLanguage: String
    }

    enum StoreError: LocalizedError {
        case invalidEntry, invalidFormat, tooLarge, readOnly, unavailable

        var errorDescription: String? {
            switch self {
            case .invalidEntry: return "Invalid dictionary entry."
            case .invalidFormat: return "The dictionary format is damaged or from a newer version."
            case .tooLarge: return "The dictionary limit has been reached."
            case .readOnly: return "The existing dictionary cannot be changed."
            case .unavailable: return "The local dictionary could not be saved."
            }
        }
    }

    private struct Document: Codable {
        let version: Int
        var words: [PersonalWord]
        var phrases: [PhraseException]
    }

    static let shared = PersonalWordStore()
    private static let maxBytes = 1_048_576
    private static let maxWords = 2_000
    private static let maxPhrases = 500
    private let lock = NSLock()
    private let fileURL: URL
    private var document = Document(version: 1, words: [], phrases: [])
    private var wordKeys: Set<String> = []
    private var phraseKeys: Set<String> = []
    private var loadError: String?

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? support.appendingPathComponent("MacSwitcher", isDirectory: true)
            .appendingPathComponent("PersonalDictionary.json")
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                guard !Self.isSymlink(self.fileURL) else { throw StoreError.invalidFormat }
                let attributes = try FileManager.default.attributesOfItem(atPath: self.fileURL.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= Self.maxBytes else { throw StoreError.tooLarge }
                document = try Self.decode(Data(contentsOf: self.fileURL))
                wordKeys = Self.wordKeys(for: document)
                phraseKeys = Self.phraseKeys(for: document)
            }
        } catch {
            loadError = StoreError.invalidFormat.localizedDescription
        }
    }

    var readOnlyError: String? { lock.withLock { loadError } }
    func words() -> [PersonalWord] { lock.withLock { document.words } }
    func phrases() -> [PhraseException] { lock.withLock { document.phrases } }

    func containsWord(_ word: String, language: String) -> Bool {
        lock.withLock { wordKeys.contains(language + "\0" + Self.fold(word)) }
    }

    func containsPhrase(original: String, sourceLanguage: String) -> Bool {
        lock.withLock { phraseKeys.contains(sourceLanguage + "\0" + original) }
    }

    func addWord(_ word: String, language: String) throws {
        guard Self.validWord(word), Self.validLanguage(language) else { throw StoreError.invalidEntry }
        try mutate { doc in
            if !doc.words.contains(where: { $0.language == language && Self.fold($0.word) == Self.fold(word) }) {
                doc.words.append(PersonalWord(word: word, language: language))
            }
        }
    }

    func removeWord(_ word: String, language: String) throws {
        try mutate { doc in
            doc.words.removeAll { $0.language == language && Self.fold($0.word) == Self.fold(word) }
        }
    }

    func addPhrase(original: String, replacement: String, sourceLanguage: String) throws {
        guard Self.validPhrase(original), Self.validPhrase(replacement), Self.validLanguage(sourceLanguage),
              original != replacement else { throw StoreError.invalidEntry }
        try mutate { doc in
            if !doc.phrases.contains(where: { $0.original == original && $0.sourceLanguage == sourceLanguage }) {
                doc.phrases.append(PhraseException(original: original, replacement: replacement,
                                                   sourceLanguage: sourceLanguage))
            }
        }
    }

    func removePhrase(original: String, sourceLanguage: String) throws {
        try mutate { doc in
            doc.phrases.removeAll { $0.original == original && $0.sourceLanguage == sourceLanguage }
        }
    }

    func exportData() throws -> Data {
        try lock.withLock {
            guard loadError == nil else { throw StoreError.readOnly }
            return try JSONEncoder().encode(document)
        }
    }

    /// Import replaces the two complete lists after strict validation; a failed import preserves the old file.
    func importData(_ data: Data) throws {
        let imported = try Self.decode(data)
        try lock.withLock {
            guard loadError == nil else { throw StoreError.readOnly }
            try save(imported)
            document = imported
            wordKeys = Self.wordKeys(for: imported)
            phraseKeys = Self.phraseKeys(for: imported)
        }
    }

    private func mutate(_ change: (inout Document) -> Void) throws {
        try lock.withLock {
            guard loadError == nil else { throw StoreError.readOnly }
            var copy = document
            change(&copy)
            try Self.validate(copy)
            try save(copy)
            document = copy
            wordKeys = Self.wordKeys(for: copy)
            phraseKeys = Self.phraseKeys(for: copy)
        }
    }

    private func save(_ value: Document) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maxBytes else { throw StoreError.tooLarge }
        let directory = fileURL.deletingLastPathComponent()
        guard !Self.isSymlink(directory), !Self.isSymlink(fileURL) else { throw StoreError.unavailable }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard chmod(directory.path, 0o700) == 0 else { throw StoreError.unavailable }
            let temporary = directory.appendingPathComponent(".PersonalDictionary-\(UUID().uuidString).tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw StoreError.unavailable }
            defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw StoreError.unavailable }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0, rename(temporary.path, fileURL.path) == 0 else {
                throw StoreError.unavailable
            }
        } catch {
            throw StoreError.unavailable
        }
    }

    private static func decode(_ data: Data) throws -> Document {
        guard data.count <= maxBytes,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == Set(["version", "words", "phrases"]),
              let version = raw["version"] as? Int, version == 1,
              let words = raw["words"] as? [[String: Any]],
              let phrases = raw["phrases"] as? [[String: Any]],
              words.allSatisfy({ Set($0.keys) == Set(["word", "language"]) }),
              phrases.allSatisfy({ Set($0.keys) == Set(["original", "replacement", "sourceLanguage"]) }),
              let result = try? JSONDecoder().decode(Document.self, from: data) else {
            throw StoreError.invalidFormat
        }
        try validate(result)
        return result
    }

    private static func validate(_ value: Document) throws {
        guard value.version == 1, value.words.count <= maxWords, value.phrases.count <= maxPhrases,
              value.words.allSatisfy({ validWord($0.word) && validLanguage($0.language) }),
              value.phrases.allSatisfy({ validPhrase($0.original) && validPhrase($0.replacement)
                  && validLanguage($0.sourceLanguage) && $0.original != $0.replacement }),
              wordKeys(for: value).count == value.words.count,
              phraseKeys(for: value).count == value.phrases.count
        else { throw StoreError.invalidEntry }
    }

    private static func validLanguage(_ language: String) -> Bool { language == "ru" || language == "en" }
    private static func fold(_ text: String) -> String { text.lowercased().precomposedStringWithCanonicalMapping }
    private static func wordKeys(for value: Document) -> Set<String> {
        Set(value.words.map { $0.language + "\0" + fold($0.word) })
    }
    private static func phraseKeys(for value: Document) -> Set<String> {
        Set(value.phrases.map { $0.sourceLanguage + "\0" + $0.original })
    }
    private static func validWord(_ word: String) -> Bool {
        guard !word.isEmpty, word.utf8.count <= 128, word.count <= 64 else { return false }
        let punctuation = CharacterSet(charactersIn: "-'’")
        return word.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || punctuation.contains($0)
        }
    }
    private static func validPhrase(_ phrase: String) -> Bool {
        !phrase.trimmingCharacters(in: .whitespaces).isEmpty && phrase.count <= 160 &&
        phrase.utf8.count <= 512 && !phrase.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
