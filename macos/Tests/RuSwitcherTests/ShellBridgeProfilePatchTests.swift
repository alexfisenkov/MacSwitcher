import Darwin
import Foundation
import XCTest
@testable import RuSwitcher

final class ShellBridgeProfilePatchTests: XCTestCase {
    private let resource = "/Applications/MacSwitcher.app/Contents/Resources/terminal-zle.zsh"

    func testPackagedResourceIsFoundInSwiftPMBundle() {
        XCTAssertNotNil(ShellBridgeProfilePatch.packagedResourceURL)
    }

    func testPreviewRoundTripPreservesOriginalBytes() throws {
        for original in ["", "export LANG=ru_RU.UTF-8", "export LANG=ru_RU.UTF-8\n",
                         "# комментарий\nexport X='a b'\n", "# строка\r\nexport X='тест'\r\n",
                         "# строка\r\nexport X='тест'"] {
            let data = Data(original.utf8)
            let (install, changed) = try ShellBridgeProfilePatch.transformed(
                profileData: data, resourcePath: "/Applications/Приложения/MacSwitcher.app/terminal-zle.zsh")
            XCTAssertEqual(install.action, .install)
            XCTAssertEqual(changed.prefix(data.count), data)
            let (repeatInstall, same) = try ShellBridgeProfilePatch.transformed(
                profileData: changed, resourcePath: "/Applications/Приложения/MacSwitcher.app/terminal-zle.zsh")
            XCTAssertEqual(repeatInstall.action, .alreadyInstalled)
            XCTAssertEqual(same, changed)
            let (remove, restored) = try ShellBridgeProfilePatch.transformed(
                profileData: changed, resourcePath: "/Applications/Приложения/MacSwitcher.app/terminal-zle.zsh", uninstall: true)
            XCTAssertEqual(remove.action, .uninstall)
            XCTAssertEqual(restored, data)
        }
    }

    func testMalformedMarkerRefuses() throws {
        let original = Data("# MacSwitcher shell bridge v1 changed\n".utf8)
        XCTAssertThrowsError(try ShellBridgeProfilePatch.transformed(profileData: original,
            resourcePath: resource))
        XCTAssertThrowsError(try ShellBridgeProfilePatch.transformed(profileData: original,
            resourcePath: resource, uninstall: true))
        XCTAssertThrowsError(try ShellBridgeProfilePatch.preview(profileData: nil,
            resourcePath: "/bad\npath"))
    }

    func testUninstallRemovesOwnLineAfterLaterUserEdits() throws {
        for original in ["export X=1", "export X=1\n", "export X=1\r\n"] {
            let data = Data(original.utf8)
            let (_, installed) = try ShellBridgeProfilePatch.transformed(
                profileData: data, resourcePath: resource)
            var later = installed
            later.append(contentsOf: "# later user setting\n".utf8)
            let (_, result) = try ShellBridgeProfilePatch.transformed(profileData: later,
                resourcePath: resource, uninstall: true)
            let expected = Data((original + (original.utf8.last == 10 ? "" : "\n")
                + "# later user setting\n").utf8)
            XCTAssertEqual(result, expected, "case \(String(reflecting: original))")
        }
    }

    func testApplyOnlyTemporaryProfileMakesBackupAndRestores() throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("ms-profile-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = folder.appendingPathComponent(".zshrc")
        let original = Data("alias ll='ls -l'\n".utf8)
        try original.write(to: profile)
        let (installed, backup) = try ShellBridgeProfilePatch.apply(profile: profile, resourcePath: resource)
        XCTAssertEqual(installed.action, .install)
        XCTAssertEqual(try Data(contentsOf: backup!), original)
        let backupMode = try FileManager.default.attributesOfItem(atPath: backup!.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(backupMode?.intValue, 0o600)
        let afterInstall = try Data(contentsOf: profile)
        XCTAssertTrue(afterInstall.count > original.count)
        let (again, duplicateBackup) = try ShellBridgeProfilePatch.apply(profile: profile, resourcePath: resource)
        XCTAssertEqual(again.action, .alreadyInstalled)
        XCTAssertNil(duplicateBackup)
        let (removed, removalBackup) = try ShellBridgeProfilePatch.apply(
            profile: profile, resourcePath: resource, uninstall: true)
        XCTAssertEqual(removed.action, .uninstall)
        XCTAssertEqual(try Data(contentsOf: removalBackup!), afterInstall)
        XCTAssertEqual(try Data(contentsOf: profile), original)
    }

    func testAtomicExternalEditBetweenCheckAndExchangeIsRestoredWithoutLosingVersions() throws {
        try exerciseConflict(atomic: true)
    }

    func testInPlaceExternalEditBetweenCheckAndExchangeIsRestoredWithoutLosingVersions() throws {
        try exerciseConflict(atomic: false)
    }

    private func exerciseConflict(atomic: Bool) throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("ms-profile-race-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = folder.appendingPathComponent(".zshrc")
        let original = Data("export A=old\n".utf8)
        let external = Data("export A=latest\n".utf8)
        try original.write(to: profile)
        let proposal = try ShellBridgeProfilePatch.transformed(profileData: original,
            resourcePath: resource).1
        XCTAssertThrowsError(try ShellBridgeProfilePatch.apply(profile: profile,
            resourcePath: resource, beforeExchange: {
                if atomic {
                    try external.write(to: profile, options: .atomic)
                } else {
                    let fd = Darwin.open(profile.path, O_WRONLY | O_TRUNC)
                    guard fd >= 0 else { throw ShellBridgeProfilePatch.PatchError.ioFailure }
                    defer { Darwin.close(fd) }
                    let count = external.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
                    guard count == external.count, Darwin.fsync(fd) == 0 else {
                        throw ShellBridgeProfilePatch.PatchError.ioFailure
                    }
                }
            })) { error in
                guard case ShellBridgeProfilePatch.PatchError.conflict = error else {
                    return XCTFail("Expected conflict, got \(error)")
                }
            }
        XCTAssertEqual(try Data(contentsOf: profile), external)
        let holder = folder.appendingPathComponent(".macswitcher-profile-recovery")
        let mode = try FileManager.default.attributesOfItem(atPath: holder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        let saved = try FileManager.default.contentsOfDirectory(at: holder,
            includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) }
        XCTAssertTrue(saved.contains(original))
        XCTAssertTrue(saved.contains(proposal))
    }

    func testNewProfileRaceCannotOverwriteUnexpectedFile() throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("ms-profile-newrace-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = folder.appendingPathComponent(".zshrc")
        let external = Data("export B=new\n".utf8)
        XCTAssertThrowsError(try ShellBridgeProfilePatch.apply(profile: profile,
            resourcePath: resource, beforeExchange: {
                try external.write(to: profile)
            })) { error in
                guard case ShellBridgeProfilePatch.PatchError.conflict = error else {
                    return XCTFail("Expected conflict, got \(error)")
                }
            }
        XCTAssertEqual(try Data(contentsOf: profile), external)
        let holder = folder.appendingPathComponent(".macswitcher-profile-recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: holder.path))
    }

    func testSymlinkProfileIsRefusedWithoutChangingTarget() throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("ms-profile-link-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("actual.zshrc")
        let profile = folder.appendingPathComponent(".zshrc")
        let original = Data("export SAFE=1\n".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target)
        XCTAssertThrowsError(try ShellBridgeProfilePatch.apply(profile: profile, resourcePath: resource))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: profile.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}
