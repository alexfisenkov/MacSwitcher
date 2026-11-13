import AppKit
import Foundation

/// Reads only local scripting-definition files. It never asks an application
/// for permission or sends an Apple Event during capability discovery.
final class SelectedTTYCapabilityDiscovery: @unchecked Sendable {
    private enum Cached { case supported(ScriptableSelectedTTYCapability), unsupported }
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]

    func capability(pid: Int32) -> ScriptableSelectedTTYCapability? {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return nil }
        let key = bundleURL.path
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            if case .supported(let capability) = cached { return capability }
            return nil
        }
        lock.unlock()
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: resources,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        let definitions = files.filter { $0.pathExtension.lowercased() == "sdef" }
        let matches = definitions.compactMap { file -> ScriptableSelectedTTYCapability? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size <= 1_048_576,
                  let data = try? Data(contentsOf: file) else { return nil }
            return Self.parse(data)
        }
        let selected = matches.count == 1 ? matches[0] : nil
        lock.lock(); cache[key] = selected.map(Cached.supported) ?? .unsupported; lock.unlock()
        return selected
    }

    static func parse(_ data: Data) -> ScriptableSelectedTTYCapability? {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let collector = Collector()
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return collector.capability()
    }

    private final class Collector: NSObject, XMLParserDelegate {
        private var currentClass: String?
        private var codes: [String: Set<String>] = [:]

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes: [String: String]) {
            if elementName == "class" { currentClass = attributes["name"]?.lowercased() }
            guard let currentClass,
                  let name = attributes["name"]?.lowercased(),
                  let code = attributes["code"], code.utf8.count == 4 else { return }
            if currentClass == "window", elementName == "contents", name == "selected tab" {
                codes["selectedTab", default: []].insert(code)
            } else if currentClass == "window", elementName == "property" {
                let propertyName: String?
                switch name {
                case "frontmost": propertyName = "frontmost"
                case "id": propertyName = "windowID"
                case "bounds": propertyName = "bounds"
                default: propertyName = nil
                }
                if let propertyName { codes[propertyName, default: []].insert(code) }
            } else if currentClass == "tab", elementName == "property", name == "tty",
                      attributes["access"] == "r" {
                codes["tty", default: []].insert(code)
            }
            if elementName == "class", currentClass == "window" { codes["window", default: []].insert(code) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "class" { currentClass = nil }
        }

        func capability() -> ScriptableSelectedTTYCapability? {
            func code(_ name: String) -> OSType? {
                guard let values = codes[name], values.count == 1, let value = values.first else { return nil }
                return value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
            }
            guard let window = code("window"), let selected = code("selectedTab"),
                  let tty = code("tty"), let frontmost = code("frontmost"),
                  let id = code("windowID"), let bounds = code("bounds") else { return nil }
            return ScriptableSelectedTTYCapability(windowClass: window,
                selectedTabProperty: selected, ttyProperty: tty,
                frontmostProperty: frontmost, windowIDProperty: id,
                boundsProperty: bounds)
        }
    }
}
