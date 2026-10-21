import CoreImage
import CoreVideo
import DemoRecKit
import Metal
import ScreenCaptureKit

/// Low-res, low-fps live view of whatever will be recorded, for the setup screen.
/// Display previews leave out DemoRec's own window so the preview doesn't show itself.
/// Zooms live like the video will: feed `liveZoom` the pointer and it redraws smoothly while zoomed.
/// Draws the trail in `liveInk` the same way, redrawing while any of it is still fading.
final class ScreenPreview: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Delivered on the main queue.
    var onImage: ((PreviewFrame) -> Void)?

    private let queue = DispatchQueue(label: "demorec.screenpreview")
    private let renderer = FrameRenderer()
    private lazy var textureCache = renderer.makeTextureCache()
    private var lastTexture: CVMetalTexture? // queue only; keeps lastFrame's buffer alive
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private var stream: SCStream?
    private var generation = 0
    private var stage: Stage? // queue only
    private var background: Background = .screen // queue only
    private var compositor: Compositor? // queue only; reused so a static background is drawn once
    private var compositorLayout: Layout? // queue only; what `compositor` was made for
    private var canvas: CGSize? // queue only
    private var crop: CGRect? // queue only
    private var lastFrame: CIImage? // queue only
    private var zoomEnabled = true // queue only
    private var zoom = ZoomState.none // queue only
    private var lastZoomStep: Double? // queue only
    private var inkShown = false // queue only; the last render had a trail, so it needs one more to clear it
    private var zoomTimer: DispatchSourceTimer?
    /// In the coordinates of the cropped screen, on the host clock in seconds (see `now`).
    let liveZoom = LiveZoom()
    /// Also in the cropped screen's coordinates on the host clock. Pass one in to share it (see LivePreview).
    let liveInk: LiveInk

    init(liveInk: LiveInk = LiveInk()) {
        self.liveInk = liveInk
        super.init()
    }

    /// Seconds on the host clock: what CursorRecorder reports when started at time zero.
    static func now() -> Double { SharedClock.now().seconds }

    /// Styles and frames the preview like the final video. Re-renders the last frame, since a still screen sends no new ones.
    /// `zoom` false shows the screen unzoomed whatever the pointer does (e.g. while editing the crop).
    /// A burst of changes (dragging a slider) draws only the latest: one redraw waits at a time, and it takes whatever
    /// layout is newest when it runs.
    func setLayout(stage: Stage?, background: Background, canvas: CGSize?, crop: CGRect?, zoom: Bool) {
        let waiting = pendingLock.withLock {
            defer { pendingLayout = PendingLayout(stage: stage, background: background, canvas: canvas, crop: crop, zoom: zoom) }
            return pendingLayout != nil
        }
        guard !waiting else { return }
        queue.async {
            guard let next = self.pendingLock.withLock({ () -> PendingLayout? in
                defer { self.pendingLayout = nil }
                return self.pendingLayout
            }) else { return }
            self.stage = next.stage
            self.background = next.background
            self.canvas = next.canvas
            self.crop = next.crop
            self.zoomEnabled = next.zoom
            if !next.zoom { self.zoom = .none }
            if let frame = self.lastFrame { self.render(frame) }
        }
    }

    private struct PendingLayout {
        var stage: Stage?
        var background: Background
        var canvas: CGSize?
        var crop: CGRect?
        var zoom: Bool
    }
    private let pendingLock = NSLock()
    private var pendingLayout: PendingLayout? // pendingLock

    @MainActor
    func start(target: CaptureTarget?) async throws {
        await stop()
        generation += 1
        let gen = generation
        let filter = try await ScreenRecorder.filter(for: target, excludingCurrentApp: true)
        guard gen == generation else { return } // a newer start() superseded this one

        let rect = filter.contentRect
        let longSide: CGFloat = 1600
        let s = min(1, longSide / max(rect.width, rect.height)) * CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.width = max(2, Int(rect.width * s) & ~1)
        cfg.height = max(2, Int(rect.height * s) & ~1)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 5 // one is held as lastFrame; the rest keep the stream flowing

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        if gen == generation {
            self.stream = stream
            startZoomTimer()
        } else {
            try? await stream.stopCapture()
        }
    }

    @MainActor
    func stop() async {
        generation += 1
        zoomTimer?.cancel()
        zoomTimer = nil
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Read in place as a Metal texture: the frame stays on the GPU instead of being converted on the CPU first.
        // Holding this one buffer as the last frame is fine; queueDepth leaves the stream spares (see start).
        let frame: CIImage
        var cvTexture: CVMetalTexture?
        if let cache = textureCache,
           CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                     CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTexture) == kCVReturnSuccess,
           let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture),
           let image = CIImage(mtlTexture: texture, options: [.colorSpace: srgb]) {
            frame = image.oriented(.downMirrored) // Metal's rows run top-down, CoreImage's bottom-up
        } else {
            frame = CIImage(cvPixelBuffer: pb)
        }
        lastTexture = cvTexture
        lastFrame = frame
        if zoom == .none, !inkShown { render(frame) } // while zoomed or drawing, the timer redraws anyway
    }

    /// Steps the zoom 30 times a second and redraws while it's zoomed or moving, or a trail is showing.
    private func startZoomTimer() {
        zoomTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.stepZoom() }
        timer.resume()
        zoomTimer = timer
    }

    private func stepZoom() {
        let now = Self.now()
        defer { lastZoomStep = now }
        let zooming = zoomEnabled && (liveZoom.isActive || zoom != .none)
        guard zooming || inkShown || liveInk.isVisible(at: now) else { return }
        if zooming {
            let dt = min(max(now - (lastZoomStep ?? now), 0.001), 0.1)
            var z = liveZoom.step(now: now, dt: dt)
            if z.scale < 1.001 { z = .none }
            zoom = z
        }
        if let frame = lastFrame { render(frame) }
    }

    private func render(_ frame: CIImage) {
        var out = frame
        var cropped = Layout()
        cropped.crop = crop
        let screenSize = cropped.cropRect(in: frame.extent.size).size
        let ink = liveInk.image(at: Self.now(), size: screenSize)
        inkShown = ink != nil
        if stage != nil || canvas != nil || crop != nil || zoom != .none || ink != nil {
            var layout = Layout()
            layout.stage = stage
            layout.background = background
            layout.crop = crop
            // Same shape as the output, at preview resolution.
            if let canvas {
                let s = min(1, 1600 / max(canvas.width, canvas.height))
                layout.canvas = CGSize(width: (canvas.width * s).rounded(), height: (canvas.height * s).rounded())
            }
            // Compared by value: a new compositor redraws the background, which must happen only when it changes.
            if compositor == nil || layout != compositorLayout {
                compositor = Compositor(layout: layout, reusing: compositor)
                compositorLayout = layout
            }
            out = compositor!.compose(screen: frame, cutout: nil, zoom: zoom, ink: ink)
        }
        guard let rendered = renderer.render(out) else { return }
        DispatchQueue.main.async { self.onImage?(rendered) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The previewed window was closed, or permission was revoked; the model notices on its next refresh.
    }
}
