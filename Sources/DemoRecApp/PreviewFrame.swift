import AppKit
import CoreImage
import CoreVideo
import IOSurface
import Metal
import SwiftUI

/// A rendered preview picture that stays on the GPU: an IOSurface-backed pixel buffer that `SurfaceView` hands
/// straight to Core Animation. Drawing previews as CGImages instead cost a CPU read-back per frame, then a
/// colour conversion on the main thread before each one could be shown.
final class PreviewFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    var width: Int { CVPixelBufferGetWidth(buffer) }
    var height: Int { CVPixelBufferGetHeight(buffer) }
    var surface: IOSurface? { CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() }

    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Renders CoreImage pictures into recycled IOSurfaces on the GPU. Use from one queue at a time.
final class FrameRenderer: @unchecked Sendable {
    let device: MTLDevice?
    let context: CIContext
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    init() {
        device = MTLCreateSystemDefaultDevice()
        context = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) } ?? CIContext()
    }

    /// A texture cache for reading camera or screen buffers as Metal textures without copying them.
    func makeTextureCache() -> CVMetalTextureCache? {
        guard let device else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        return cache
    }

    /// `image` drawn into a fresh surface, finished on the GPU before it's returned.
    func render(_ image: CIImage) -> PreviewFrame? {
        let w = Int(image.extent.width.rounded()), h = Int(image.extent.height.rounded())
        guard w > 0, h > 0, image.extent.width.isFinite else { return nil }
        let size = CGSize(width: w, height: h)
        if pool == nil || poolSize != size {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            // A few spares, so the one on screen is never drawn over.
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        let placed = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let destination = CIRenderDestination(pixelBuffer: pb)
        destination.colorSpace = srgb
        do {
            try context.startTask(toRender: placed, to: destination).waitUntilCompleted()
        } catch {
            return nil
        }
        // Tell Core Animation the pixels are sRGB so it matches them to the display on the GPU.
        if let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue(), let plist = srgb.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist)
        }
        return PreviewFrame(pb)
    }
}

/// Shows a `PreviewFrame` as a layer's contents: no CPU copy, no main-thread conversion. Lets clicks and drags
/// through to the SwiftUI views around it.
struct SurfaceView: NSViewRepresentable {
    let frame: PreviewFrame
    /// Fill the view and crop, instead of stretching to it.
    var fill = false

    final class LayerView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = CALayer()
            wantsLayer = true
            layer?.masksToBounds = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> LayerView { LayerView(frame: .zero) }

    func updateNSView(_ view: LayerView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contentsGravity = fill ? .resizeAspectFill : .resize
        view.layer?.contents = frame.surface
        CATransaction.commit()
    }
}
