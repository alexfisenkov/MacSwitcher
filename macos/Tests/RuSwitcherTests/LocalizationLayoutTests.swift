import AppKit
import XCTest
@testable import RuSwitcher

/// No text is cut off in any of the 16 languages: every settings tab, the welcome window and the caret hint.
final class LocalizationLayoutTests: XCTestCase {
    private let key = "com.ruswitcher.interfaceLanguage"
    private var priorPolicy: NSApplication.ActivationPolicy = .prohibited
    private var priorLanguage: Any?

    @MainActor
    override func setUp() async throws {
        priorPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        priorLanguage = UserDefaults.standard.object(forKey: key)
    }

    @MainActor
    override func tearDown() async throws {
        NSApplication.shared.setActivationPolicy(priorPolicy)
        if let priorLanguage { UserDefaults.standard.set(priorLanguage, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        L10n.reloadLanguage()
    }

    @MainActor
    private func select(_ language: String) {
        UserDefaults.standard.set(language, forKey: key)
        L10n.reloadLanguage()
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Wrapping labels must be tall enough; one-line labels and buttons wide enough for their text.
    @MainActor
    private func assertTextFits(in root: NSView, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        for view in descendants(of: root) where !view.isHiddenOrHasHiddenAncestor {
            if let field = view as? NSTextField, !field.stringValue.isEmpty, !field.isEditable {
                let wraps = field.lineBreakMode == .byWordWrapping || field.lineBreakMode == .byCharWrapping
                if wraps {
                    let needed = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.frame.width,
                        height: 10_000)).height ?? 0
                    XCTAssertLessThanOrEqual(needed, field.frame.height + 1, "\(context): \(field.stringValue)",
                        file: file, line: line)
                } else {
                    let needed = field.cell?.cellSize.width ?? 0
                    XCTAssertLessThanOrEqual(needed, field.frame.width + 1, "\(context): \(field.stringValue)",
                        file: file, line: line)
                }
            } else if let button = view as? NSButton, !(button is NSPopUpButton), !button.title.isEmpty,
                      button.bezelStyle != .disclosure, button.frame.width > 0 {
                let needed = button.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: button.frame.width,
                    height: 10_000)).height ?? 0
                XCTAssertLessThanOrEqual(needed, button.frame.height + 2, "\(context): \(button.title)",
                    file: file, line: line)
            }
        }
    }

    @MainActor
    func testEverySettingsTabFitsInEveryLanguage() throws {
        for language in L10n.supportedLanguages.sorted() {
            select(language)
            let controller = SettingsWindowController()
            let tabs = controller.makeNativeTabs(nativeShiftApplied: true, wholeLine: false, backupVerified: true)
            let root = controller.makeSettingsContent(tabView: tabs)
            root.frame = NSRect(x: 0, y: 0, width: 600, height: 520)
            let words = try XCTUnwrap(tabs.tabViewItem(at: 1).view as? NSTabView)
            let settings = try XCTUnwrap(tabs.tabViewItem(at: 2).view as? NSTabView)
            var panes: [(String, NSView)] = [("instructions", tabs.tabViewItem(at: 0).view!)]
            for index in 0..<words.numberOfTabViewItems { panes.append(("words-\(index)", words.tabViewItem(at: index).view!)) }
            for index in 0..<settings.numberOfTabViewItems { panes.append(("settings-\(index)", settings.tabViewItem(at: index).view!)) }
            for (name, pane) in panes {
                root.layoutSubtreeIfNeeded()
                assertTextFits(in: pane, "language=\(language) pane=\(name)")
                if name == "words-0" {
                    for box in descendants(of: pane).compactMap({ $0 as? NSBox }) {
                        XCTAssertGreaterThanOrEqual(box.frame.minY, 0, "language=\(language): a words row left the pane")
                    }
                }
            }
            let wholeLine = controller.makeNativeTabs(nativeShiftApplied: true, wholeLine: true, backupVerified: false)
            assertTextFits(in: wholeLine.tabViewItem(at: 0).view!, "language=\(language) whole-line")
        }
    }

    @MainActor
    func testWelcomeWindowFitsInEveryLanguage() {
        for language in L10n.supportedLanguages.sorted() {
            select(language)
            for permissions in [(false, false), (true, false), (true, true)] {
                let root = WelcomeWindowController().makeContent(accessibility: permissions.0,
                    inputMonitoring: permissions.1, automaticCorrection: true, launchAtLogin: false)
                root.layoutSubtreeIfNeeded()
                assertTextFits(in: root, "language=\(language) welcome=\(permissions)")
            }
        }
    }

    @MainActor
    func testCaretHintIsNotTruncatedInEveryLanguage() {
        for language in L10n.supportedLanguages.sorted() {
            select(language)
            let hint = CorrectionHintPanel()
            hint.update(word: "приветствие", near: NSRect(x: 300, y: 400, width: 0, height: 16))
            let needed = hint.label.cell?.cellSize.width ?? 0
            XCTAssertLessThanOrEqual(needed, hint.label.frame.width + 1, "language=\(language): \(hint.label.stringValue)")
        }
    }

    @MainActor
    func testRenderLanguageSamplesWhenRequested() throws {
        guard let folder = ProcessInfo.processInfo.environment["MACSWITCHER_PREVIEW_DIR"] else {
            throw XCTSkip("Offscreen component export is opt-in")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("l10n", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["de", "ja", "ka"] {
            select(language)
            let controller = SettingsWindowController()
            let tabs = controller.makeNativeTabs(nativeShiftApplied: true, wholeLine: false, backupVerified: true)
            let root = controller.makeSettingsContent(tabView: tabs)
            root.frame = NSRect(x: 0, y: 0, width: 600, height: 520)
            root.appearance = NSAppearance(named: .aqua)
            for (name, index, section) in [("general", 2, 0), ("more", 2, 2), ("words", 1, 0), ("learning", 1, 3), ("guide", 0, 0)] {
                tabs.selectTabViewItem(at: index)
                if index == 2, let settings = tabs.tabViewItem(at: 2).view as? NSTabView {
                    settings.selectTabViewItem(at: min(section, settings.numberOfTabViewItems - 1))
                }
                if index == 1, let words = tabs.tabViewItem(at: 1).view as? NSTabView {
                    words.selectTabViewItem(at: min(section, words.numberOfTabViewItems - 1))
                }
                root.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(language)-light-\(name).png"))
            }
            let welcome = WelcomeWindowController().makeContent(accessibility: true, inputMonitoring: false,
                automaticCorrection: true, launchAtLogin: false)
            welcome.appearance = NSAppearance(named: .aqua)
            welcome.layoutSubtreeIfNeeded()
            let backdrop = NSView(frame: welcome.frame)
            backdrop.wantsLayer = true
            backdrop.appearance = welcome.appearance
            backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            backdrop.addSubview(welcome)
            backdrop.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
            backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("\(language)-light-welcome.png"))
        }
    }
}
