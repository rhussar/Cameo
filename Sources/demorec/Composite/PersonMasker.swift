import CoreImage
import Vision

/// Produces a per-frame person mask (white = person) using Apple's on-device segmentation model.
final class PersonMasker {
    private let request = VNGeneratePersonSegmentationRequest()

    init(quality: MaskQuality) {
        switch quality {
        case .fast: request.qualityLevel = .fast
        case .balanced: request.qualityLevel = .balanced
        case .accurate: request.qualityLevel = .accurate
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Returns a mask image in the mask's native (smaller) resolution, or nil if no person is detected.
    func mask(for pixelBuffer: CVPixelBuffer) throws -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first else { return nil }
        return CIImage(cvPixelBuffer: result.pixelBuffer)
    }
}
