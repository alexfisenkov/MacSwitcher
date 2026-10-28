import AppKit

/// Shared fixed placement for nonactivating feedback panels.
enum FeedbackPanelPlacement {
    static let inset: CGFloat = 14

    static func origin(size: NSSize, mouseLocation: NSPoint = NSEvent.mouseLocation,
                       screens: [NSScreen] = NSScreen.screens,
                       fallback: NSScreen? = NSScreen.main) -> NSPoint? {
        guard let screen = screens.first(where: { $0.frame.contains(mouseLocation) }) ?? fallback ?? screens.first else {
            return nil
        }
        let visible = screen.visibleFrame
        let x = visible.maxX - size.width - inset
        let y = visible.minY + inset
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return NSPoint(x: min(max(x, visible.minX), maxX).rounded(),
                       y: min(max(y, visible.minY), maxY).rounded())
    }
}
