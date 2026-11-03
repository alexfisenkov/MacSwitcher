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
    func testShortPaneContentStaysAtTopForDifferentViewportHeights() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let controller = SettingsWindowController()
        for viewportHeight: CGFloat in [600, 680] {
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
            let control = NSButton(frame: NSRect(x: 20, y: 150, width: 200, height: 22))
            pane.addSubview(control)

            let scrollView = try XCTUnwrap(controller.topAligned(pane) as? NSScrollView)
            scrollView.frame = NSRect(x: 0, y: 0, width: 460, height: viewportHeight)
            scrollView.layoutSubtreeIfNeeded()

            XCTAssertNotNil(scrollView.documentView)
            let clipView = scrollView.contentView
            let visible = clipView.bounds
            let controlRect = control.convert(control.bounds, to: clipView)
            let topGap = clipView.isFlipped
                ? controlRect.minY - visible.minY
                : visible.maxY - controlRect.maxY
            XCTAssertLessThanOrEqual(topGap, 30, "viewport=\(viewportHeight), gap=\(topGap)")
        }
    }

    @MainActor
    func testShortPaneDoesNotScrollIntoEmptyDocumentAfterViewportShrinks() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        let firstControl = NSButton(frame: NSRect(x: 20, y: 150, width: 200, height: 22))
        pane.addSubview(firstControl)
        let scrollView = try XCTUnwrap(SettingsWindowController().topAligned(pane) as? NSScrollView)
        scrollView.frame.size.height = 320
        scrollView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let proposedBounds = NSRect(origin: NSPoint(x: 0, y: 10_000), size: clipView.bounds.size)
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        clipView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clipView)

        XCTAssertEqual(clipView.bounds.minY, 0, accuracy: 0.5)
        let controlRect = firstControl.convert(firstControl.bounds, to: clipView)
        let topGap = clipView.isFlipped
            ? controlRect.minY - clipView.bounds.minY
            : clipView.bounds.maxY - controlRect.maxY
        XCTAssertLessThanOrEqual(topGap, 30)
    }

    @MainActor
    func testLastControlInLongPaneRemainsReachableAfterViewportShrinks() throws {
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 900))
        let lastControl = NSButton(frame: NSRect(x: 20, y: 10, width: 200, height: 22))
        pane.addSubview(lastControl)
        let scrollView = try XCTUnwrap(SettingsWindowController().topAligned(pane) as? NSScrollView)
        scrollView.frame.size.height = 320
        scrollView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let proposedBounds = NSRect(origin: NSPoint(x: 0, y: 10_000), size: clipView.bounds.size)
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        clipView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clipView)

        let lastControlRect = lastControl.convert(lastControl.bounds, to: clipView)
        XCTAssertTrue(lastControlRect.intersects(clipView.bounds))
        XCTAssertLessThanOrEqual(clipView.bounds.maxY, 900.5)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
