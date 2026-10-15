import CoreImage
import CoreImage.CIFilterBuiltins

/// Cuts the presenter out of the camera frame and places the cutout over the screen frame.
/// Pure CoreImage; takes CIImages and returns a CIImage so it works for files now and live frames later.
final class Compositor {
    private let layout: Layout

    init(layout: Layout) {
        self.layout = layout
    }

    func cutout(camera: CIImage, mask: CIImage?) -> CIImage {
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

    /// Scales and positions the cutout in the configured corner and composites it over the screen frame.
    func compose(screen: CIImage, cutout: CIImage) -> CIImage {
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
