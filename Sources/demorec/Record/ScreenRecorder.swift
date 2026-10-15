import AVFoundation
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit and writes it to a .mov.
/// Frames carry host-clock timestamps; the writer session starts at the shared T0.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let url: URL
    private let fps: Int
    private let startTime: CMTime
    private let queue = DispatchQueue(label: "demorec.screen")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var frameCount = 0
    private(set) var pixelSize = CGSize.zero

    init(url: URL, fps: Int, startTime: CMTime) {
        self.url = url
        self.fps = fps
        self.startTime = startTime
    }

    static func displays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays
    }

    func start(displayID: CGDirectDisplayID?) async throws {
        let displays = try await Self.displays()
        guard let display = displays.first(where: { displayID == nil || $0.displayID == displayID }) ?? displays.first else {
            throw DemoRecError("No display found")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = filter.pointPixelScale
        let width = Int(CGFloat(display.width) * CGFloat(scale))
        let height = Int(CGFloat(display.height) * CGFloat(scale))
        pixelSize = CGSize(width: width, height: height)

        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 8
        cfg.capturesAudio = false

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? DemoRecError("Screen writer failed to start") }
        writer.startSession(atSourceTime: startTime)
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let input else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= startTime else { return }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            frameCount += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("screen stream stopped: \(error.localizedDescription)\n", stderr)
    }

    func stop() async throws {
        try? await stream?.stopCapture()
        stream = nil
        guard let writer, let input else { return }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}

struct DemoRecError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
