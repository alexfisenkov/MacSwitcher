import Foundation
import SQLite3

/// Full public corpus is an exact-lookup backstop, never a prefix predictor. SQLite
/// keeps millions of rare forms on disk instead of allocating millions of Strings.
struct FullFrequencyLexicon: Sendable {
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
            // Bounded per-language cache; no writable journal, temp table, or mmap of
            // the full database. The immutable URI is valid for packaged resources.
            sqlite3_exec(opened, "PRAGMA query_only=ON; PRAGMA cache_size=-1024; PRAGMA mmap_size=0;", nil, nil, nil)
            var metadata: OpaquePointer?
            guard sqlite3_prepare_v2(opened, "SELECT value FROM metadata WHERE key='entries' AND (SELECT user_version FROM pragma_user_version)=1 AND (SELECT value FROM metadata WHERE key='language')=?1", -1, &metadata, nil) == SQLITE_OK,
                  let metadata else {
                if let metadata { sqlite3_finalize(metadata) }
                sqlite3_close(opened)
                throw LoadError.invalidSchema(language)
            }
            sqlite3_bind_text(metadata, 1, language, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let parsedCount = sqlite3_step(metadata) == SQLITE_ROW ? Int(sqlite3_column_int64(metadata, 0)) : 0
            sqlite3_finalize(metadata)
            guard parsedCount > 0 else {
                sqlite3_close(opened)
                throw LoadError.invalidMetadata(language)
            }
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(opened, "SELECT frequency FROM frequencies WHERE word=?1", -1, &prepared, nil) == SQLITE_OK,
                  let prepared else {
                if let prepared { sqlite3_finalize(prepared) }
                sqlite3_close(opened)
                throw LoadError.invalidSchema(language)
            }
            connection = opened
            lookup = prepared
            count = parsedCount
        }

        deinit { sqlite3_finalize(lookup); sqlite3_close(connection) }

        /// Zero means SQLITE_DONE (absent), nil means an unavailable/corrupt read.
        /// A failed immutable database stays unavailable for this lexicon lifetime.
        func frequency(of word: String) -> Int? {
            lock.lock()
            defer { sqlite3_reset(lookup); sqlite3_clear_bindings(lookup); lock.unlock() }
            guard !unavailable else { return nil }
            guard sqlite3_bind_text(lookup, 1, word, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
                unavailable = true
                return nil
            }
            switch sqlite3_step(lookup) {
            case SQLITE_DONE: return 0
            case SQLITE_ROW:
                let value = sqlite3_column_int64(lookup, 0)
                guard sqlite3_column_type(lookup, 0) == SQLITE_INTEGER, value > 0 else {
                    unavailable = true
                    return nil
                }
                return Int(value)
            default:
                unavailable = true
                return nil
            }
        }
    }

    private let databases: [String: Database]
    private let fixtureWords: [String: [String: Int]]
    let wordCounts: [String: Int]

    init(wordsByLanguage: [String: [String: Int]] = [:]) {
        var normalized: [String: [String: Int]] = [:]
        for (language, words) in wordsByLanguage {
            let code = PredictionLexicon.languageCode(language)
            for (word, frequency) in words where frequency > 0 {
                let key = PredictionLexicon.normalize(word)
                normalized[code, default: [:]][key] = max(normalized[code]?[key] ?? 0, frequency)
            }
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

    func frequency(of word: String, language: String) -> Int? {
        let code = PredictionLexicon.languageCode(language)
        let normalized = PredictionLexicon.normalize(word)
        if let database = databases[code] { return database.frequency(of: normalized) }
        // Pure fixtures intentionally have no full database; that is known absence,
        // unlike a resource that was loaded but could not answer a query.
        return fixtureWords[code]?[normalized] ?? 0
    }
}
