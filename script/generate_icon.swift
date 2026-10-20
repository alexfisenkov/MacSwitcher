import AppKit

// Original MacSwitcher artwork. No vendor artwork is used.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appendingPathComponent(".черновики/MacSwitcher.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let n = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let factor = CGFloat(n) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        let dark = color(20, 35, 61)
        dark.setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 220, yRadius: 220).fill()
        for (x, text, fill) in [(155.0, "A", color(85, 200, 255)), (559.0, "Я", color(143, 240, 201))] {
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 424, width: 310, height: 370), xRadius: 65, yRadius: 65).fill()
            let font = NSFont.systemFont(ofSize: 260, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dark]
            let label = NSAttributedString(string: text, attributes: attrs)
            label.draw(at: NSPoint(x: x + (310 - label.size().width) / 2, y: 450))
        }
        let arrows = NSBezierPath()
        arrows.lineWidth = 32
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        for points in [[NSPoint(x: 270, y: 320), NSPoint(x: 740, y: 320), NSPoint(x: 675, y: 385)],
                       [NSPoint(x: 740, y: 320), NSPoint(x: 675, y: 255)],
                       [NSPoint(x: 754, y: 220), NSPoint(x: 284, y: 220), NSPoint(x: 349, y: 285)],
                       [NSPoint(x: 284, y: 220), NSPoint(x: 349, y: 155)]] {
            arrows.move(to: points[0])
            for point in points.dropFirst() { arrows.line(to: point) }
        }
        NSColor.white.setStroke()
        arrows.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let path = set.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try rep.representation(using: .png, properties: [:])!.write(to: path)
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("assets/MacSwitcher.icns").path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
