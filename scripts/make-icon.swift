// Draws the DemoRec app icon into an .iconset folder: a dark tile, a mini screen, a red record dot.
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // Tile (macOS icon grid: 824pt body inset 100pt).
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!.draw(in: tilePath, angle: -90)

    // Mini screen.
    let screen = NSRect(x: 230 * s, y: 330 * s, width: 564 * s, height: 370 * s)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 36 * s, yRadius: 36 * s)
    NSColor(white: 1, alpha: 0.10).setFill()
    screenPath.fill()
    NSColor(white: 1, alpha: 0.85).setStroke()
    screenPath.lineWidth = 22 * s
    screenPath.stroke()

    // Record dot in the bottom-right corner of the screen, where you appear.
    let dot = NSRect(x: 600 * s, y: 250 * s, width: 230 * s, height: 230 * s)
    NSColor(white: 0.08, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot.insetBy(dx: -18 * s, dy: -18 * s)).fill()
    NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
