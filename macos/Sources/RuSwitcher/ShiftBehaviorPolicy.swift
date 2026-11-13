import Foundation
import CoreFoundation
import CryptoKit
import Darwin

/// One-time, rollback-safe snapshot of the legacy gesture controls. No input callback calls this type.
enum ShiftBehaviorPolicy {
    static let version = 2
    static let maxBackupBytes = 128 * 1024
    static let markerKey = "com.macswitcher.nativeShiftMigrationVersion"
    static let automaticBaselineKey = "com.macswitcher.nativeShiftAutomaticBaseline"
    static let perAppBaselineKey = "com.macswitcher.nativeShiftPerAppBaseline"
    static let automaticOverrideKey = "com.macswitcher.nativeShiftAutomaticOverride"
    static let perAppOverrideKey = "com.macswitcher.nativeShiftPerAppOverride"
    static let backupDigestKey = "com.macswitcher.nativeShiftBackupSHA256"
    static let backupFileNameKey = "com.macswitcher.nativeShiftBackupFileName"

    static let legacyKeys = [
        "com.ruswitcher.triggerKey", "com.ruswitcher.triggerRightOnly",
        "com.ruswitcher.triggerDoubleTap", "com.ruswitcher.combinedShiftEnabled",
        "com.ruswitcher.switchHotkey", "com.ruswitcher.switchRightOnly",
        "com.ruswitcher.switchDoubleTap", "com.ruswitcher.caseHotkey",
        "com.ruswitcher.caseRightOnly", "com.ruswitcher.caseDoubleTap",
        "com.ruswitcher.autoSwitch"
    ]

    struct Entry {
        let type: String
        let value: Any?
    }

    static func backupURL(in directory: URL) -> URL {
        directory.appendingPathComponent("shift-gesture-v2.plist", isDirectory: false)
    }

    static func backupEntries(at url: URL) throws -> [String: Entry] {
        try backupEntries(from: readBackupData(url))
    }

    private static func backupEntries(from data: Data) throws -> [String: Entry] {
        guard let payload = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              payload["version"] as? Int == version,
              let rawEntries = payload["entries"] as? [String: [String: Any]],
              Set(rawEntries.keys) == Set(legacyKeys) else { throw MigrationError.invalidBackup }
        var result: [String: Entry] = [:]
        for key in legacyKeys {
            guard let raw = rawEntries[key], let type = raw["type"] as? String else {
                throw MigrationError.invalidBackup
            }
            if type == "absent" {
                guard raw["value"] == nil else { throw MigrationError.invalidBackup }
                result[key] = Entry(type: type, value: nil)
            } else {
                guard let value = raw["value"], valueType(value) == type else {
                    throw MigrationError.invalidBackup
                }
                result[key] = Entry(type: type, value: value)
            }
        }
        guard payload["automaticBaseline"] is Bool,
              payload["perAppBaseline"] is Bool else { throw MigrationError.invalidBackup }
        return result
    }

    struct ActivationResult {
        let applied: Bool
        let backupVerified: Bool
    }

    static func activeBackupURL(defaults: UserDefaults, directory: URL) -> URL {
        let name = defaults.string(forKey: backupFileNameKey) ?? "shift-gesture-v2.plist"
        return directory.appendingPathComponent(safeBackupName(name) ? name : "shift-gesture-v2.plist")
    }

    /// A committed marker controls runtime behavior. Backup damage only changes rollback status.
    static func activate(defaults: UserDefaults, directory: URL) -> ActivationResult {
        if defaults.integer(forKey: markerKey) == version {
            return ActivationResult(applied: true,
                backupVerified: verifyCommittedBackup(defaults: defaults, directory: directory))
        }
        do {
            guard !hasSymbolicLinkInPath(directory) else { throw MigrationError.unsafePath }
            let manager = FileManager.default
            if manager.fileExists(atPath: directory.path) {
                try requirePrivateDirectory(directory)
            } else {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try requirePrivateDirectory(directory)
            }
            let entries: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: legacyKeys.map { key in
                if let value = defaults.object(forKey: key) {
                    return (key, ["type": valueType(value), "value": value])
                }
                return (key, ["type": "absent"])
            })
            let master = defaults.object(forKey: "com.ruswitcher.autoSwitch") as? Bool ?? true
            let automaticBaseline = master && (defaults.object(forKey: "com.ruswitcher.autoConvert") as? Bool ?? false)
            let perAppBaseline = master && defaults.bool(forKey: "com.ruswitcher.perAppLayout")
            let payload: [String: Any] = [
                "version": version, "entries": entries,
                "automaticBaseline": automaticBaseline,
                "perAppBaseline": perAppBaseline
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            guard data.count <= maxBackupBytes else { throw MigrationError.invalidBackup }

            // Any pre-marker file is an orphan: leave it untouched and bind a fresh snapshot.
            let canonical = backupURL(in: directory)
            let url: URL
            if manager.fileExists(atPath: canonical.path)
                || (try? manager.destinationOfSymbolicLink(atPath: canonical.path)) != nil {
                url = directory.appendingPathComponent("shift-gesture-v2-\(UUID().uuidString).plist")
            } else {
                url = canonical
            }
            guard !manager.fileExists(atPath: url.path),
                  (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                throw MigrationError.unsafePath
            }
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let readBack = try readBackupData(url)
            guard readBack == data else { throw MigrationError.invalidBackup }
            _ = try backupEntries(from: readBack)
            let digest = sha256(data)
            defaults.set(automaticBaseline, forKey: automaticBaselineKey)
            defaults.set(perAppBaseline, forKey: perAppBaselineKey)
            defaults.set(digest, forKey: backupDigestKey)
            defaults.set(url.lastPathComponent, forKey: backupFileNameKey)
            defaults.set(version, forKey: markerKey)
            return ActivationResult(applied: defaults.integer(forKey: markerKey) == version,
                backupVerified: defaults.string(forKey: backupDigestKey) == digest)
        } catch {
            return ActivationResult(applied: false, backupVerified: false)
        }
    }

    private static func verifyCommittedBackup(defaults: UserDefaults, directory: URL) -> Bool {
        do {
            guard !hasSymbolicLinkInPath(directory) else { return false }
            try requirePrivateDirectory(directory)
            let name = defaults.string(forKey: backupFileNameKey) ?? "shift-gesture-v2.plist"
            guard safeBackupName(name) else { return false }
            let url = directory.appendingPathComponent(name)
            guard !hasSymbolicLinkInPath(url) else { return false }
            let data = try readBackupData(url)
            guard defaults.string(forKey: backupDigestKey) == sha256(data) else { return false }
            _ = try backupEntries(from: data)
            return true
        } catch {
            return false
        }
    }

    private static func safeBackupName(_ name: String) -> Bool {
        name == "shift-gesture-v2.plist"
            || (name.hasPrefix("shift-gesture-v2-") && name.hasSuffix(".plist")
                && !name.contains("/") && !name.contains(".."))
    }

    private static func hasSymbolicLinkInPath(_ url: URL) -> Bool {
        var component = url.standardizedFileURL
        while component.path != "/" {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: component.path) {
                // macOS's system-owned /var alias is the canonical route to temporary profiles.
                let attributes = try? FileManager.default.attributesOfItem(atPath: component.path)
                if component.path == "/var", target == "private/var",
                   (attributes?[.ownerAccountID] as? NSNumber)?.intValue == 0 {
                    component.deleteLastPathComponent()
                    continue
                }
                return true
            }
            component.deleteLastPathComponent()
        }
        return false
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid()),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw MigrationError.invalidBackup
        }
    }

    private static func requirePrivateFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid()),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= maxBackupBytes else {
            throw MigrationError.invalidBackup
        }
    }

    /// Bounded read from the same verified descriptor; fstat catches replacement and
    /// the max+1 loop catches growth after stat without allocating unbounded data.
    private static func readBackupData(_ url: URL) throws -> Data {
        guard !hasSymbolicLinkInPath(url) else { throw MigrationError.unsafePath }
        try requirePrivateFile(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw MigrationError.invalidBackup }
        defer { _ = Darwin.close(fd) }
        var status = stat()
        guard Darwin.fstat(fd, &status) == 0,
              (status.st_mode & 0o170000) == 0o100000,
              (status.st_mode & 0o777) == 0o600,
              status.st_uid == getuid(),
              status.st_size > 0, status.st_size <= maxBackupBytes else {
            throw MigrationError.invalidBackup
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let limit = min(buffer.count, maxBackupBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, limit)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw MigrationError.invalidBackup
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > maxBackupBytes { throw MigrationError.invalidBackup }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func valueType(_ value: Any) -> String {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
            return String(cString: number.objCType).contains("f") || String(cString: number.objCType).contains("d")
                ? "real" : "integer"
        }
        if value is String { return "string" }
        if value is Data { return "data" }
        if value is Date { return "date" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "dictionary" }
        return "unknown"
    }

    private enum MigrationError: Error { case invalidBackup, unsafePath }
}
