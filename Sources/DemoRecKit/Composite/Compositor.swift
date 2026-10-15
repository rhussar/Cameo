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
        guard let mask else { return cam }
        let sx = cam.extent.width / mask.extent.width
        let sy = cam.extent.height / mask.extent.height
        var m = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        if layout.mirror {
            m = m.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).transformed(by: CGAffineTransform(translationX: cam.extent.width, y: 0))
        }
        if layout.feather > 0 {
            m = m.clampedToExtent().applyingGaussianBlur(sigma: layout.feather).cropped(to: cam.extent)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = cam
        blend.backgroundImage = CIImage(color: .clear).cropped(to: cam.extent)
        blend.maskImage = m
        return blend.outputImage ?? cam
    }

    /// Builds the frame: the screen (flat, or staged as a card over a blurred backdrop) with the cutout in its corner.
    public func compose(screen: CIImage, cutout: CIImage?) -> CIImage {
        let base = layout.stage.map { stage(screen: screen, stage: $0) } ?? screen
        guard let cutout else { return base }
        return place(cutout: cutout, over: base)
    }

    /// Zoomed, blurred, dimmed copy of the screen filling the frame, with a rounded, tilted, shadowed card of the screen on top.
    private func stage(screen: CIImage, stage: Stage) -> CIImage {
        let frame = screen.extent
        let W = frame.width
        let H = frame.height

        // Backdrop: blur on a downscaled copy for speed, then scale back up.
        let zoom = CGFloat(stage.backgroundZoom)
        var backdrop = screen.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2))
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
            .transformed(by: CGAffineTransform(translationX: W / 2, y: H / 2))
            .cropped(to: frame)
        let down: CGFloat = 8
        let sigma = CGFloat(stage.backgroundBlur) * H
        if sigma > 0 {
            backdrop = backdrop
                .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma / down)
                .cropped(to: CGRect(x: 0, y: 0, width: W / down, height: H / down))
                .transformed(by: CGAffineTransform(scaleX: down, y: down))
                .cropped(to: frame)
        }
        if stage.backgroundDim > 0 {
            let k = CGFloat(1 - stage.backgroundDim)
            let dim = CIFilter.colorMatrix()
            dim.inputImage = backdrop
            dim.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
            dim.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
            dim.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
            backdrop = dim.outputImage ?? backdrop
        }

        // Card geometry.
        let cardH = CGFloat(stage.inset) * H
        let cardW = cardH * W / H
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
        let s = cardH / H
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
        switch layout.corner {
        case .bottomRight: x = W - w - margin; y = margin
        case .bottomLeft: x = margin; y = margin
        case .topRight: x = W - w - margin; y = H - h - margin
        case .topLeft: x = margin; y = H - h - margin
        }
        person = person.transformed(by: CGAffineTransform(translationX: x, y: y))
        return person.composited(over: screen).cropped(to: screen.extent)
    }
}
