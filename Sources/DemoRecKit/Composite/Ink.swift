import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// The green trail the pointer leaves while you hold the trail shortcut. Each bit of the trail fades out on its own
/// a moment after it was drawn, like a laser pointer, so the trail follows the pointer and then disappears.
public struct InkTrail {
    private let strokes: [[CursorTrack.Point]]
    /// Seconds a bit of trail stays before it's gone.
    public var fade = InkTrail.defaultFade
    public static let defaultFade = 1.5

    public static let color = CIColor(red: 0.2, green: 0.85, blue: 0.35)

    public init?(track: CursorTrack) {
        self.init(strokes: track.ink ?? [])
    }

    public init?(strokes: [[CursorTrack.Point]]) {
        let ink = strokes.filter { !$0.isEmpty }
        guard !ink.isEmpty else { return nil }
        self.strokes = ink
    }

    /// The trail at time `t` (seconds on the cursor track's clock) over a screen of `size` pixels, or nil when
    /// there's nothing to draw.
    public func image(at t: Double, size: CGSize) -> CIImage? {
        // How strong each point is now: 1 when just drawn, easing to 0 at `fade`.
        var visible: [[(p: CGPoint, a: CGFloat)]] = []
        for stroke in strokes {
            guard let first = stroke.first, first.t <= t, let last = stroke.last, t - last.t < fade else { continue }
            var run: [(p: CGPoint, a: CGFloat)] = []
            for q in stroke where q.t <= t && t - q.t < fade {
                let age = (t - q.t) / fade
                run.append((CGPoint(x: q.x * size.width, y: (1 - q.y) * size.height), CGFloat(1 - age * age)))
            }
            if !run.isEmpty { visible.append(run) }
        }
        guard !visible.isEmpty else { return nil }

        let width = max(4, size.height * 0.006)
        let glow = width * 1.6
        let pad = width * 2 + glow * 3
        var box = CGRect.null
        for run in visible { for v in run { box = box.union(CGRect(origin: v.p, size: .zero)) } }
        box = box.insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: size)).integral
        guard box.width >= 1, box.height >= 1 else { return nil }

        // A grey mask of the trail: each segment as bright as its newer end. Lighten keeps the brightest where
        // segments overlap, so the round joins don't show up as beads.
        guard let ctx = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.setBlendMode(.lighten)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for run in visible {
            if run.count == 1 {
                let v = run[0]
                ctx.setFillColor(gray: v.a, alpha: 1)
                ctx.fillEllipse(in: CGRect(x: v.p.x - width / 2, y: v.p.y - width / 2, width: width, height: width))
                continue
            }
            for i in 1..<run.count {
                // A touch thinner as it fades, so the tail tapers.
                ctx.setLineWidth(width * (0.4 + 0.6 * run[i].a))
                ctx.setStrokeColor(gray: run[i].a, alpha: 1)
                ctx.move(to: run[i - 1].p)
                ctx.addLine(to: run[i].p)
                ctx.strokePath()
            }
        }
        // A brighter dot where the pointer is now, while you're still drawing.
        if let head = visible.last?.last, head.a > 0.97 {
            let r = width * 1.1
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: head.p.x - r, y: head.p.y - r, width: r * 2, height: r * 2))
        }
        guard let cg = ctx.makeImage() else { return nil }

        let mask = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
        let green = CIImage(color: Self.color).cropped(to: box)
        let clear = CIImage(color: .clear).cropped(to: box)
        func tinted(_ m: CIImage) -> CIImage {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = green
            blend.backgroundImage = clear
            blend.maskImage = m
            return blend.outputImage ?? clear
        }
        let soft = mask.clampedToExtent().applyingGaussianBlur(sigma: glow).cropped(to: box)
        let halo = tinted(soft).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.7)])
        return tinted(mask).composited(over: halo)
    }
}

/// The trail as it's being drawn, for live previews: strokes come in from the pointer watcher's queue and the
/// preview draws them on its own. Strokes that have faded away are forgotten.
public final class LiveInk: @unchecked Sendable {
    private let lock = NSLock()
    private var strokes: [[CursorTrack.Point]] = []
    private var drawing = false
    private let fade = InkTrail.defaultFade

    public init() {}

    public func begin(_ p: CursorTrack.Point) {
        lock.withLock { drawing = true; strokes.append([p]) }
    }

    /// The pointer moved: part of the stroke if the trail shortcut is held, otherwise nothing.
    public func add(_ p: CursorTrack.Point) {
        lock.withLock { if drawing, !strokes.isEmpty { strokes[strokes.count - 1].append(p) } }
    }

    public func end() {
        lock.withLock { drawing = false }
    }

    public func clear() {
        lock.withLock { drawing = false; strokes = [] }
    }

    /// Whether there's anything on screen at `t`, so the preview knows to keep redrawing.
    public func isVisible(at t: Double) -> Bool {
        lock.withLock { drawing || strokes.contains { ($0.last?.t ?? -.infinity) > t - fade } }
    }

    public func image(at t: Double, size: CGSize) -> CIImage? {
        let current = lock.withLock { () -> [[CursorTrack.Point]] in
            let held = drawing ? strokes.popLast() : nil
            strokes.removeAll { ($0.last?.t ?? -.infinity) <= t - fade }
            if let held { strokes.append(held) }
            return strokes
        }
        return InkTrail(strokes: current)?.image(at: t, size: size)
    }
}
