// Draws the Cameo app icon into an .iconset folder: a dark tile with one flowing glyph, a gradient "C" sweeping
// around a record dot (a record button, a lens, and the C of Cameo).
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    cg.scaleBy(x: s, y: s)

    // Tile (macOS icon grid: 824pt body inset 100pt), near-black with a soft shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    cg.addPath(tile)
    cg.setFillColor(rgb(0x121218))
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(tile)
    cg.clip()
    cg.drawLinearGradient(gradient([rgb(0x24242E), rgb(0x0E0E13)], [0, 1]),
                          start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()

    let center = CGPoint(x: 512, y: 512)

    // The C: one thick arc with round ends, opening to the upper right, its colour flowing warm to cool.
    let arc = CGMutablePath()
    arc.addArc(center: center, radius: 236, startAngle: 58 * .pi / 180, endAngle: 6 * .pi / 180, clockwise: false)
    let ribbon = arc.copy(strokingWithWidth: 92, lineCap: .round, lineJoin: .round, miterLimit: 10)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: rgb(0xFF4D6D, 0.2))
    cg.addPath(ribbon)
    cg.setFillColor(rgb(0xFF5A6E))
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(ribbon)
    cg.clip()
    cg.drawLinearGradient(gradient([rgb(0xFFB36B), rgb(0xFF5A6E), rgb(0x9B5CFF)], [0, 0.5, 1]),
                          start: CGPoint(x: 760, y: 760), end: CGPoint(x: 300, y: 260), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()

    // The record dot.
    let dot = CGRect(x: center.x - 96, y: center.y - 96, width: 192, height: 192)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: rgb(0xFF3B30, 0.3))
    cg.setFillColor(rgb(0xFF3B30))
    cg.fillEllipse(in: dot)
    cg.restoreGState()
    cg.saveGState()
    cg.addEllipse(in: dot)
    cg.clip()
    cg.drawLinearGradient(gradient([rgb(0xFF7A5C), rgb(0xF0263A)], [0, 1]),
                          start: CGPoint(x: dot.midX, y: dot.maxY), end: CGPoint(x: dot.midX, y: dot.minY), options: [])
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
