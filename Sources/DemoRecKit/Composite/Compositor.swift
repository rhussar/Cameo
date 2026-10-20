import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Cuts the presenter out of the camera frame and places the cutout over the screen frame.
/// Pure CoreImage; takes CIImages and returns a CIImage so it works for files now and live frames later.
public final class Compositor {
    private let layout: Layout
    /// A preset or picture background is the same every frame, so it's drawn once per frame size and kept as pixels.
    private let backgroundLock = NSLock()
    private var backgroundCache: (size: CGSize, image: CIImage)?
    private lazy var backgroundContext = CIContext(options: [.cacheIntermediates: false])

    public init(layout: Layout) {
        self.layout = layout
    }

    public func cutout(camera: CIImage, mask: CIImage?) -> CIImage {
        var cam = camera
        if layout.mirror {
            cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -cam.extent.width, y: 0))
                .transformed(by: CGAffineTransform(translationX: cam.extent.width, y: 0))
            cam = cam.transformed(by: CGAffineTransform(translationX: -cam.extent.minX, y: 0))
        }
        let guide = cam
        cam = adjusted(cam)
        guard let mask else { return cam }
        var m = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
        if layout.mirror {
            m = m.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).transformed(by: CGAffineTransform(translationX: m.extent.width, y: 0))
        }
        m = Self.refine(mask: m, guide: guide)
        if layout.feather > 0 {
            // The refined edge is already soft; half the sigma keeps the old default from blurring it again.
            m = m.clampedToExtent().applyingGaussianBlur(sigma: layout.feather / 2).cropped(to: cam.extent)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = cam
        blend.backgroundImage = CIImage(color: .clear).cropped(to: cam.extent)
        blend.maskImage = m
        return blend.outputImage ?? cam
    }

    /// Scales the low-res segmentation mask up to the camera frame, snapping its edge to real edges in the
    /// frame (hair, shoulders), then tightens the faint outer fringe so no halo of background shows.
    private static func refine(mask: CIImage, guide: CIImage) -> CIImage {
        let up = CIFilter.edgePreserveUpsample()
        up.inputImage = guide
        up.smallImage = mask
        up.spatialSigma = 3
        up.lumaSigma = 0.15
        let upsampled = up.outputImage?.cropped(to: guide.extent)
            ?? mask.transformed(by: CGAffineTransform(scaleX: guide.extent.width / mask.extent.width, y: guide.extent.height / mask.extent.height))
        // Choke: 0.25 and below becomes fully transparent, 0.85 and above fully opaque.
        let lo: CGFloat = 0.25, k = 1 / (0.85 - lo)
        let choke = CIFilter.colorMatrix()
        choke.inputImage = upsampled
        choke.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        choke.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        choke.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        choke.biasVector = CIVector(x: -lo * k, y: -lo * k, z: -lo * k, w: 0)
        return (choke.outputImage ?? upsampled).applyingFilter("CIColorClamp")
    }

    /// Builds the frame: the screen (cropped, then flat, or staged as a card over a blurred backdrop) with the cutout in its corner.
    /// With a canvas of a different shape, the screen is fitted inside it over a blurred copy of itself.
    /// `zoom` zooms the screen only; you stay the same size.
    public func compose(screen: CIImage, cutout: CIImage?, zoom: ZoomState = .none) -> CIImage {
        var screen = screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
        if layout.crop != nil {
            let r = layout.cropRect(in: screen.extent.size)
            screen = screen.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }
        screen = zoomed(screen, zoom)
        let frame = CGRect(origin: .zero, size: layout.canvas ?? screen.extent.size)
        let base: CIImage
        if let stage = layout.stage {
            base = self.stage(screen: screen, stage: stage, frame: frame)
        } else if frame.size == screen.extent.size {
            base = screen
        } else {
            base = letterbox(screen: screen, frame: frame)
        }
        guard let cutout else { return base }
        switch layout.presenter.style {
        case .cutout: return place(cutout: cutout, over: base)
        case .glass: return placeGlass(camera: cutout, over: base)
        }
    }

    /// The part of the screen in view, scaled up to fill the screen's own size.
    private func zoomed(_ screen: CIImage, _ zoom: ZoomState) -> CIImage {
        guard zoom.scale > 1.001 else { return screen }
        let W = screen.extent.width
        let H = screen.extent.height
        // Zoom y is top-down; CoreImage's is bottom-up.
        let t = CGAffineTransform(translationX: W / 2, y: H / 2)
            .scaledBy(x: zoom.scale, y: zoom.scale)
            .translatedBy(x: -zoom.x * W, y: -(1 - zoom.y) * H)
        return screen.clampedToExtent().transformed(by: t).cropped(to: screen.extent)
    }

    /// Brightness/contrast/saturation and warmth from `layout.look`.
    private func adjusted(_ image: CIImage) -> CIImage {
        let look = layout.look
        guard !look.isNeutral else { return image }
        var out = image
        if look.brightness != 0 || look.contrast != 1 || look.saturation != 1 {
            let cc = CIFilter.colorControls()
            cc.inputImage = out
            cc.brightness = Float(look.brightness * 0.25) // the filter's full range is far too strong for skin
            cc.contrast = Float(look.contrast)
            cc.saturation = Float(look.saturation)
            out = cc.outputImage ?? out
        }
        if look.warmth != 0 {
            let t = CIFilter.temperatureAndTint()
            t.inputImage = out
            t.neutral = CIVector(x: 6500, y: 0)
            t.targetNeutral = CIVector(x: 6500 - look.warmth * 2500, y: 0) // a lower target reads warmer
            out = t.outputImage ?? out
        }
        return out.cropped(to: image.extent)
    }

    /// What's behind the screen: the chosen background, or the screen itself zoomed, blurred and dimmed.
    private func backdrop(screen: CIImage, frame: CGRect, zoom: CGFloat, blur: CGFloat, dim: CGFloat) -> CIImage {
        switch layout.background {
        case .screen: return blurredScreen(screen: screen, frame: frame, zoom: zoom, blur: blur, dim: dim)
        case .preset, .image: return staticBackground(frame: frame)
        }
    }

    /// The preset wash or picture for this frame size, drawn once and kept.
    private func staticBackground(frame: CGRect) -> CIImage {
        backgroundLock.lock(); defer { backgroundLock.unlock() }
        if let cached = backgroundCache, cached.size == frame.size { return cached.image }
        let drawn = Self.drawBackground(layout.background, frame: frame)
        // Materialise so the per-frame cost is one texture, not a gradient stack.
        let image: CIImage
        if let cg = backgroundContext.createCGImage(drawn, from: frame, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            image = CIImage(cgImage: cg)
        } else {
            image = drawn
        }
        backgroundCache = (frame.size, image)
        return image
    }

    /// Draws a background to fill `frame`: a preset's colour blobs over its base, or a picture scaled to cover.
    /// Unknown presets and unreadable pictures fall back to graphite so the video still renders.
    static func drawBackground(_ background: Background, frame: CGRect) -> CIImage {
        let W = frame.width, H = frame.height
        switch background {
        case .screen:
            return CIImage(color: .black).cropped(to: frame)
        case .image(let path, let blur):
            guard let picture = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]),
                  picture.extent.width > 0, picture.extent.height > 0 else {
                return drawBackground(.preset("Graphite"), frame: frame)
            }
            let p = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
            let cover = max(W / p.extent.width, H / p.extent.height)
            var out = p.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
            out = out.transformed(by: CGAffineTransform(translationX: (W - out.extent.width) / 2, y: (H - out.extent.height) / 2))
            if blur > 0 {
                out = out.clampedToExtent().applyingGaussianBlur(sigma: blur * H)
            }
            return out.cropped(to: frame)
        case .preset(let name):
            let preset = BackgroundPreset.named(name) ?? BackgroundPreset.all.last!
            func color(_ c: BackgroundPreset.RGB, alpha: CGFloat = 1) -> CIColor {
                CIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: alpha)
            }
            var out = CIImage(color: color(preset.base)).cropped(to: frame)
            let long = max(W, H)
            for blob in preset.blobs {
                let g = CIFilter.radialGradient()
                g.center = CGPoint(x: CGFloat(blob.x) * W, y: CGFloat(blob.y) * H)
                g.radius0 = 0
                g.radius1 = Float(CGFloat(blob.radius) * long)
                g.color0 = color(blob.color, alpha: 0.95)
                g.color1 = color(blob.color, alpha: 0)
                if let image = g.outputImage {
                    out = image.cropped(to: frame).composited(over: out)
                }
            }
            return out
        }
    }

    /// The screen scaled to cover `frame`, zoomed, blurred and dimmed.
    private func blurredScreen(screen: CIImage, frame: CGRect, zoom: CGFloat, blur: CGFloat, dim: CGFloat) -> CIImage {
        let W = frame.width
        let H = frame.height
        let cover = max(W / screen.extent.width, H / screen.extent.height) * zoom
        var backdrop = screen.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
        backdrop = backdrop.transformed(by: CGAffineTransform(translationX: (W - backdrop.extent.width) / 2, y: (H - backdrop.extent.height) / 2))
            .cropped(to: frame)
        // Blur on a downscaled copy for speed, then scale back up.
        let down: CGFloat = 8
        let sigma = blur * H
        if sigma > 0 {
            backdrop = backdrop
                .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma / down)
                .cropped(to: CGRect(x: 0, y: 0, width: W / down, height: H / down))
                .transformed(by: CGAffineTransform(scaleX: down, y: down))
                .cropped(to: frame)
        }
        if dim > 0 {
            let k = 1 - dim
            let m = CIFilter.colorMatrix()
            m.inputImage = backdrop
            m.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
            backdrop = m.outputImage ?? backdrop
        }
        return backdrop
    }

    /// Flat screen fitted and centred in a differently shaped frame, over a blurred copy of itself.
    private func letterbox(screen: CIImage, frame: CGRect) -> CIImage {
        let d = Stage()
        let back = backdrop(screen: screen, frame: frame, zoom: CGFloat(d.backgroundZoom), blur: CGFloat(d.backgroundBlur), dim: CGFloat(d.backgroundDim))
        let fit = min(frame.width / screen.extent.width, frame.height / screen.extent.height)
        var fitted = screen.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
        fitted = fitted.transformed(by: CGAffineTransform(translationX: (frame.width - fitted.extent.width) / 2, y: (frame.height - fitted.extent.height) / 2))
        return fitted.composited(over: back).cropped(to: frame)
    }

    /// Zoomed, blurred, dimmed copy of the screen filling the frame, with a rounded, tilted, shadowed card of the screen on top.
    private func stage(screen: CIImage, stage: Stage, frame: CGRect) -> CIImage {
        let W = frame.width
        let H = frame.height
        let backdrop = self.backdrop(screen: screen, frame: frame, zoom: CGFloat(stage.backgroundZoom),
                                     blur: CGFloat(stage.backgroundBlur), dim: CGFloat(stage.backgroundDim))

        // Card geometry: the screen fitted in the frame, then inset.
        let fit = min(W / screen.extent.width, H / screen.extent.height)
        let cardH = CGFloat(stage.inset) * fit * screen.extent.height
        let cardW = CGFloat(stage.inset) * fit * screen.extent.width
        let cardRect = CGRect(x: 0, y: 0, width: cardW, height: cardH)
        let radius = CGFloat(stage.cornerRadius) * H
        let rr = CIFilter.roundedRectangleGenerator()
        rr.extent = cardRect
        rr.radius = Float(max(radius, 0))
        rr.color = .white
        let roundedMask = rr.outputImage?.cropped(to: cardRect)

        // Perspective: rotate about the vertical axis through the card centre and project.
        let cx = CGFloat(stage.cardX) * W
        let cy = CGFloat(stage.cardY) * H
        let theta = CGFloat(stage.tilt) * .pi / 180
        let focal = 2.5 * W
        func project(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            let z = dx * sin(theta)
            let p = focal / (focal + z)
            return CGPoint(x: cx + dx * cos(theta) * p, y: cy + dy * p)
        }
        let hw = cardW / 2
        let hh = cardH / 2
        func projected(_ image: CIImage) -> CIImage {
            let persp = CIFilter.perspectiveTransform()
            persp.inputImage = image
            persp.bottomLeft = project(-hw, -hh)
            persp.bottomRight = project(hw, -hh)
            persp.topLeft = project(-hw, hh)
            persp.topRight = project(hw, hh)
            return (persp.outputImage ?? image.transformed(by: CGAffineTransform(translationX: cx - hw, y: cy - hh))).cropped(to: frame)
        }

        // Card: scaled screen with rounded corners.
        let s = cardH / screen.extent.height
        var card = screen.transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: cardRect)
        if let roundedMask {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = card
            blend.backgroundImage = CIImage(color: .clear).cropped(to: cardRect)
            blend.maskImage = roundedMask
            card = (blend.outputImage ?? card).cropped(to: cardRect)
        }
        card = projected(card)

        var result = backdrop
        if stage.shadowOpacity > 0, let roundedMask {
            let ink = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(stage.shadowOpacity))).cropped(to: cardRect)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = ink
            blend.backgroundImage = CIImage(color: .clear).cropped(to: cardRect)
            blend.maskImage = roundedMask
            let shadowShape = projected((blend.outputImage ?? ink).cropped(to: cardRect))
            let shadow = shadowShape
                .applyingGaussianBlur(sigma: CGFloat(stage.shadowBlur) * H)
                .transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(stage.shadowOffset) * H))
                .cropped(to: frame)
            result = shadow.composited(over: result)
        }
        return card.composited(over: result).cropped(to: frame)
    }

    /// Scales and positions the cutout in the configured corner and composites it over the frame.
    private func place(cutout: CIImage, over screen: CIImage) -> CIImage {
        let targetHeight = layout.scale * screen.extent.height
        let s = targetHeight / cutout.extent.height
        var person = cutout.transformed(by: CGAffineTransform(scaleX: s, y: s))
        person = person.transformed(by: CGAffineTransform(translationX: -person.extent.minX, y: -person.extent.minY))

        let w = person.extent.width
        let h = person.extent.height
        let W = screen.extent.width
        let H = screen.extent.height
        let margin = layout.margin
        let x: CGFloat
        let y: CGFloat
        if let p = layout.position {
            x = min(max(p.x, 0), 1) * W - w / 2
            y = min(max(p.y, 0), 1) * max(H - h, 0)
        } else { switch layout.corner {
        case .bottomRight: x = W - w - margin; y = margin
        case .bottomLeft: x = margin; y = margin
        case .topRight: x = W - w - margin; y = H - h - margin
        case .topLeft: x = margin; y = H - h - margin
        } }
        person = person.transformed(by: CGAffineTransform(translationX: x, y: y))
        return person.composited(over: screen).cropped(to: screen.extent)
    }

    /// The camera picture as a floating pane: soft rounded corners, a faint hairline of light along the edge,
    /// and a wide, diffuse shadow, like a photo on an iPhone lock screen. Sized and positioned like the cutout.
    private func placeGlass(camera: CIImage, over base: CIImage) -> CIImage {
        let W = base.extent.width
        let H = base.extent.height
        let tileH = CGFloat(layout.scale) * H
        let tileW = (tileH * CGFloat(layout.presenter.tile.aspect)).rounded()
        let margin = layout.margin
        let x: CGFloat
        let y: CGFloat
        if let p = layout.position {
            x = min(max(p.x, 0), 1) * W - tileW / 2
            y = min(max(p.y, 0), 1) * max(H - tileH, 0)
        } else { switch layout.corner {
        case .bottomRight: x = W - tileW - margin; y = margin
        case .bottomLeft: x = margin; y = margin
        case .topRight: x = W - tileW - margin; y = H - tileH - margin
        case .topLeft: x = margin; y = H - tileH - margin
        } }
        let tile = CGRect(x: x.rounded(), y: y.rounded(), width: tileW, height: tileH)
        let radius = Presenter.cornerRadius * tileH

        func rounded(_ rect: CGRect, _ radius: CGFloat) -> CIImage {
            let rr = CIFilter.roundedRectangleGenerator()
            rr.extent = rect
            rr.radius = Float(max(radius, 0.5))
            rr.color = .white
            return (rr.outputImage ?? CIImage(color: .white)).cropped(to: rect)
        }
        func clipped(_ image: CIImage, to mask: CIImage, in rect: CGRect) -> CIImage {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = image.cropped(to: rect)
            blend.backgroundImage = CIImage(color: .clear).cropped(to: rect)
            blend.maskImage = mask
            return (blend.outputImage ?? image).cropped(to: rect)
        }
        let mask = rounded(tile, radius)
        var result = base

        // A wide, soft shadow, offset a little downwards.
        let shadowSigma = Presenter.shadowBlur * H
        let ink = clipped(CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: Presenter.shadowOpacity)), to: mask, in: tile)
        let shadow = ink.clampedToExtent().applyingGaussianBlur(sigma: shadowSigma)
            .transformed(by: CGAffineTransform(translationX: 0, y: -Presenter.shadowOffset * H))
            .cropped(to: base.extent)
        result = shadow.composited(over: result)

        // The picture, centre-cropped to the pane and clipped to its corners.
        let cam = camera.transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
        let cover = max(tile.width / cam.extent.width, tile.height / cam.extent.height)
        var picture = cam.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
        picture = picture.transformed(by: CGAffineTransform(translationX: tile.midX - picture.extent.width / 2,
                                                            y: tile.midY - picture.extent.height / 2))
        result = clipped(picture, to: mask, in: tile).composited(over: result)

        // A hairline of light along the edge, brighter at the top, softened so it reads as a highlight, not a border.
        let hair = max(1, (Presenter.edgeWidth * tileH).rounded())
        let insetMask = rounded(tile.insetBy(dx: hair, dy: hair), max(radius - hair, 0.5))
        let shine = CIFilter.linearGradient()
        shine.point0 = CGPoint(x: tile.midX, y: tile.maxY)
        shine.point1 = CGPoint(x: tile.midX, y: tile.minY)
        shine.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: Presenter.edgeOpacityTop)
        shine.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: Presenter.edgeOpacityBottom)
        let ring = clipped(shine.outputImage ?? CIImage(color: .white), to: mask, in: tile)
        let cut = CIFilter.blendWithMask()
        cut.inputImage = CIImage(color: .clear).cropped(to: tile)
        cut.backgroundImage = ring
        cut.maskImage = insetMask
        let edge = (cut.outputImage ?? ring).cropped(to: tile)
            .clampedToExtent().applyingGaussianBlur(sigma: hair * 0.6).cropped(to: tile)
        result = edge.composited(over: result)

        return result.cropped(to: base.extent)
    }
}
