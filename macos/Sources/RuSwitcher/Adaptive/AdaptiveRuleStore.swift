import Foundation
import Darwin

/// Private word-only cache. Failed reads leave the base prediction engine usable.
final class AdaptiveRuleStore: @unchecked Sendable {
    enum StoreError: Error { case invalid, unavailable, readOnly, limit }
    private struct Document: Codable { let schema: Int; var rules: [AdaptiveRule] }
    static let shared = AdaptiveRuleStore()
    static let didChange = Notification.Name("MacSwitcherAdaptiveRulesDidChange")
    private static let maxBytes = 512 * 1024
    private static let maxRules = 2_000
    private let lock = NSLock()
    private let url: URL
    private let postReplaceReadback: @Sendable (URL) throws -> Data
    private let cleanupArtifact: @Sendable (URL) throws -> Void
    private var document = Document(schema: 1, rules: [])
    private var seen: Set<UUID> = []
    private var withdrawn: Set<UUID> = []
    private var votes: [UUID: AdaptiveVote] = [:]
    private var seenOrder: [UUID] = []
    private var generation: UInt64 = 0
    private var error: String?
    private var writeError: String?
    private var cleanupWarning: String?
    private var enabled: Bool

    init(fileURL: URL? = nil, enabled: Bool = false,
         postReplaceReadback: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
         cleanupArtifact: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = fileURL ?? support.appendingPathComponent("MacSwitcher", isDirectory: true)
            .appendingPathComponent("adaptive-rules.json")
        self.enabled = enabled
        self.postReplaceReadback = postReplaceReadback
        self.cleanupArtifact = cleanupArtifact
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                guard !Self.isSymlink(url) else { throw StoreError.invalid }
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                guard (size?.intValue ?? Int.max) <= Self.maxBytes else { throw StoreError.limit }
                document = try Self.decode(Data(contentsOf: url))
                retryOwnedArtifactCleanup()
            } else {
                // A first-write crash may leave a private temp without a main
                // document. Never discard a backup that could be the only old copy.
                retryOwnedArtifactCleanup(allowBackupCleanup: false)
            }
        } catch { self.error = "Правила недоступны: файл повреждён или имеет неизвестный формат. Файл сохранён без изменений." }
    }

    var readOnlyError: String? { lock.withLock { error ?? writeError ?? cleanupWarning } }
    var currentGeneration: UInt64 { lock.withLock { generation } }
    func rules() -> [AdaptiveRule] { lock.withLock { enabled && error == nil ? document.rules : [] } }
    func allRules() -> [AdaptiveRule] { lock.withLock { document.rules } }

    func setEnabled(_ value: Bool) {
        // Keep bounded occurrence metadata so a later confirmed undo can retract
        // its pre-toggle vote. The generation still cancels queued old work.
        lock.withLock { enabled = value; generation &+= 1 }
    }

    /// Caller captures generation before dispatch; saving verifies it under the same lock.
    @discardableResult func record(_ evidence: AdaptiveEvidence, generation expected: UInt64) throws -> Bool {
        let changed = try lock.withLock {
            guard enabled, expected == generation else { return false }
            guard error == nil else { throw StoreError.readOnly }
            var copy = document
            let prior = copy.rules
            var updatedSeen = seen
            var updatedWithdrawn = withdrawn
            var updatedVotes = votes
            AdaptiveRulePolicy.apply(evidence, to: &copy.rules, seen: &updatedSeen,
                withdrawn: &updatedWithdrawn, votes: &updatedVotes)
            guard copy.rules != prior else { return false }
            try Self.validate(copy)
            do { try save(copy); writeError = nil }
            catch { writeError = "Не удалось сохранить правила на диске."; throw error }
            document = copy
            seen = updatedSeen
            withdrawn = updatedWithdrawn
            votes = updatedVotes
            if case .manualConfirmed(let id, _, _) = evidence { retain(id) }
            if case .automaticUndoConfirmed(let id, _, _) = evidence { retain(id) }
            return true
        }
        if changed { notifyChanged() }
        return changed
    }

    func delete(_ pair: AdaptiveWordPair) throws {
        try lock.withLock {
            generation &+= 1
            guard error == nil else { throw StoreError.readOnly }
            var copy = document
            copy.rules.removeAll { $0.pair == pair }
            do { try save(copy); writeError = nil }
            catch { writeError = "Не удалось сохранить правила на диске."; throw error }
            document = copy
            votes = votes.filter { $0.value.pair != pair }
            retryOwnedArtifactCleanup()
        }
        notifyChanged()
    }

    func reset() throws {
        try lock.withLock {
            generation &+= 1
            guard error == nil else { throw StoreError.readOnly }
            let empty = Document(schema: 1, rules: [])
            do { try save(empty); writeError = nil }
            catch { writeError = "Не удалось сохранить правила на диске."; throw error }
            document = empty
            withdrawn.removeAll(); votes.removeAll()
            retryOwnedArtifactCleanup()
        }
        notifyChanged()
    }

    private func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    /// Only exact, regular artifacts of this writer are retried. A damaged current
    /// document never reaches this path, preserving any possible recovery copy.
    private func retryOwnedArtifactCleanup(allowBackupCleanup: Bool = true) {
        let directory = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var incomplete = false
        for name in names where Self.isOwnedArtifactName(name) {
            if name.hasPrefix(".adaptive-backup-"), !allowBackupCleanup {
                incomplete = true
                continue
            }
            let artifact = directory.appendingPathComponent(name)
            guard !Self.isSymlink(artifact),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: artifact.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else {
                incomplete = true; continue
            }
            if name.hasPrefix(".adaptive-backup-"),
               (try? Self.decode(Data(contentsOf: artifact))) == nil {
                incomplete = true; continue
            }
            do { try cleanupArtifact(artifact) }
            catch { incomplete = true }
        }
        cleanupWarning = incomplete
            ? "Очистка старых служебных копий не завершена. Повторите сброс или перезапустите приложение."
            : nil
    }

    private static func isOwnedArtifactName(_ name: String) -> Bool {
        if name.hasPrefix(".adaptive-backup-") {
            return UUID(uuidString: String(name.dropFirst(".adaptive-backup-".count))) != nil
        }
        if name.hasPrefix(".adaptive-"), name.hasSuffix(".tmp") {
            return UUID(uuidString: String(name.dropFirst(".adaptive-".count).dropLast(4))) != nil
        }
        return false
    }

    private func retain(_ id: UUID) {
        seenOrder.append(id)
        if seenOrder.count > 256 {
            let old = seenOrder.removeFirst()
            seen.remove(old); withdrawn.remove(old); votes.removeValue(forKey: old)
        }
    }

    private static func validate(_ doc: Document) throws {
        guard doc.schema == 1, doc.rules.count <= maxRules,
              Set(doc.rules.map(\.pair)).count == doc.rules.count,
              doc.rules.allSatisfy({ rule in
                  rule.confirmations == 1 || rule.confirmations == 2
              }) else { throw StoreError.invalid }
        for rule in doc.rules {
            guard let pair = AdaptiveWordPair.make(rule.pair.en, rule.pair.ru),
                  pair.pair == rule.pair, ["ru", "en"].contains(rule.preferred) else { throw StoreError.invalid }
        }
    }

    private static func decode(_ data: Data) throws -> Document {
        guard data.count <= maxBytes,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == Set(["schema", "rules"]),
              let records = raw["rules"] as? [[String: Any]],
              records.allSatisfy({ record in
                  Set(record.keys) == Set(["pair", "preferred", "confirmations", "confirmedAt", "lastOccurrenceID"])
                  && (record["pair"] as? [String: Any]).map { Set($0.keys) == Set(["ru", "en"]) } == true
              }),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { throw StoreError.invalid }
        try validate(doc)
        return doc
    }

    private func save(_ doc: Document) throws {
        let data = try JSONEncoder().encode(doc)
        guard data.count <= Self.maxBytes else { throw StoreError.limit }
        let directory = url.deletingLastPathComponent()
        guard !Self.isSymlink(directory), !Self.isSymlink(url) else { throw StoreError.unavailable }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard chmod(directory.path, 0o700) == 0 else { throw StoreError.unavailable }
            let temp = directory.appendingPathComponent(".adaptive-\(UUID().uuidString).tmp")
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw StoreError.unavailable }
            defer {
                close(fd)
                if FileManager.default.fileExists(atPath: temp.path) {
                    do { try cleanupArtifact(temp) }
                    catch {
                        cleanupWarning = "Очистка старых служебных копий не завершена. Повторите сброс или перезапустите приложение."
                    }
                }
            }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw StoreError.unavailable }
                    offset += count
                }
            }
            guard fsync(fd) == 0,
                  (try Self.decode(Data(contentsOf: temp))).rules == doc.rules else {
                throw StoreError.unavailable
            }
            // Keep the previous inode until the new file passes an independent read-back.
            // A hard link is private, same-volume and does not copy personal data elsewhere.
            let backup = directory.appendingPathComponent(".adaptive-backup-\(UUID().uuidString)")
            let hadPrevious = FileManager.default.fileExists(atPath: url.path)
            if hadPrevious { guard link(url.path, backup.path) == 0 else { throw StoreError.unavailable } }
            guard rename(temp.path, url.path) == 0 else {
                if hadPrevious {
                    do { try cleanupArtifact(backup) }
                    catch {
                        cleanupWarning = "Очистка старых служебных копий не завершена. Повторите сброс или перезапустите приложение."
                    }
                }
                throw StoreError.unavailable
            }
            do {
                let readBack = try Self.decode(postReplaceReadback(url))
                guard readBack.rules == doc.rules else { throw StoreError.unavailable }
            } catch {
                let restored = hadPrevious
                    ? rename(backup.path, url.path) == 0
                    : unlink(url.path) == 0
                guard restored else {
                    // Preserve the only old copy for manual recovery; routine
                    // startup cleanup deliberately ignores recovery artifacts.
                    if hadPrevious {
                        let recovery = directory.appendingPathComponent(".adaptive-recovery-\(UUID().uuidString)")
                        _ = rename(backup.path, recovery.path)
                    }
                    throw StoreError.unavailable
                }
                throw StoreError.unavailable
            }
            // Cleanup is best effort: a committed/read-back-verified write remains success.
            if hadPrevious {
                do { try cleanupArtifact(backup) }
                catch {
                    cleanupWarning = "Очистка старых служебных копий не завершена. Повторите сброс или перезапустите приложение."
                }
            }
        } catch { throw StoreError.unavailable }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return (attr[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
