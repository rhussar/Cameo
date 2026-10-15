import CoreImage
import DemoRecKit
import Metal
import ScreenCaptureKit

/// Low-res, low-fps live view of whatever will be recorded, for the setup screen.
/// Display previews leave out DemoRec's own window so the preview doesn't show itself.
final class ScreenPreview: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Delivered on the main queue.
    var onImage: ((CGImage) -> Void)?

    private let queue = DispatchQueue(label: "demorec.screenpreview")
    private let ciContext: CIContext = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0) } ?? CIContext()
    private var stream: SCStream?
    private var generation = 0

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
        cfg.showsCursor = true
        cfg.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        if gen == generation {
            self.stream = stream
        } else {
            try? await stream.stopCapture()
        }
    }

    @MainActor
    func stop() async {
        generation += 1
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
        let image = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        DispatchQueue.main.async { self.onImage?(cg) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The previewed window was closed, or permission was revoked; the model notices on its next refresh.
    }
}
