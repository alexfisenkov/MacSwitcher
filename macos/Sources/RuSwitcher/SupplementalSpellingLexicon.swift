import Foundation
import SQLite3

/// Exact spelling evidence from public word lists. These entries have no frequency
/// and never participate in prefix prediction or confidence ratios.
struct SupplementalSpellingLexicon: Sendable {
    enum LoadError: Error { case cannotOpen(String), invalidSchema(String), invalidMetadata(String) }

    private final class Database: @unchecked Sendable {
        private let connection: OpaquePointer
        private let lookup: OpaquePointer
        private let lock = NSLock()
        private var unavailable = false
        let count: Int

        init(url: URL, language: String) throws {
            var opened: OpaquePointer?
            let uri = url.absoluteString + "?mode=ro&immutable=1"
            guard sqlite3_open_v2(uri, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let opened else {
                if let opened { sqlite3_close(opened) }
                throw LoadError.cannotOpen(language)
            }
            guard sqlite3_exec(opened, "PRAGMA query_only=ON; PRAGMA cache_size=-1024; PRAGMA mmap_size=0;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(opened)
                throw LoadError.invalidSchema(language)
            }
            var metadata: OpaquePointer?
            guard sqlite3_prepare_v2(opened,
                "SELECT value FROM metadata WHERE key='entries' AND (SELECT user_version FROM pragma_user_version)=1 AND (SELECT value FROM metadata WHERE key='language')=?1",
                -1, &metadata, nil) == SQLITE_OK, let metadata else {
                if let metadata { sqlite3_finalize(metadata) }
                sqlite3_close(opened)
                throw LoadError.invalidSchema(language)
            }
            guard sqlite3_bind_text(metadata, 1, language, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
                sqlite3_finalize(metadata)
                sqlite3_close(opened)
                throw LoadError.invalidMetadata(language)
            }
            let entries: Int?
            if sqlite3_step(metadata) == SQLITE_ROW,
               let text = sqlite3_column_text(metadata, 0) {
                entries = Int(String(cString: text))
            } else { entries = nil }
            sqlite3_finalize(metadata)
            guard let entries, entries > 0 else {
                sqlite3_close(opened)
                throw LoadError.invalidMetadata(language)
            }
            var countQuery: OpaquePointer?
            guard sqlite3_prepare_v2(opened, "SELECT COUNT(*) FROM spellings", -1, &countQuery, nil) == SQLITE_OK,
                  let countQuery else {
                if let countQuery { sqlite3_finalize(countQuery) }
                sqlite3_close(opened)
                throw LoadError.invalidSchema(language)
            }
            let countMatches = sqlite3_step(countQuery) == SQLITE_ROW
                && sqlite3_column_type(countQuery, 0) == SQLITE_INTEGER
                && sqlite3_column_int64(countQuery, 0) == Int64(entries)
            sqlite3_finalize(countQuery)
            guard countMatches else {
                sqlite3_close(opened)
                throw LoadError.invalidMetadata(language)
            }
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(opened, "SELECT word FROM spellings WHERE word=?1", -1, &prepared, nil) == SQLITE_OK,
                  let prepared else {
                if let prepared { sqlite3_finalize(prepared) }
                sqlite3_close(opened)
                throw LoadError.invalidSchema(language)
            }
            connection = opened
            lookup = prepared
            count = entries
        }

        deinit { sqlite3_finalize(lookup); sqlite3_close(connection) }

        /// false means known absence; nil means the database could not answer.
        func contains(_ word: String) -> Bool? {
            lock.lock()
            defer { sqlite3_reset(lookup); sqlite3_clear_bindings(lookup); lock.unlock() }
            guard !unavailable else { return nil }
            guard sqlite3_bind_text(lookup, 1, word, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
                unavailable = true
                return nil
            }
            switch sqlite3_step(lookup) {
            case SQLITE_DONE: return false
            case SQLITE_ROW:
                guard sqlite3_column_type(lookup, 0) == SQLITE_TEXT,
                      let matched = sqlite3_column_text(lookup, 0),
                      String(cString: matched) == word else {
                    unavailable = true
                    return nil
                }
                return true
            default:
                unavailable = true
                return nil
            }
        }
    }

    private let databases: [String: Database]
    private let fixtureWords: [String: Set<String>]
    let wordCounts: [String: Int]

    init(wordsByLanguage: [String: Set<String>] = [:]) {
        var normalized: [String: Set<String>] = [:]
        for (language, words) in wordsByLanguage {
            let code = PredictionLexicon.languageCode(language)
            normalized[code, default: []].formUnion(words.map(PredictionLexicon.normalize))
        }
        databases = [:]
        fixtureWords = normalized
        wordCounts = normalized.mapValues(\.count)
    }

    init(urlsByLanguage: [String: URL]) throws {
        var loaded: [String: Database] = [:]
        for (language, url) in urlsByLanguage {
            let code = PredictionLexicon.languageCode(language)
            loaded[code] = try Database(url: url, language: code)
        }
        databases = loaded
        fixtureWords = [:]
        wordCounts = loaded.mapValues(\.count)
    }

    func contains(_ word: String, language: String) -> Bool? {
        let code = PredictionLexicon.languageCode(language)
        let normalized = PredictionLexicon.normalize(word)
        if let database = databases[code] { return database.contains(normalized) }
        // Pure fixtures have known absence; a loaded database that fails is nil.
        return fixtureWords[code]?.contains(normalized) ?? false
    }
}
