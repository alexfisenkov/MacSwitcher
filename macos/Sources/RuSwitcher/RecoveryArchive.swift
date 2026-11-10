import Foundation
import CryptoKit
import Darwin

/// Local export only; callers decide when the user has authorized persistence.
enum RecoveryArchive {
    struct Source: Codable, Equatable, Sendable {
        let id: UUID
        let text: String
    }
    struct Payload: Codable, Equatable, Sendable {
        let schema: Int
        let originals: [Source]
    }
    struct Receipt: Sendable {
        let file: URL
        let digests: [UUID: Data]
        let payloadBytes: Int
        let payloadDigest: Data
        fileprivate init(file: URL, digests: [UUID: Data], payloadBytes: Int, payloadDigest: Data) {
            self.file = file; self.digests = digests
            self.payloadBytes = payloadBytes; self.payloadDigest = payloadDigest
        }
    }
    enum Failure: Error, Equatable { case invalidSources, verificationFailed, syncFailed, writeFailed, archiveLimit }
    private static let maximumExports = 256
    private static let maximumArchiveBytes = 1_073_741_824
    private static let maximumPayloadBytes = 8_388_608
    private static let exportLock = NSLock()

    static func digest(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }

    private static func sync(_ url: URL, directory: Bool) throws {
        let descriptor = open(url.path, O_RDONLY | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw Failure.syncFailed }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.syncFailed }
    }

    private static func readBounded(_ url: URL, expectedBytes: Int, expectedDigest: Data) throws -> Data {
        guard expectedBytes > 0, expectedBytes <= maximumPayloadBytes else { throw Failure.verificationFailed }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.verificationFailed }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (metadata.st_mode & 0o777) == 0o600,
              metadata.st_size == off_t(expectedBytes) else { throw Failure.verificationFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        data.reserveCapacity(expectedBytes)
        while data.count < expectedBytes {
            guard let chunk = try handle.read(upToCount: expectedBytes - data.count), !chunk.isEmpty else {
                throw Failure.verificationFailed
            }
            data.append(chunk)
        }
        let trailing = try handle.read(upToCount: 1)
        guard trailing == nil || trailing?.isEmpty == true,
              fstat(descriptor, &metadata) == 0, metadata.st_size == off_t(expectedBytes),
              Data(SHA256.hash(data: data)) == expectedDigest else { throw Failure.verificationFailed }
        return data
    }

    static func save(_ originals: [Source], in directory: URL) throws -> URL {
        try saveVerified(originals, in: directory).file
    }

    static func saveVerified(_ originals: [Source], in directory: URL,
                             syncer: (URL, Bool) throws -> Void = { try sync($0, directory: $1) }) throws -> Receipt {
        exportLock.lock(); defer { exportLock.unlock() }
        guard !originals.isEmpty, originals.count <= 8,
              Set(originals.map(\.id)).count == originals.count,
              originals.reduce(0, { $0 + $1.text.utf16.count }) <= 1_048_576 else {
            throw Failure.invalidSources
        }
        let manager = FileManager.default
        let payload = Payload(schema: 1, originals: originals)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= maximumPayloadBytes else { throw Failure.invalidSources }
        let payloadDigest = Data(SHA256.hash(data: data))
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard (try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw Failure.verificationFailed
        }
        let existing = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard existing.count < maximumExports else { throw Failure.archiveLimit }
        var occupied = 0
        for item in existing {
            let file = item.appendingPathComponent("originals.json")
            let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size >= 0, size <= maximumArchiveBytes - occupied else { throw Failure.archiveLimit }
            occupied += size
        }
        guard data.count <= maximumArchiveBytes - occupied else { throw Failure.archiveLimit }
        try syncer(directory.deletingLastPathComponent(), true)
        let export = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: export, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            try syncer(directory, true)
            let target = export.appendingPathComponent("originals.json")
            try data.write(to: target, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            guard try readBounded(target, expectedBytes: data.count, expectedDigest: payloadDigest) == data,
                  try JSONDecoder().decode(Payload.self, from: data) == payload,
                  (try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (try manager.attributesOfItem(atPath: export.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
                throw Failure.verificationFailed
            }
            try syncer(target, false)
            try syncer(export, true)
            return Receipt(file: target,
                digests: Dictionary(uniqueKeysWithValues: originals.map { ($0.id, digest($0.text)) }),
                payloadBytes: data.count, payloadDigest: payloadDigest)
        } catch {
            // Only this newly minted directory is rolled back. Existing archives
            // and RAM originals remain untouched on any export failure.
            try? manager.removeItem(at: export)
            throw error
        }
    }

    /// Bounded integrity check for explicit user reads and off-input-path backing validation.
    static func original(id: UUID, receipt: Receipt) throws -> String {
        let data = try readBounded(receipt.file, expectedBytes: receipt.payloadBytes,
            expectedDigest: receipt.payloadDigest)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.schema == 1, let source = payload.originals.first(where: { $0.id == id }),
              receipt.digests[id] == digest(source.text) else { throw Failure.verificationFailed }
        return source.text
    }
}
