import CoreImage
import Vision

/// Produces a per-frame person mask (white = person) using Apple's on-device segmentation model.
public final class PersonMasker {
    private let request = VNGeneratePersonSegmentationRequest()
    /// One handler for the whole stream, so Vision can carry state from frame to frame instead of starting over.
    private let handler = VNSequenceRequestHandler()

    public init(quality: MaskQuality) {
        switch quality {
        case .fast: request.qualityLevel = .fast
        case .balanced: request.qualityLevel = .balanced
        case .accurate: request.qualityLevel = .accurate
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Returns a mask image in the mask's native (smaller) resolution, or nil if no person is detected.
    public func mask(for pixelBuffer: CVPixelBuffer) throws -> CIImage? {
        try handler.perform([request], on: pixelBuffer)
        guard let result = request.results?.first else { return nil }
        return CIImage(cvPixelBuffer: result.pixelBuffer)
    }
}
