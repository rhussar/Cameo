import CoreGraphics
import Foundation

/// A desktop-style wallpaper drawn from shapes, so it's crisp at any frame size: layered hills, flowing waves,
/// petals, ribbons of light. Original designs in the spirit of macOS and Windows wallpapers.
public struct Wallpaper: Sendable, Equatable, Hashable {
    public var name: String
    /// Fine grain over the finished picture, in display values (see `Compositor`); also hides gradient banding.
    public var grain: Double

    public static let all: [Wallpaper] = [
        Wallpaper(name: "Dune", grain: 0.025),
        Wallpaper(name: "Lagoon", grain: 0.025),
        Wallpaper(name: "Horizon", grain: 0.025),
        Wallpaper(name: "Petal", grain: 0.02),
        Wallpaper(name: "Night Petal", grain: 0.03),
        Wallpaper(name: "Aurora", grain: 0.035),
        Wallpaper(name: "Ember", grain: 0.03),
        Wallpaper(name: "Silk", grain: 0.02),
        Wallpaper(name: "Slate", grain: 0.035),
    ]

    /// Matches ignoring case, spaces and dashes, so "night-petal" finds "Night Petal".
    public static func named(_ name: String) -> Wallpaper? {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return all.first { key($0.name) == key(name) }
    }

    /// The wallpaper drawn at a pixel size.
    public func render(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              // 16 bits a channel keeps the long gradients smooth.
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let p = Painter(ctx: ctx, W: CGFloat(width), H: CGFloat(height))
        switch name {
        case "Dune": p.dune()
        case "Lagoon": p.lagoon()
        case "Horizon": p.horizon()
        case "Petal": p.petal(dark: false)
        case "Night Petal": p.petal(dark: true)
        case "Aurora": p.aurora()
        case "Ember": p.ember()
        case "Silk": p.folds(dark: false)
        case "Slate": p.folds(dark: true)
        default: p.dune()
        }
        return ctx.makeImage()
    }
}

/// Drawing helpers in normalised coordinates: x 0...1 left to right, y 0...1 bottom to top.
private struct Painter {
    let ctx: CGContext
    let W: CGFloat
    let H: CGFloat

    typealias RGB = (CGFloat, CGFloat, CGFloat)

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * W, y: y * H) }
    func color(_ c: RGB, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a) }

    func gradient(_ stops: [(CGFloat, RGB, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map { color($0.1, $0.2) } as CFArray, locations: stops.map(\.0))!
    }

    /// Fills the whole frame with a linear gradient between two normalised points.
    func fill(_ stops: [(CGFloat, RGB)], from a: CGPoint, to b: CGPoint) {
        ctx.drawLinearGradient(gradient(stops.map { ($0.0, $0.1, 1) }), start: pt(a.x, a.y), end: pt(b.x, b.y),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// A soft round light. `radius` is a fraction of the frame's long side.
    func glow(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, _ c: RGB, _ a: CGFloat) {
        let r = radius * max(W, H)
        ctx.drawRadialGradient(gradient([(0, c, a), (0.45, c, a * 0.45), (1, c, 0)]), startCenter: pt(x, y), startRadius: 0,
                               endCenter: pt(x, y), endRadius: r, options: [])
    }

    /// A smooth curve through points (Catmull-Rom as cubic Béziers), appended to `path`.
    func curve(_ pts: [CGPoint], into path: CGMutablePath, move: Bool) {
        let p = pts.map { pt($0.x, $0.y) }
        guard p.count > 1 else { return }
        if move { path.move(to: p[0]) } else { path.addLine(to: p[0]) }
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    /// The area between a top curve and either a bottom curve or the bottom of the frame.
    func region(top: [CGPoint], bottom: [CGPoint]?) -> CGPath {
        let path = CGMutablePath()
        curve(top, into: path, move: true)
        if let bottom {
            curve(bottom.reversed(), into: path, move: false)
        } else {
            path.addLine(to: pt(top.last!.x, -0.1))
            path.addLine(to: pt(top.first!.x, -0.1))
        }
        path.closeSubpath()
        return path
    }

    /// Fills a shape with a vertical gradient across its height (top colour first). `shadow` adds a soft glow or
    /// cast shadow around it; `dy` moves that shadow up (positive) or down, as a fraction of the frame height.
    func shape(_ path: CGPath, _ top: RGB, _ bottom: RGB, alpha: CGFloat = 1,
               shadow: (RGB, CGFloat, CGFloat, CGFloat)? = nil) {
        if let (c, a, blur, dy) = shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: dy * H), blur: blur * H, color: color(c, a))
            ctx.addPath(path)
            ctx.setFillColor(color(bottom, alpha))
            ctx.fillPath()
            ctx.restoreGState()
        }
        let box = path.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, top, alpha), (1, bottom, alpha)]),
                               start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// A shape as pure blurred light: drawn far off the frame so only its shadow lands in it.
    func blurred(_ path: CGPath, _ c: RGB, _ a: CGFloat, blur: CGFloat) {
        let away = W * 4
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: -away, height: 0), blur: blur * H, color: color(c, a))
        ctx.translateBy(x: away, y: 0)
        ctx.addPath(path)
        ctx.setFillColor(color(c, 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    func shifted(_ pts: [CGPoint], _ dy: CGFloat) -> [CGPoint] { pts.map { P($0.x, $0.y + dy) } }

    // MARK: Wallpapers

    /// Warm desert hills at golden hour, each crest catching the light.
    func dune() {
        fill([(0, (0.99, 0.91, 0.82)), (0.55, (0.98, 0.78, 0.64)), (1, (0.95, 0.66, 0.52))], from: P(0, 1), to: P(0, 0.3))
        glow(0.76, 0.80, radius: 0.32, (1, 0.97, 0.90), 0.85)
        let hills: [([CGPoint], RGB, RGB)] = [
            ([P(-0.05, 0.60), P(0.18, 0.67), P(0.44, 0.58), P(0.70, 0.64), P(1.05, 0.55)], (0.96, 0.70, 0.56), (0.91, 0.60, 0.49)),
            ([P(-0.05, 0.46), P(0.26, 0.53), P(0.55, 0.44), P(0.80, 0.51), P(1.05, 0.46)], (0.88, 0.55, 0.44), (0.79, 0.45, 0.38)),
            ([P(-0.05, 0.31), P(0.30, 0.37), P(0.60, 0.27), P(0.86, 0.34), P(1.05, 0.30)], (0.71, 0.37, 0.34), (0.59, 0.28, 0.29)),
            ([P(-0.05, 0.15), P(0.36, 0.21), P(0.66, 0.12), P(1.05, 0.19)], (0.45, 0.21, 0.24), (0.31, 0.14, 0.19)),
        ]
        for (top, a, b) in hills {
            shape(region(top: top, bottom: nil), a, b, shadow: ((1, 0.93, 0.82), 0.55, 0.012, 0.004))
        }
    }

    /// Deep ocean swells rolling in, lighter and brighter towards the shore.
    func lagoon() {
        fill([(0, (0.03, 0.08, 0.22)), (1, (0.06, 0.22, 0.44))], from: P(0, 1), to: P(0, 0))
        glow(0.22, 0.82, radius: 0.5, (0.22, 0.55, 0.88), 0.45)
        let waves: [([CGPoint], RGB, RGB)] = [
            ([P(-0.05, 0.74), P(0.25, 0.63), P(0.50, 0.71), P(0.76, 0.53), P(1.05, 0.61)], (0.13, 0.43, 0.74), (0.05, 0.20, 0.45)),
            ([P(-0.05, 0.56), P(0.30, 0.45), P(0.55, 0.55), P(0.80, 0.38), P(1.05, 0.46)], (0.18, 0.62, 0.83), (0.06, 0.30, 0.56)),
            ([P(-0.05, 0.39), P(0.26, 0.30), P(0.56, 0.40), P(0.82, 0.24), P(1.05, 0.30)], (0.40, 0.82, 0.89), (0.10, 0.45, 0.66)),
            ([P(-0.05, 0.21), P(0.30, 0.14), P(0.62, 0.22), P(1.05, 0.10)], (0.72, 0.93, 0.93), (0.25, 0.62, 0.76)),
        ]
        for (top, a, b) in waves {
            shape(region(top: top, bottom: nil), a, b, shadow: ((0.75, 0.95, 1), 0.45, 0.014, 0.003))
        }
    }

    /// Dusk over layered mountains, the sun just above the ridge.
    func horizon() {
        fill([(0, (0.11, 0.13, 0.31)), (0.4, (0.53, 0.37, 0.58)), (0.7, (0.95, 0.62, 0.53)), (1, (1.0, 0.83, 0.64))],
             from: P(0, 1), to: P(0, 0.22))
        glow(0.62, 0.36, radius: 0.42, (1, 0.80, 0.62), 0.45)
        glow(0.62, 0.36, radius: 0.09, (1, 0.96, 0.86), 0.95)
        let ridges: [([CGPoint], RGB, RGB)] = [
            ([P(-0.05, 0.36), P(0.12, 0.44), P(0.28, 0.38), P(0.45, 0.49), P(0.63, 0.36), P(0.80, 0.43), P(1.05, 0.34)], (0.66, 0.45, 0.60), (0.52, 0.36, 0.52)),
            ([P(-0.05, 0.26), P(0.20, 0.33), P(0.38, 0.24), P(0.58, 0.31), P(0.78, 0.22), P(1.05, 0.29)], (0.43, 0.29, 0.46), (0.33, 0.22, 0.38)),
            ([P(-0.05, 0.14), P(0.30, 0.19), P(0.55, 0.11), P(0.80, 0.17), P(1.05, 0.12)], (0.24, 0.16, 0.30), (0.15, 0.10, 0.21)),
        ]
        for (top, a, b) in ridges {
            shape(region(top: top, bottom: nil), a, b, shadow: ((1, 0.85, 0.75), 0.25, 0.01, 0.003))
        }
    }

    /// A glowing flower of translucent blue petals, light or on black.
    func petal(dark: Bool) {
        if dark {
            fill([(0, (0.01, 0.02, 0.07)), (1, (0.02, 0.07, 0.20))], from: P(0, 1), to: P(1, 0))
            glow(0.55, 0.35, radius: 0.45, (0.10, 0.30, 0.80), 0.35)
        } else {
            fill([(0, (0.86, 0.92, 1.0)), (1, (0.52, 0.71, 0.96))], from: P(0, 1), to: P(1, 0))
            glow(0.55, 0.35, radius: 0.4, (1, 1, 1), 0.5)
        }
        let center = pt(0.55, 0.30)
        let L = 0.62 * H, w = 0.22 * H
        let deep: RGB = dark ? (0.03, 0.16, 0.62) : (0.02, 0.22, 0.70)
        let tip: RGB = dark ? (0.45, 0.75, 1.0) : (0.55, 0.80, 1.0)
        let halo: RGB = dark ? (0.30, 0.60, 1.0) : (1, 1, 1)
        for (i, deg) in [-72.0, 72, -36, 36, 0].enumerated() {
            let petal = CGMutablePath()
            petal.move(to: .zero)
            petal.addCurve(to: CGPoint(x: 0, y: L), control1: CGPoint(x: w * 0.95, y: L * 0.25), control2: CGPoint(x: w * 0.55, y: L * 0.97))
            petal.addCurve(to: .zero, control1: CGPoint(x: -w * 0.55, y: L * 0.97), control2: CGPoint(x: -w * 0.95, y: L * 0.25))
            var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(-deg) * .pi / 180)
            guard let path = petal.copy(using: &t) else { continue }
            let lift = CGFloat(i) * 0.04
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: (dark ? 0.06 : 0.035) * H, color: color(halo, dark ? 0.55 : 0.6))
            ctx.addPath(path)
            ctx.setFillColor(color(deep, 0.6))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let tipPoint = CGPoint(x: 0, y: L).applying(t)
            ctx.drawLinearGradient(gradient([(0, deep, 0.92), (0.65, (tip.0 * 0.8, tip.1 * 0.85, tip.2), 0.9), (1, tip, 0.85 + lift)]),
                                   start: center, end: tipPoint, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    /// Broad, soft veils of green and violet light drifting across a night sky.
    func aurora() {
        fill([(0, (0.01, 0.02, 0.06)), (1, (0.03, 0.06, 0.14))], from: P(0, 1), to: P(0, 0))
        glow(0.5, -0.25, radius: 0.65, (0.10, 0.22, 0.48), 0.5)
        func veil(_ base: [CGPoint], _ c: RGB, core: RGB) {
            blurred(region(top: shifted(base, 0.30), bottom: base), c, 0.30, blur: 0.12)
            blurred(region(top: shifted(base, 0.12), bottom: shifted(base, 0.02)), c, 0.45, blur: 0.06)
            blurred(region(top: shifted(base, 0.05), bottom: shifted(base, 0.02)), core, 0.35, blur: 0.03)
        }
        veil([P(-0.05, 0.30), P(0.32, 0.42), P(0.64, 0.28), P(1.05, 0.40)], (0.48, 0.26, 0.90), core: (0.70, 0.50, 1.0))
        veil([P(-0.05, 0.48), P(0.26, 0.60), P(0.56, 0.44), P(0.83, 0.56), P(1.05, 0.48)], (0.14, 0.82, 0.60), core: (0.55, 1.0, 0.80))
    }

    /// Glowing ribbons of orange, magenta and violet sweeping across a dark frame.
    func ember() {
        fill([(0, (0.05, 0.02, 0.05)), (1, (0.11, 0.03, 0.09))], from: P(0, 1), to: P(1, 0))
        glow(0.30, 0.75, radius: 0.5, (0.55, 0.12, 0.25), 0.35)
        let path = [P(-0.05, 0.86), P(0.30, 0.74), P(0.62, 0.52), P(1.05, 0.24)]
        let ribbons: [(CGFloat, CGFloat, RGB, RGB, RGB)] = [
            (0, 0.17, (1.0, 0.58, 0.22), (0.88, 0.17, 0.36), (1, 0.45, 0.25)),
            (-0.13, 0.12, (0.92, 0.22, 0.52), (0.47, 0.10, 0.56), (0.95, 0.25, 0.55)),
            (-0.27, 0.07, (0.58, 0.22, 0.78), (0.26, 0.08, 0.46), (0.55, 0.25, 0.85)),
        ]
        for (dy, thick, a, b, halo) in ribbons {
            let top = shifted(path, dy)
            shape(region(top: top, bottom: shifted(top, -thick)), a, b, shadow: (halo, 0.65, 0.04, 0))
        }
    }

    /// Folded sheets of paper with soft shadows: light (Silk) or dark (Slate).
    func folds(dark: Bool) {
        if dark {
            fill([(0, (0.17, 0.18, 0.20)), (1, (0.07, 0.07, 0.09))], from: P(0, 1), to: P(1, 0))
        } else {
            fill([(0, (0.98, 0.98, 0.99)), (1, (0.87, 0.88, 0.91))], from: P(0, 1), to: P(1, 0))
        }
        let sheets: [[CGPoint]] = [
            [P(-0.05, 0.76), P(0.30, 0.66), P(0.62, 0.73), P(1.05, 0.55)],
            [P(-0.05, 0.53), P(0.34, 0.42), P(0.66, 0.50), P(1.05, 0.34)],
            [P(-0.05, 0.30), P(0.30, 0.22), P(0.70, 0.30), P(1.05, 0.14)],
        ]
        for (i, top) in sheets.enumerated() {
            let k = CGFloat(i) * 0.02
            let a: RGB = dark ? (0.23 - k, 0.24 - k, 0.27 - k) : (0.99 - k, 0.99 - k, 1.0 - k)
            let b: RGB = dark ? (0.11 - k / 2, 0.11 - k / 2, 0.13 - k / 2) : (0.89 - k, 0.90 - k, 0.93 - k)
            shape(region(top: top, bottom: nil), a, b, shadow: ((0, 0, 0), dark ? 0.45 : 0.13, 0.03, 0.006))
        }
    }
}
