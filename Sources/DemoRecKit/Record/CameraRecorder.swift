import AVFoundation

/// Captures a webcam plus a microphone (the system default unless one is chosen) and writes them to a .mov.
/// Writer inputs are created from the first buffers so any camera/mic format works.
public final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let url: URL
    private let fps: Int
    private let startTime: CMTime
    private let queue = DispatchQueue(label: "demorec.camera")

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var writing = false
    public private(set) var frameCount = 0

    public init(url: URL, fps: Int, startTime: CMTime) {
        self.url = url
        self.fps = fps
        self.startTime = startTime
    }

    public static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    public static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices
    }

    public static func pickCamera(matching name: String?) throws -> AVCaptureDevice {
        let all = cameras()
        if let name, let match = all.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) {
            return match
        }
        if let name { fputs("camera \"\(name)\" not found, falling back\n", stderr) }
        guard let fallback = all.first(where: { $0.localizedName.contains("FaceTime") }) ?? all.first else {
            throw DemoRecError("No camera found")
        }
        return fallback
    }

    public static func requestAccess() async throws {
        for media in [AVMediaType.video, .audio] {
            let ok = await AVCaptureDevice.requestAccess(for: media)
            guard ok else { throw DemoRecError("\(media == .video ? "Camera" : "Microphone") access denied. Allow it in System Settings > Privacy & Security, then try again.") }
        }
    }

    /// `cameraID` / `microphoneID` pick devices by unique ID; when absent or unplugged, the camera falls back
    /// to `cameraName` matching and the microphone to the system default.
    public func start(cameraName: String?, cameraID: String? = nil, microphoneID: String? = nil) throws {
        let camera = try cameraID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? Self.pickCamera(matching: cameraName)
        print("camera: \(camera.localizedName)")

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        let camInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(camInput) else { throw DemoRecError("Cannot add camera input") }
        session.addInput(camInput)

        if let mic = microphoneID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .audio) {
            print("microphone: \(mic.localizedName)")
            let micInput = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(micInput) { session.addInput(micInput) }
        } else {
            fputs("no microphone found; recording video only\n", stderr)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { throw DemoRecError("Cannot add video output") }
        session.addOutput(videoOutput)

        audioOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        session.commitConfiguration()

        // Ask the camera for the requested frame rate when its active format allows it.
        if let range = camera.activeFormat.videoSupportedFrameRateRanges.first(where: { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }) {
            _ = range
            if (try? camera.lockForConfiguration()) != nil {
                camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                camera.unlockForConfiguration()
            }
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        self.writer = writer
        session.startRunning()
    }

    private var hasMic: Bool { session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true } }

    private func ensureInputs(video: CMSampleBuffer?, audio: CMSampleBuffer?) {
        guard let writer, !writing else { return }
        if videoInput == nil, let video, let fmt = CMSampleBufferGetFormatDescription(video) {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dims.width),
                AVVideoHeightKey: Int(dims.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoExpectedSourceFrameRateKey: fps,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            videoInput = input
        }
        if audioInput == nil, let audio, let fmt = CMSampleBufferGetFormatDescription(audio),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                AVEncoderBitRateKey: 160_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        }
        let ready = videoInput != nil && (audioInput != nil || !hasMic)
        if ready {
            guard writer.startWriting() else {
                fputs("camera writer failed: \(writer.error?.localizedDescription ?? "?")\n", stderr)
                return
            }
            writer.startSession(atSourceTime: startTime)
            writing = true
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput
        ensureInputs(video: isVideo ? sampleBuffer : nil, audio: isVideo ? nil : sampleBuffer)
        guard writing, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= startTime else { return }
        if isVideo {
            if let videoInput, videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) { frameCount += 1 }
        } else if let audioInput, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    public func stop() async throws {
        session.stopRunning()
        // Drain anything still queued on the delegate queue.
        await withCheckedContinuation { cont in queue.async { cont.resume() } }
        guard let writer, writing else { return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
