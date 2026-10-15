import CoreImage
import CoreImage.CIFilterBuiltins

/// Cuts the presenter out of the camera frame and places the cutout over the screen frame.
/// Pure CoreImage; takes CIImages and returns a CIImage so it works for files now and live frames later.
public final class Compositor {
    private let layout: Layout

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

    /// Builds the frame: the screen (flat, or staged as a card over a blurred backdrop) with the cutout in its corner.
    /// With a canvas of a different shape, the screen is fitted inside it over a blurred copy of itself.
    public func compose(screen: CIImage, cutout: CIImage?) -> CIImage {
        let screen = screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
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
        return place(cutout: cutout, over: base)
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

    /// The screen scaled to cover `frame`, zoomed, blurred and dimmed.
    private func backdrop(screen: CIImage, frame: CGRect, zoom: CGFloat, blur: CGFloat, dim: CGFloat) -> CIImage {
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
}
