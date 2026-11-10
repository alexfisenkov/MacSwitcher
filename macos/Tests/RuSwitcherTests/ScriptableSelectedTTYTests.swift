import AppKit
import ApplicationServices
import XCTest
@testable import RuSwitcher

final class ScriptableSelectedTTYTests: XCTestCase {
    private final class MockExecutor: ReadOnlyAppleEventExecutor {
        var permission: OSStatus = noErr
        var readCodes: [OSType] = []
        var tty = "/dev/ttys001"
        var id: Int32 = 71
        var boundsDescriptor: NSAppleEventDescriptor?
        var boundsDescriptorAfterFirstRead: NSAppleEventDescriptor?
        var flipTTYAfterTwoReads = false
        private var ttyReads = 0
        private var boundsReads = 0
        func preflight(pid: Int32) -> OSStatus { permission }
        func read(pid: Int32, object: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
            var objectRecord = object.aeDesc!.pointee
            var rawKey = AEDesc()
            guard AEGetParamDesc(&objectRecord, AEKeyword(keyAEKeyData), DescType(typeWildCard), &rawKey) == noErr else {
                return nil
            }
            let key = NSAppleEventDescriptor(aeDescNoCopy: &rawKey)
            let code = key.typeCodeValue
            readCodes.append(code)
            switch code {
            case ScriptableSelectedTTYCapability.terminalSDEF.frontmostProperty:
                return .init(boolean: true)
            case ScriptableSelectedTTYCapability.terminalSDEF.windowIDProperty:
                return .init(int32: id)
            case ScriptableSelectedTTYCapability.terminalSDEF.ttyProperty:
                ttyReads += 1
                return .init(string: flipTTYAfterTwoReads && ttyReads > 2
                    ? "/dev/ttys002" : tty)
            case ScriptableSelectedTTYCapability.terminalSDEF.boundsProperty:
                boundsReads += 1
                if boundsReads > 1, let changed = boundsDescriptorAfterFirstRead { return changed }
                return boundsDescriptor ?? .init(descriptorType: OSType(typeQDRectangle),
                    data: Data([0, 20, 0, 30, 1, 20, 2, 30]))
            default: return nil
            }
        }
    }

    func testReadOnlyPropertyChainReturnsStableSelectedTTY() throws {
        let executor = MockExecutor()
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        let result = try reader.observe(pid: 123)
        XCTAssertEqual(result.tty, "/dev/ttys001")
        XCTAssertEqual(result.windowID, 71)
        XCTAssertTrue(result.windowBoundsCandidates.contains(CGRect(x: 30, y: 20, width: 512, height: 256)))
        XCTAssertEqual(executor.readCodes.count, 7)
        XCTAssertEqual(executor.readCodes.filter { $0 == ScriptableSelectedTTYCapability.terminalSDEF.ttyProperty }.count, 2)
    }

    func testPreflightConsentAndChangedSelectedTabRefuseWithoutEvent() {
        let executor = MockExecutor()
        executor.permission = OSStatus(errAEEventWouldRequireUserConsent)
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        XCTAssertThrowsError(try reader.observe(pid: 123))
        XCTAssertTrue(executor.readCodes.isEmpty)
        executor.permission = noErr
        executor.tty = "not-a-device"
        XCTAssertThrowsError(try reader.observe(pid: 123))
    }

    func testRectangleRejectsMalformedBounds() {
        XCTAssertNil(ScriptableSelectedTTYReader.qdRect(Data([0, 1])))
        XCTAssertNil(ScriptableSelectedTTYReader.qdRect(Data(repeating: 0, count: 8)))
    }

    func testEndianCandidatesRequireUniqueAXWitness() {
        let expected = CGRect(x: 30, y: 20, width: 512, height: 256)
        let executor = MockExecutor()
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        for raw in [Data([0, 20, 0, 30, 1, 20, 2, 30]),
                    Data([20, 0, 30, 0, 20, 1, 30, 2])] {
            executor.boundsDescriptor = NSAppleEventDescriptor(descriptorType: OSType(typeQDRectangle), data: raw)
            let proof = ScriptableShellFocusProof(readerForPID: { _ in reader },
                frontmostPID: { 123 }, axValidator: { _, rect in rect == expected },
                foregroundValidator: { _, _ in true })
            XCTAssertTrue(proof.permits(sessionPID: 456, tty: "/dev/ttys001"))
            let ambiguous = ScriptableShellFocusProof(readerForPID: { _ in reader },
                frontmostPID: { 123 }, axValidator: { _, _ in true },
                foregroundValidator: { _, _ in true })
            XCTAssertFalse(ambiguous.permits(sessionPID: 456, tty: "/dev/ttys001"))
            let noMatch = ScriptableShellFocusProof(readerForPID: { _ in reader },
                frontmostPID: { 123 }, axValidator: { _, _ in false },
                foregroundValidator: { _, _ in true })
            XCTAssertFalse(noMatch.permits(sessionPID: 456, tty: "/dev/ttys001"))
        }
    }

    func testSignedNegativeQuickDrawCoordinates() {
        let raw = Data([0xFF, 0xEC, 0xFF, 0xE2, 0x00, 0xC8, 0x01, 0x2C])
        let expected = CGRect(x: -30, y: -20, width: 330, height: 220)
        XCTAssertEqual(ScriptableSelectedTTYReader.qdRect(raw), expected)
        let littleEndian = Data([0xEC, 0xFF, 0xE2, 0xFF, 0xC8, 0x00, 0x2C, 0x01])
        XCTAssertTrue(ScriptableSelectedTTYReader.qdRectCandidates(littleEndian).contains(expected))
    }

    func testChangedRawBoundsAfterAXWitnessRefuses() {
        let executor = MockExecutor()
        executor.boundsDescriptorAfterFirstRead = NSAppleEventDescriptor(
            descriptorType: OSType(typeQDRectangle),
            data: Data([20, 0, 30, 0, 20, 1, 30, 2]))
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        let proof = ScriptableShellFocusProof(readerForPID: { _ in reader },
            frontmostPID: { 123 }, axValidator: { _, rect in
                rect == CGRect(x: 30, y: 20, width: 512, height: 256)
            }, foregroundValidator: { _, _ in true })
        XCTAssertFalse(proof.permits(sessionPID: 456, tty: "/dev/ttys001"))
    }

    func testBoundsReplyMustBeTypedQDRectangle() {
        let raw = Data([0, 20, 0, 30, 1, 20, 2, 30])
        let executor = MockExecutor()
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        executor.boundsDescriptor = NSAppleEventDescriptor(descriptorType: OSType(0x64617461), data: raw)
        XCTAssertThrowsError(try reader.observe(pid: 123))
        let list = NSAppleEventDescriptor.list()
        for (index, value) in [30, 20, 542, 276].enumerated() {
            list.insert(NSAppleEventDescriptor(int32: Int32(value)), at: index + 1)
        }
        executor.boundsDescriptor = list
        XCTAssertThrowsError(try reader.observe(pid: 123))
    }

    func testFocusProofRefusesTabSwitchAfterAXValidation() {
        let executor = MockExecutor()
        executor.flipTTYAfterTwoReads = true
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        let proof = ScriptableShellFocusProof(readerForPID: { _ in reader },
            frontmostPID: { 123 }, axValidator: { _, rect in
                rect == CGRect(x: 30, y: 20, width: 512, height: 256)
            },
            foregroundValidator: { _, _ in true })
        XCTAssertFalse(proof.permits(sessionPID: 456, tty: "/dev/ttys001"))
        XCTAssertEqual(executor.readCodes.filter {
            $0 == ScriptableSelectedTTYCapability.terminalSDEF.ttyProperty
        }.count, 4)
    }

    func testCapabilityDiscoveryUsesSDEFPropertiesRatherThanAppName() throws {
        let file = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.sdef")
        let data = try Data(contentsOf: file)
        let found = try XCTUnwrap(SelectedTTYCapabilityDiscovery.parse(data))
        XCTAssertEqual(found.windowClass, ScriptableSelectedTTYCapability.terminalSDEF.windowClass)
        XCTAssertEqual(found.selectedTabProperty, ScriptableSelectedTTYCapability.terminalSDEF.selectedTabProperty)
        XCTAssertEqual(found.ttyProperty, ScriptableSelectedTTYCapability.terminalSDEF.ttyProperty)
        let unsupported = Data("<dictionary><class name='window' code='cwin'/></dictionary>".utf8)
        XCTAssertNil(SelectedTTYCapabilityDiscovery.parse(unsupported))
    }
}
