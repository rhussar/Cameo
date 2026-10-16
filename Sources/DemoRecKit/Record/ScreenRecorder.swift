import AVFoundation
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit and writes it to a .mov.
/// Frames carry host-clock timestamps; the writer session starts at the shared T0.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let url: URL
    private let fps: Int
    private let startTime: CMTime
    private let queue = DispatchQueue(label: "demorec.screen")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    public private(set) var frameCount = 0
    public private(set) var pixelSize = CGSize.zero

    public init(url: URL, fps: Int, startTime: CMTime) {
        self.url = url
        self.fps = fps
        self.startTime = startTime
    }

    public static func displays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays
    }

    /// Builds the capture filter for a target. Nil means the main display.
    /// `excludingCurrentApp` keeps the calling app's own windows (e.g. the recording controls) out of a display capture.
    public static func filter(for target: CaptureTarget?, excludingCurrentApp: Bool) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if case .window(let id) = target {
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw DemoRecError("That window is no longer open. Pick another one.")
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
        var displayID: CGDirectDisplayID?
        if case .display(let id) = target { displayID = id }
        let displays = content.displays
        guard let display = displays.first(where: { $0.displayID == (displayID ?? CGMainDisplayID()) }) ?? displays.first else {
            throw DemoRecError("No display found")
        }
        if excludingCurrentApp {
            // The on-screen-only list misses this app until its window is up (e.g. right at launch),
            // so look it up in the full list; excluding the app also covers windows it opens later.
            let all = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let me = all.applications.first(where: { $0.processID == getpid() }) {
                return SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
            }
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    public func start(displayID: CGDirectDisplayID?, excludingCurrentApp: Bool = false) async throws {
        try await start(target: displayID.map { .display($0) }, excludingCurrentApp: excludingCurrentApp)
    }

    public func start(target: CaptureTarget?, excludingCurrentApp: Bool = false) async throws {
        let filter = try await Self.filter(for: target, excludingCurrentApp: excludingCurrentApp)
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int(filter.contentRect.width * scale) & ~1
        let height = Int(filter.contentRect.height * scale) & ~1
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
        // Write the index every couple of seconds, so if the Mac crashes or loses power mid-recording,
        // everything up to the last few seconds can still be opened.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
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

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("screen stream stopped: \(error.localizedDescription)\n", stderr)
    }

    public func stop() async throws {
        try? await stream?.stopCapture()
        stream = nil
        guard let writer, let input else { return }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}

/// What to record: a whole display or a single window.
public enum CaptureTarget: Hashable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

public struct DemoRecError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
