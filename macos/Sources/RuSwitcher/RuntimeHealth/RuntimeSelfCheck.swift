import Foundation

/// Offline synthetic checks of production pure functions. This runner never
/// selects an input source or reads a real editor, clipboard, profile or disk.
enum RuntimeSelfCheck {
    enum ID: String, CaseIterable {
        case gesture, mapping, shellWire, profileTransform
    }
    struct Result: Equatable {
        let id: ID
        let passed: Bool
    }

    static func run() -> [Result] {
        ID.allCases.map { id in Result(id: id, passed: check(id)) }
    }

    private static func check(_ id: ID) -> Bool {
        switch id {
        case .gesture:
            var gesture = CombinedShiftGesture()
            let en = CombinedShiftContext(sourceLayoutID: "en", targetLayoutID: "ru")
            let ru = en.reversed
            gesture.press(.left, at: 10_000_000, context: en)
            guard gesture.release(.left, at: 60_000_000) == .switchLayout(en) else { return false }
            gesture.press(.right, at: 130_000_000, context: ru)
            return gesture.release(.right, at: 180_000_000) == .convert(en)
        case .mapping:
            return KeyMapping.convert("ghbdtn") == "привет"
        case .shellWire:
            let original = "synthetic 🙂"
            return GenericShellEditorWire.decode(GenericShellEditorWire.encode(original)) == original
        case .profileTransform:
            let original = Data("# synthetic fixture\n".utf8)
            let path = "/synthetic/terminal-zle.zsh"
            guard let (_, installed) = try? ShellBridgeProfilePatch.transformed(
                    profileData: original, resourcePath: path),
                  let (_, restored) = try? ShellBridgeProfilePatch.transformed(
                    profileData: installed, resourcePath: path, uninstall: true) else { return false }
            return restored == original
        }
    }
}
