import Foundation

/// Explicit local export only, never background persistence or telemetry.
enum RecoveryArchive {
    struct Source: Codable, Equatable {
        let id: UUID
        let text: String
    }
    struct Payload: Codable, Equatable {
        let schema: Int
        let originals: [Source]
    }
    enum Failure: Error { case invalidSources, verificationFailed }

    static func save(_ originals: [Source], in directory: URL) throws -> URL {
        guard !originals.isEmpty, originals.count <= 8,
              originals.reduce(0, { $0 + $1.text.utf16.count }) <= 1_048_576 else {
            throw Failure.invalidSources
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let export = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: export, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let target = export.appendingPathComponent("originals.json")
        let payload = Payload(schema: 1, originals: originals)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        guard try Data(contentsOf: target) == data,
              try JSONDecoder().decode(Payload.self, from: Data(contentsOf: target)) == payload,
              (try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw Failure.verificationFailed
        }
        return target
    }
}
