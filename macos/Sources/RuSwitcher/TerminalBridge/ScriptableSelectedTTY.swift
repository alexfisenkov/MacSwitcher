import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Four-character property path advertised by a host's scripting dictionary.
/// It describes capability, not an application-name whitelist. The first
/// known profile comes from Terminal.app's local SDEF (cwin/tcnt/ttty).
struct ScriptableSelectedTTYCapability {
    let windowClass: OSType
    let selectedTabProperty: OSType
    let ttyProperty: OSType
    let frontmostProperty: OSType
    let windowIDProperty: OSType
    let boundsProperty: OSType

    static let terminalSDEF = Self(windowClass: fourCC("cwin"),
        selectedTabProperty: fourCC("tcnt"), ttyProperty: fourCC("ttty"),
        frontmostProperty: fourCC("pisf"), windowIDProperty: fourCC("ID  "),
        boundsProperty: fourCC("pbnd"))

    private static func fourCC(_ text: String) -> OSType {
        text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}

struct ScriptableSelectedTTYObservation: Equatable {
    let tty: String
    let windowID: Int32
    let windowBoundsCandidates: [CGRect]
    let rawBounds: Data
}

enum ScriptableSelectedTTYFailure: Error { case needsConsent, unsupported, changed, invalidReply }

protocol ReadOnlyAppleEventExecutor {
    func preflight(pid: Int32) -> OSStatus
    func read(pid: Int32, object: NSAppleEventDescriptor) -> NSAppleEventDescriptor?
}

/// Only kAEGetData is sent. Both preflight and send forbid a consent prompt.
struct NativeReadOnlyAppleEventExecutor: ReadOnlyAppleEventExecutor {
    /// Call only after the user explicitly chooses the named host in setup UI.
    /// No Apple Event payload or terminal text is sent by this consent probe.
    static func requestConsent(pid: Int32) -> OSStatus {
        guard !Thread.isMainThread else { return OSStatus(errAEEventWouldRequireUserConsent) }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        var raw = target.aeDesc!.pointee
        return AEDeterminePermissionToAutomateTarget(&raw, kAECoreSuite, kAEGetData, true)
    }

    func preflight(pid: Int32) -> OSStatus {
        guard !Thread.isMainThread else { return OSStatus(errAEEventWouldRequireUserConsent) }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        var raw = target.aeDesc!.pointee
        return AEDeterminePermissionToAutomateTarget(&raw, kAECoreSuite, kAEGetData, false)
    }

    func read(pid: Int32, object: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        guard !Thread.isMainThread else { return nil }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(eventClass: kAECoreSuite, eventID: kAEGetData,
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: keyDirectObject)
        let options = NSAppleEventDescriptor.SendOptions(rawValue:
            UInt(kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent))
        return try? event.sendEvent(options: options, timeout: 0.25).paramDescriptor(forKeyword: keyDirectObject)
    }
}

/// Property-object builders are independently testable without sending an AE.
enum ScriptableSelectedTTYObjectPath {
    static func window(_ capability: ScriptableSelectedTTYCapability) -> NSAppleEventDescriptor? {
        object(desiredClass: capability.windowClass, container: .null(),
            keyForm: OSType(formAbsolutePosition), key: .init(int32: 1))
    }

    static func property(_ property: OSType, of container: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor? {
        object(desiredClass: OSType(cProperty), container: container, keyForm: OSType(formPropertyID),
            key: .init(typeCode: property))
    }

    private static func object(desiredClass: OSType, container: NSAppleEventDescriptor,
                               keyForm: OSType, key: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        var rawContainer = container.aeDesc!.pointee
        var rawKey = key.aeDesc!.pointee
        var result = AEDesc()
        guard CreateObjSpecifier(desiredClass, &rawContainer, keyForm, &rawKey, false, &result) == noErr else {
            return nil
        }
        return NSAppleEventDescriptor(aeDescNoCopy: &result)
    }
}

struct ScriptableSelectedTTYReader {
    let capability: ScriptableSelectedTTYCapability
    let executor: ReadOnlyAppleEventExecutor

    func observe(pid: Int32) throws -> ScriptableSelectedTTYObservation {
        let permission = executor.preflight(pid: pid)
        guard permission == noErr else {
            throw permission == errAEEventWouldRequireUserConsent
                ? ScriptableSelectedTTYFailure.needsConsent : .unsupported
        }
        guard let window = ScriptableSelectedTTYObjectPath.window(capability),
              let front = ScriptableSelectedTTYObjectPath.property(capability.frontmostProperty, of: window),
              let id = ScriptableSelectedTTYObjectPath.property(capability.windowIDProperty, of: window),
              let bounds = ScriptableSelectedTTYObjectPath.property(capability.boundsProperty, of: window),
              let tab = ScriptableSelectedTTYObjectPath.property(capability.selectedTabProperty, of: window),
              let tty = ScriptableSelectedTTYObjectPath.property(capability.ttyProperty, of: tab) else {
            throw ScriptableSelectedTTYFailure.unsupported
        }
        func value(_ object: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
            executor.read(pid: pid, object: object)
        }
        guard value(front)?.booleanValue == true,
              let beforeID = value(id)?.int32Value,
              let ttyBefore = value(tty)?.stringValue, ttyBefore.hasPrefix("/dev/tty"),
              let boundsReply = value(bounds),
              boundsReply.descriptorType == DescType(typeQDRectangle),
              case let rectangles = Self.qdRectCandidates(boundsReply.data), !rectangles.isEmpty,
              value(id)?.int32Value == beforeID,
              value(tty)?.stringValue == ttyBefore,
              value(front)?.booleanValue == true else { throw ScriptableSelectedTTYFailure.changed }
        return ScriptableSelectedTTYObservation(tty: ttyBefore, windowID: beforeID,
            windowBoundsCandidates: rectangles, rawBounds: boundsReply.data)
    }

    /// Preserve the original BE decoder for focused tests and historical
    /// fixtures. Production accepts neither byte order without an AX witness.
    static func qdRect(_ data: Data) -> CGRect? {
        qdRect(data, littleEndian: false)
    }

    static func qdRectCandidates(_ data: Data) -> [CGRect] {
        var candidates: [CGRect] = []
        for littleEndian in [false, true] {
            if let candidate = qdRect(data, littleEndian: littleEndian),
               !candidates.contains(candidate) { candidates.append(candidate) }
        }
        return candidates
    }

    private static func qdRect(_ data: Data, littleEndian: Bool) -> CGRect? {
        guard data.count == 8 else { return nil }
        let bytes = Array(data)
        func word(_ offset: Int) -> Int {
            let bits = littleEndian
                ? UInt16(bytes[offset + 1]) << 8 | UInt16(bytes[offset])
                : UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            return Int(Int16(bitPattern: bits))
        }
        let top = word(0), left = word(2), bottom = word(4), right = word(6)
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// Production proof binds frontmost app, focused AX text surface, selected
/// scriptable tab TTY, and the shell's foreground process group. It never reads
/// AXValue, selected text, process arguments, history or the terminal buffer.
struct ScriptableShellFocusProof: GenericShellEditorFocusProof {
    let readerForPID: (Int32) -> ScriptableSelectedTTYReader?
    let frontmostPID: () -> Int32?
    let axValidator: (Int32, CGRect) -> Bool
    let foregroundValidator: (Int32, String) -> Bool

    init(readerForPID: @escaping (Int32) -> ScriptableSelectedTTYReader?,
         frontmostPID: @escaping () -> Int32?,
         axValidator: @escaping (Int32, CGRect) -> Bool = Self.axFocusedTextArea,
         foregroundValidator: @escaping (Int32, String) -> Bool = Self.shellIsForeground) {
        self.readerForPID = readerForPID
        self.frontmostPID = frontmostPID
        self.axValidator = axValidator
        self.foregroundValidator = foregroundValidator
    }

    func permits(sessionPID: Int32, tty: String) -> Bool {
        guard let appPID = frontmostPID(), appPID > 0,
              let reader = readerForPID(appPID),
              let selected = try? reader.observe(pid: appPID), selected.tty == tty,
              foregroundValidator(sessionPID, tty),
              case let matches = selected.windowBoundsCandidates.filter({ axValidator(appPID, $0) }),
              matches.count == 1, let chosen = matches.first,
              let afterAX = try? reader.observe(pid: appPID), afterAX == selected,
              axValidator(appPID, chosen),
              foregroundValidator(sessionPID, tty) else { return false }
        return frontmostPID() == appPID
    }

    static func shellIsForeground(_ pid: Int32, tty: String) -> Bool {
        guard pid > 0 else { return false }
        let fd = Darwin.open(tty, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var device = stat()
        guard Darwin.fstat(fd, &device) == 0,
              device.st_mode & mode_t(S_IFMT) == mode_t(S_IFCHR) else { return false }

        // tcgetpgrp(fd) requires this GUI process to own the controlling TTY.
        // KERN_PROC_PID reports the shell's own controlling TTY and foreground
        // group without reading its command line, environment or buffer.
        var mib = [Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_PID), pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard Darwin.sysctl(&mib, u_int(mib.count), &process, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size,
              process.kp_proc.p_pid == pid,
              process.kp_proc.p_stat != SZOMB,
              process.kp_eproc.e_ucred.cr_uid == Darwin.geteuid(),
              process.kp_eproc.e_pcred.p_ruid == Darwin.getuid(),
              process.kp_eproc.e_flag & Int32(EPROC_CTTY) != 0,
              process.kp_eproc.e_tdev == device.st_rdev,
              process.kp_eproc.e_pgid > 0,
              process.kp_eproc.e_tpgid == process.kp_eproc.e_pgid else { return false }
        return true
    }

    private static func axFocusedTextArea(pid: Int32, bounds: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, 0.05) == .success else { return false }
        var rawFocus: AnyObject?, rawWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &rawFocus) == .success,
              AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawFocus, let rawWindow,
              CFGetTypeID(rawFocus) == AXUIElementGetTypeID(),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return false }
        let focus = rawFocus as! AXUIElement, window = rawWindow as! AXUIElement
        var focusPID: pid_t = 0, windowPID: pid_t = 0
        guard AXUIElementGetPid(focus, &focusPID) == .success, focusPID == pid,
              AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid else { return false }
        var rawRole: AnyObject?, rawPosition: AnyObject?, rawSize: AnyObject?, rawOwnerWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(focus, kAXRoleAttribute as CFString, &rawRole) == .success,
              (rawRole as? String) == kAXTextAreaRole,
              AXUIElementCopyAttributeValue(focus, kAXWindowAttribute as CFString, &rawOwnerWindow) == .success,
              let rawOwnerWindow, CFGetTypeID(rawOwnerWindow) == AXUIElementGetTypeID(),
              CFEqual(rawOwnerWindow, window),
              AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return false }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return false }
        let actual = CGRect(origin: point, size: size)
        return abs(actual.minX - bounds.minX) <= 2 && abs(actual.minY - bounds.minY) <= 2
            && abs(actual.width - bounds.width) <= 2 && abs(actual.height - bounds.height) <= 2
    }
}
