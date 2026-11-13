import Darwin
import Foundation

/// Explicit owner-approved profile patch only. No caller invokes this at startup.
/// The preview is content-free; backup files may contain private shell settings.
enum ShellBridgeProfilePatch {
    enum PatchError: Error { case invalidPath, unsafeProfile, modifiedMarker, conflict, ioFailure }
    enum Action: Equatable { case install, uninstall, alreadyInstalled, alreadyRemoved }
    struct Preview: Equatable {
        let action: Action
        let sourceLine: String
        let requiresBackup: Bool
    }

    private static let marker = "# MacSwitcher shell bridge v1"
    private static let maximumProfileBytes = 1_048_576
    private enum OriginalEnding: String, CaseIterable {
        case empty, finalLF, finalCRLF, noFinalLF, noFinalCRLF
        var newline: String {
            switch self {
            case .finalCRLF, .noFinalCRLF: "\r\n"
            default: "\n"
            }
        }
        var needsSeparator: Bool { self == .noFinalLF || self == .noFinalCRLF }
    }

    static var packagedResourceURL: URL? {
        let mainBundleURL = Bundle.main.bundleURL
        let swiftPMResourceURL = mainBundleURL.pathExtension.lowercased() == "app"
            ? nil : Bundle.module.url(forResource: "terminal-zle", withExtension: "zsh")
        return resolvePackagedResourceURL(mainBundleURL: mainBundleURL,
            swiftPMResourceURL: swiftPMResourceURL)
    }

    /// A distributed app must resolve its own nested SwiftPM bundle. The
    /// generated Bundle.module fallback can still point at the build machine.
    static func resolvePackagedResourceURL(mainBundleURL: URL,
                                           swiftPMResourceURL: URL?) -> URL? {
        guard mainBundleURL.pathExtension.lowercased() == "app" else {
            return swiftPMResourceURL
        }
        let app = mainBundleURL.resolvingSymlinksInPath().standardizedFileURL
        let resourceBundle = app.appendingPathComponent(
            "Contents/Resources/RuSwitcher_RuSwitcher.bundle")
            .resolvingSymlinksInPath().standardizedFileURL
        guard resourceBundle.path.hasPrefix(app.path + "/"),
              (try? resourceBundle.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        let resource = resourceBundle.appendingPathComponent("terminal-zle.zsh")
            .resolvingSymlinksInPath().standardizedFileURL
        guard resource.path.hasPrefix(resourceBundle.path + "/"),
              (try? resource.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: resource.path) else { return nil }
        return resource
    }

    private static func originalEnding(_ data: Data) -> OriginalEnding {
        guard !data.isEmpty else { return .empty }
        if data.suffix(2) == Data([13, 10]) { return .finalCRLF }
        if data.last == 10 { return .finalLF }
        return data.range(of: Data([13, 10]), options: .backwards) != nil ? .noFinalCRLF : .noFinalLF
    }

    private static func sourceLine(resourcePath: String, ending: OriginalEnding) throws -> String {
        guard resourcePath.hasPrefix("/"), !resourcePath.contains("\n"),
              !resourcePath.contains("\r"), !resourcePath.contains("\0") else { throw PatchError.invalidPath }
        let quoted = "'" + resourcePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "[[ -o interactive && -r \(quoted) ]] && source \(quoted) \(marker) \(ending.rawValue)"
    }

    static func preview(profileData: Data?, resourcePath: String,
                        uninstall: Bool = false) throws -> Preview {
        let original = profileData ?? Data()
        guard original.count <= maximumProfileBytes else { throw PatchError.unsafeProfile }
        let text = String(data: original, encoding: .utf8)
        guard text != nil else { throw PatchError.unsafeProfile }
        let line = try sourceLine(resourcePath: resourcePath, ending: originalEnding(original))
        let markerLines = original.split(separator: 10, omittingEmptySubsequences: false)
            .compactMap { bytes -> String? in
                var line = Data(bytes)
                if line.last == 13 { line.removeLast() }
                return String(data: line, encoding: .utf8)
            }
            .filter { $0.contains(marker) }
        if let existing = markerLines.first {
            let recognized = try OriginalEnding.allCases.contains {
                try sourceLine(resourcePath: resourcePath, ending: $0) == existing
            }
            guard markerLines.count == 1, recognized else {
                throw PatchError.modifiedMarker
            }
        }
        if uninstall {
            return Preview(action: markerLines.isEmpty ? .alreadyRemoved : .uninstall,
                sourceLine: markerLines.first ?? line, requiresBackup: !markerLines.isEmpty)
        }
        if let existing = markerLines.first {
            return Preview(action: .alreadyInstalled, sourceLine: String(existing), requiresBackup: false)
        }
        return Preview(action: .install, sourceLine: line, requiresBackup: true)
    }

    static func transformed(profileData: Data?, resourcePath: String,
                            uninstall: Bool = false) throws -> (Preview, Data) {
        let original = profileData ?? Data()
        let plan = try preview(profileData: profileData, resourcePath: resourcePath, uninstall: uninstall)
        guard String(data: original, encoding: .utf8) != nil else { throw PatchError.unsafeProfile }
        switch plan.action {
        case .alreadyInstalled, .alreadyRemoved: return (plan, original)
        case .install:
            let ending = originalEnding(original)
            var result = original
            if ending.needsSeparator { result.append(contentsOf: ending.newline.utf8) }
            result.append(contentsOf: plan.sourceLine.utf8)
            result.append(contentsOf: ending.newline.utf8)
            guard result.count <= maximumProfileBytes else { throw PatchError.unsafeProfile }
            return (plan, result)
        case .uninstall:
            guard let state = OriginalEnding.allCases.first(where: {
                plan.sourceLine.hasSuffix(" \($0.rawValue)")
            }) else { throw PatchError.modifiedMarker }
            let installed = Data((plan.sourceLine + state.newline).utf8)
            guard let range = original.range(of: installed),
                  original.range(of: installed, in: range.upperBound..<original.endIndex) == nil,
                  range.lowerBound == 0 || original[range.lowerBound - 1] == 10 else {
                throw PatchError.modifiedMarker
            }
            var removalStart = range.lowerBound
            // If the marker is still the last line, restore the exact original
            // absence of a final newline. If later content exists, preserve
            // that separator so subsequent user edits remain on their line.
            if state.needsSeparator && range.upperBound == original.count {
                let separator = Data(state.newline.utf8)
                guard removalStart >= separator.count,
                      original[(removalStart - separator.count)..<removalStart] == separator else {
                    throw PatchError.modifiedMarker
                }
                removalStart -= separator.count
            }
            var result = original
            result.removeSubrange(removalStart..<range.upperBound)
            return (plan, result)
        }
    }

    /// Only call after explicit approval. A displaced live inode is always
    /// retained under a private 0700 holder before its bytes are compared.
    /// File coordination covers cooperating editors; the exchange preserves
    /// both versions even if an uncoordinated writer wins the final race.
    @discardableResult
    static func apply(profile: URL, resourcePath: String, uninstall: Bool = false,
                      beforeExchange: (() throws -> Void)? = nil)
        throws -> (Preview, URL?) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<(Preview, URL?), Error>?
        coordinator.coordinate(writingItemAt: profile, options: .forReplacing,
                               error: &coordinationError) { coordinated in
            outcome = Result {
                try applyCoordinated(profile: coordinated, resourcePath: resourcePath,
                    uninstall: uninstall, beforeExchange: beforeExchange)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw PatchError.ioFailure }
        return try outcome.get()
    }

    private static func applyCoordinated(profile: URL, resourcePath: String,
                                         uninstall: Bool, beforeExchange: (() throws -> Void)?)
        throws -> (Preview, URL?) {
        let path = profile.path
        var info = stat()
        let existed = Darwin.lstat(path, &info) == 0
        if existed {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == Darwin.getuid() else { throw PatchError.unsafeProfile }
        }
        let original = existed ? try readRegular(path).data : nil
        let (plan, result) = try transformed(profileData: original,
            resourcePath: resourcePath, uninstall: uninstall)
        guard plan.requiresBackup else { return (plan, nil) }
        let mode = existed ? info.st_mode & 0o777 : mode_t(0o600)
        let holder = profile.deletingLastPathComponent()
            .appendingPathComponent(".macswitcher-profile-recovery", isDirectory: true)
        try prepareHolder(holder.path)
        let backup = holder.appendingPathComponent("\(profile.lastPathComponent).backup-\(UUID().uuidString)")
        try writeExclusive(original ?? Data(), to: backup.path, mode: 0o600)
        let candidate = holder.appendingPathComponent("\(profile.lastPathComponent).candidate-\(UUID().uuidString)")
        try writeExclusive(result, to: candidate.path, mode: mode)
        let candidateInfo = try readRegular(candidate.path).info
        // A separate private copy also preserves our proposed bytes if an
        // uncoordinated writer edits the candidate inode after the exchange.
        let proposalCopy = holder.appendingPathComponent("\(profile.lastPathComponent).proposal-\(UUID().uuidString)")
        try writeExclusive(result, to: proposalCopy.path, mode: 0o600)
        try syncDirectory(holder.path)
        // A normal preflight catches most conflicts without changing the main
        // path; the atomic exchange below handles the remaining race.
        if existed {
            guard let current = try? readRegular(path),
                  sameFile(current.info, info), current.data == original else {
                throw PatchError.conflict
            }
        } else if Darwin.lstat(path, &info) == 0 {
            throw PatchError.conflict
        }
        try beforeExchange?()
        if existed {
            guard Darwin.renameatx_np(AT_FDCWD, candidate.path, AT_FDCWD, path,
                                     UInt32(RENAME_SWAP)) == 0 else { throw PatchError.conflict }
            // `candidate` now names the actual displaced profile, protected by
            // holder permissions. Verify it before declaring installation.
            let displaced = try? readRegular(candidate.path)
            let matched = displaced.map { sameFile($0.info, info) && $0.data == original } ?? false
            if !matched {
                // Roll back only while the current main path is still exactly
                // our candidate. Otherwise keep both versions for recovery.
                if let currentCandidate = try? readRegular(path),
                   currentCandidate.data == result,
                   sameFile(currentCandidate.info, candidateInfo) {
                    _ = Darwin.renameatx_np(AT_FDCWD, candidate.path, AT_FDCWD, path,
                                            UInt32(RENAME_SWAP))
                }
                try? syncDirectory(holder.path)
                try? syncDirectory(profile.deletingLastPathComponent().path)
                throw PatchError.conflict
            }
        } else {
            guard Darwin.renameatx_np(AT_FDCWD, candidate.path, AT_FDCWD, path,
                                     UInt32(RENAME_EXCL)) == 0 else { throw PatchError.conflict }
        }
        try syncDirectory(holder.path)
        try syncDirectory(profile.deletingLastPathComponent().path)
        guard let installed = try? readRegular(path), installed.data == result else {
            throw PatchError.conflict
        }
        return (plan, backup)
    }

    private static func sameFile(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino
            && left.st_uid == right.st_uid && left.st_mode == right.st_mode
    }

    private static func prepareHolder(_ path: String) throws {
        if Darwin.mkdir(path, 0o700) != 0 && errno != EEXIST { throw PatchError.ioFailure }
        var info = stat()
        guard Darwin.lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == Darwin.getuid(),
              (info.st_mode & 0o777) == 0o700 else { throw PatchError.unsafeProfile }
    }

    private static func readRegular(_ path: String) throws -> (data: Data, info: stat) {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw PatchError.unsafeProfile }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == Darwin.getuid(),
              info.st_size >= 0, info.st_size <= maximumProfileBytes else { throw PatchError.unsafeProfile }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        while data.count < info.st_size {
            var chunk = [UInt8](repeating: 0, count: min(4096, Int(info.st_size) - data.count))
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { throw PatchError.unsafeProfile }
            data.append(contentsOf: chunk.prefix(count))
        }
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0,
              sameFile(info, after), after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw PatchError.conflict }
        return (data, info)
    }

    private static func writeExclusive(_ data: Data, to path: String, mode: mode_t) throws {
        let fd = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw PatchError.ioFailure }
        defer { Darwin.close(fd) }
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { pointer in
                Darwin.write(fd, pointer.baseAddress!.advanced(by: written), data.count - written)
            }
            guard count > 0 else { throw PatchError.ioFailure }
            written += count
        }
        guard Darwin.fchmod(fd, mode) == 0 else { throw PatchError.ioFailure }
        guard Darwin.fsync(fd) == 0 else { throw PatchError.ioFailure }
    }

    private static func syncDirectory(_ path: String) throws {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw PatchError.ioFailure }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw PatchError.ioFailure }
    }
}
