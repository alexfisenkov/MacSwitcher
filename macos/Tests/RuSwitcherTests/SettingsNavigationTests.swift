import AppKit
import XCTest
@testable import RuSwitcher

final class SettingsNavigationTests: XCTestCase {
    @MainActor
    func testNavigationUsesSuppliedPanesAndFitsVisibleFrame() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 600))
        let first = NSTabViewItem(identifier: "first")
        first.label = "Основные"
        first.view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        let second = NSTabViewItem(identifier: "second")
        second.label = "Второй раздел"
        second.view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        tabs.addTabViewItem(first)
        tabs.addTabViewItem(second)

        let controller = SettingsWindowController()
        let content = controller.makeSettingsContent(tabView: tabs)
        let views = descendants(of: content)
        let navigation = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        let splitView = try XCTUnwrap(views.compactMap { $0 as? NSSplitView }.first)

        XCTAssertEqual(navigation.numberOfRows, 2)
        XCTAssertEqual(navigation.selectedRow, 0)
        XCTAssertEqual(controller.splitView(splitView, constrainMinCoordinate: 0, ofSubviewAt: 0), 130)
        XCTAssertEqual(controller.splitView(splitView, constrainMaxCoordinate: 700, ofSubviewAt: 0), 380)
        navigation.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification,
                                                              object: navigation))
        XCTAssertTrue(tabs.selectedTabViewItem === second)

        let fitted = controller.fittedSettingsWindowSize(
            visibleFrame: NSRect(x: 0, y: 0, width: 760, height: 500)
        )
        XCTAssertLessThanOrEqual(fitted.width, 700)
        XCTAssertLessThanOrEqual(fitted.height, 440)
    }

    @MainActor
    func testGeneralPaneRefreshUsesInjectedReplacementAndPreservesSelection() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 600))
        let general = NSTabViewItem(identifier: "settings.general")
        general.label = "General"
        general.view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        let about = NSTabViewItem(identifier: "about")
        about.label = "About"
        about.view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(about)
        tabs.selectTabViewItem(general)

        let controller = SettingsWindowController()
        _ = controller.makeSettingsContent(tabView: tabs)
        let replacement = NSTabViewItem(identifier: "settings.general")
        replacement.label = "General"
        let refreshedContent = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
        refreshedContent.identifier = NSUserInterfaceItemIdentifier("injected-general-content")
        replacement.view = refreshedContent

        controller.refreshGeneralTabPresentation { replacement }

        XCTAssertEqual(tabs.numberOfTabViewItems, 2)
        XCTAssertTrue(tabs.selectedTabViewItem === replacement)
        XCTAssertTrue(tabs.tabViewItem(at: 0) === replacement)
        XCTAssertEqual(tabs.tabViewItem(at: 0).view?.identifier?.rawValue, "injected-general-content")
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
