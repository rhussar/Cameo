import AVFoundation
import CoreImage
import Metal

/// Reads screen.mov and camera.mov, renders the composite on a fixed output clock, and writes final.mp4
/// with the camera file's audio passed through untouched.
public final class Transcoder {
    /// Called from a background queue with the fraction of frames rendered (0...1).
    public var onProgress: ((Double) -> Void)?
    private let layout: Layout
    private let fps: Int
    private let outputHeight: Int?
    private let masker: PersonMasker
    private let maskEnabled: Bool
    private let compositor: Compositor
    private let ciContext: CIContext

    public init(layout: Layout, fps: Int, outputHeight: Int?, quality: MaskQuality, maskEnabled: Bool = true) {
        self.layout = layout
        self.maskEnabled = maskEnabled
        self.fps = fps
        self.outputHeight = outputHeight
        self.masker = PersonMasker(quality: quality)
        self.compositor = Compositor(layout: layout)
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
    }

    private final class FrameSource {
        let output: AVAssetReaderTrackOutput
        var current: CVPixelBuffer?
        var currentTime: CMTime = .negativeInfinity
        var pending: CMSampleBuffer?
        var exhausted = false

        init(output: AVAssetReaderTrackOutput) { self.output = output }

        /// Advances so `current` is the latest frame with pts <= t. Returns true if the frame changed.
        func advance(to t: CMTime) -> Bool {
            var changed = false
            while true {
                if pending == nil, !exhausted {
                    pending = output.copyNextSampleBuffer()
                    if pending == nil { exhausted = true }
                }
                guard let sb = pending else { return changed }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                if pts <= t {
                    if let pb = CMSampleBufferGetImageBuffer(sb) {
                        current = pb
                        currentTime = pts
                        changed = true
                    }
                    pending = nil
                } else {
                    return changed
                }
            }
        }
    }

    public func run(screenURL: URL, cameraURL: URL, outputURL: URL) async throws {
        let screenAsset = AVURLAsset(url: screenURL)
        let cameraAsset = AVURLAsset(url: cameraURL)
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else { throw DemoRecError("screen.mov has no video track") }
        guard let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first else { throw DemoRecError("camera.mov has no video track") }
        let audioTrack = try await cameraAsset.loadTracks(withMediaType: .audio).first

        let screenSize = try await screenTrack.load(.naturalSize)
        let screenDuration = try await screenAsset.load(.duration)
        let cameraDuration = try await cameraAsset.load(.duration)
        let duration = CMTimeMaximum(screenDuration, cameraDuration)

        var outW = Int(screenSize.width)
        var outH = Int(screenSize.height)
        if let canvas = layout.canvas {
            // The compositor already renders at the canvas size.
            outW = Int(canvas.width) & ~1
            outH = Int(canvas.height) & ~1
        } else if let outputHeight, outputHeight < outH {
            outW = Int((Double(outW) * Double(outputHeight) / Double(outH)).rounded()) & ~1
            outH = outputHeight & ~1
        }
        let outputScale = layout.canvas == nil ? CGFloat(outH) / screenSize.height : 1
        let useHEVC = outW > 4096 || outH > 4096
        print("output: \(outW)x\(outH) @ \(fps) fps, \(useHEVC ? "HEVC" : "H.264")")

        // Readers
        let pixelFormat = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let screenReader = try AVAssetReader(asset: screenAsset)
        let screenOut = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: pixelFormat)
        screenOut.alwaysCopiesSampleData = false
        screenReader.add(screenOut)
        let cameraReader = try AVAssetReader(asset: cameraAsset)
        let cameraOut = AVAssetReaderTrackOutput(track: cameraTrack, outputSettings: pixelFormat)
        cameraOut.alwaysCopiesSampleData = false
        cameraReader.add(cameraOut)
        // Audio gets its own reader: a reader with two outputs blocks when one of them is not drained in step.
        var audioReader: AVAssetReader?
        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack {
            let reader = try AVAssetReader(asset: cameraAsset)
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(out)
            audioReader = reader
            audioOut = out
        }
        guard screenReader.startReading() else { throw screenReader.error ?? DemoRecError("screen reader failed") }
        guard cameraReader.startReading() else { throw cameraReader.error ?? DemoRecError("camera reader failed") }
        if let audioReader, !audioReader.startReading() { throw audioReader.error ?? DemoRecError("audio reader failed") }

        // Writer
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, outW * outH * 6),
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let fmts = try await audioTrack.load(.formatDescriptions)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmts.first)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? DemoRecError("writer failed to start") }
        writer.startSession(atSourceTime: .zero)

        // Frame generation on a fixed output clock.
        let screenSrc = FrameSource(output: screenOut)
        let cameraSrc = FrameSource(output: cameraOut)
        // Both recorders share a start clock but deliver their first frames a moment later.
        // Start the video once both have a frame, so it doesn't open on black.
        let start = CMTimeMaximum(try await Self.firstFrameTime(screenTrack), try await Self.firstFrameTime(cameraTrack))
        // Passthrough audio comes out in media time; its track's edit places it on the shared clock.
        var audioOffset = start
        if let audioTrack, let edit = try await audioTrack.load(.segments).first(where: { !$0.isEmpty }) {
            audioOffset = start - (edit.timeMapping.target.start - edit.timeMapping.source.start)
        }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let totalFrames = max(1, Int(((duration - start).seconds * Double(fps)).rounded(.up)))
        print(String(format: "length: %.1f s (skipping the first %.2f s before both recordings have a frame)", (duration - start).seconds, start.seconds))
        var cutout: CIImage?
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height))
        let started = Date()
        var frameIndex = 0

        func nextFrame() throws -> (CVPixelBuffer, CMTime)? {
            guard frameIndex < totalFrames else { return nil }
            let i = frameIndex
            frameIndex += 1
            let t = CMTimeMultiply(frameDuration, multiplier: Int32(i))
            _ = screenSrc.advance(to: start + t)
            let cameraChanged = cameraSrc.advance(to: start + t)

            if cameraChanged, let camBuf = cameraSrc.current {
                let mask = maskEnabled ? try masker.mask(for: camBuf) : nil
                cutout = compositor.cutout(camera: CIImage(cvPixelBuffer: camBuf), mask: mask)
            }

            let screen = screenSrc.current.map { CIImage(cvPixelBuffer: $0) } ?? black
            var frame = compositor.compose(screen: screen, cutout: cutout)
            if outputScale != 1 {
                frame = frame.transformed(by: CGAffineTransform(scaleX: outputScale, y: outputScale))
            }

            guard let pool = adaptor.pixelBufferPool else { throw DemoRecError("no pixel buffer pool") }
            var outBuf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
            guard let outBuf else { throw DemoRecError("could not allocate output buffer") }
            ciContext.render(frame, to: outBuf, bounds: CGRect(x: 0, y: 0, width: outW, height: outH), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

            if i % fps == 0 || i == totalFrames - 1 { onProgress?(Double(i + 1) / Double(totalFrames)) }
            if i % (fps * 5) == 0 || i == totalFrames - 1 {
                let elapsed = Date().timeIntervalSince(started)
                let pct = Double(i + 1) / Double(totalFrames) * 100
                print(String(format: "\r  %5.1f%%  frame %d/%d  (%.0fs elapsed)", pct, i + 1, totalFrames, elapsed), terminator: "")
                fflush(stdout)
            }
            return (outBuf, t)
        }

        // The writer interleaves its inputs and toggles each input's readiness as the other catches up,
        // so every input pumps itself from requestMediaDataWhenReady on its own queue.
        let videoQueue = DispatchQueue(label: "demorec.write.video")
        let audioQueue = DispatchQueue(label: "demorec.write.audio")
        let group = DispatchGroup()
        let errorLock = NSLock()
        var failure: Error?
        func fail(_ error: Error) {
            errorLock.lock(); if failure == nil { failure = error }; errorLock.unlock()
        }

        group.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                do {
                    guard let (buf, t) = try nextFrame() else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard adaptor.append(buf, withPresentationTime: t) else {
                        throw writer.error ?? DemoRecError("failed to append frame at \(t.seconds)s")
                    }
                } catch {
                    fail(error)
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        var audioPackets = 0
        if let audioOut, let audioInput {
            group.enter()
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sb = audioOut.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard CMSampleBufferGetNumSamples(sb) > 0, let shifted = Self.shifted(sb, by: audioOffset) else { continue }
                    guard audioInput.append(shifted) else {
                        fail(writer.error ?? DemoRecError("failed to append audio"))
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioPackets += 1
                }
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: DispatchQueue(label: "demorec.write.done")) { cont.resume() }
        }
        print()
        if audioInput != nil { print("audio: \(audioPackets) packets copied") }
        if let failure { throw failure }

        await writer.finishWriting()
        if let error = writer.error { throw error }
        screenReader.cancelReading()
        cameraReader.cancelReading()
        audioReader?.cancelReading()
    }

    /// When a recording's first real frame lands: the end of the empty edit the recorder leaves before it.
    private static func firstFrameTime(_ track: AVAssetTrack) async throws -> CMTime {
        let segments = try await track.load(.segments)
        return segments.first { !$0.isEmpty }?.timeMapping.target.start ?? .zero
    }

    /// Moves an audio buffer `offset` earlier. Nil if it then ends before time zero.
    private static func shifted(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferGetPresentationTimeStamp(sb) + CMSampleBufferGetDuration(sb) - offset > .zero else { return nil }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
