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
    private let cursor: CursorTrack?
    private let zoom: ZoomSettings

    /// `cursor` (from cursor.json) drives the zoom; without one the screen is never zoomed.
    public init(layout: Layout, fps: Int, outputHeight: Int?, quality: MaskQuality, maskEnabled: Bool = true,
                cursor: CursorTrack? = nil, zoom: ZoomSettings = ZoomSettings()) {
        self.layout = layout
        // Zoom works in the cropped screen's coordinates.
        self.cursor = layout.crop.flatMap { cursor?.cropped(to: $0) } ?? cursor
        self.zoom = zoom
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

        let recordedSize = try await screenTrack.load(.naturalSize)
        // What the compositor treats as the screen: the crop, if there is one.
        let screenSize = layout.cropRect(in: recordedSize).size
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
        // Cutouts are made on their own thread, ahead of the render loop, at the size they appear in the video.
        let frameHeight = layout.canvas?.height ?? screenSize.height
        let cutoutHeight = layout.scale * frameHeight
        let cutouts = CutoutStage(output: cameraOut) { [masker, compositor, ciContext, maskEnabled] buffer in
            var camera = CIImage(cvPixelBuffer: buffer)
            let s = cutoutHeight / camera.extent.height
            if s < 1 { camera = camera.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
            let mask = maskEnabled ? try masker.mask(for: buffer) : nil
            return try Self.materialize(compositor.cutout(camera: camera, mask: mask), context: ciContext)
        }
        defer { cutouts.cancel() }
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
        let zoomPath = cursor.map { ZoomPlanner.path(track: $0, settings: zoom, start: start.seconds, fps: fps, frames: totalFrames) }
        if let cursor, let zoomPath {
            let moments = ZoomPlanner.segments(for: cursor, settings: zoom).count
            let zoomedFrames = zoomPath.filter { $0.scale > 1.01 }.count
            print(String(format: "zoom: %d moments, zoomed in for %.1f s", moments, Double(zoomedFrames) / Double(fps)))
        }
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: recordedSize))
        let started = Date()
        var frameIndex = 0

        func nextFrame() throws -> (CVPixelBuffer, CMTime)? {
            guard frameIndex < totalFrames else { return nil }
            let i = frameIndex
            frameIndex += 1
            let t = CMTimeMultiply(frameDuration, multiplier: Int32(i))
            _ = screenSrc.advance(to: start + t)
            let cutout = try cutouts.advance(to: start + t)

            let screen = screenSrc.current.map { CIImage(cvPixelBuffer: $0) } ?? black
            var frame = compositor.compose(screen: screen, cutout: cutout, zoom: zoomPath?[i] ?? .none)
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
                    // Drain after every frame. This loop can run for the whole video without returning, and without
                    // a pool each decoded screen frame (~20 MB at ultrawide/4K sizes) stays alive in the system's
                    // video decoder until the end: tens of GB for a few minutes, enough to freeze the Mac.
                    guard let (buf, t) = try autoreleasepool(invoking: { try nextFrame() }) else {
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

    /// Renders an image into its own buffer so later frames reuse the pixels instead of redoing the work.
    private static func materialize(_ image: CIImage, context: CIContext) throws -> CIImage {
        let image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(image.extent.width.rounded(.up)), Int(image.extent.height.rounded(.up)), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw DemoRecError("could not allocate cutout buffer") }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(image, to: buffer, bounds: image.extent, colorSpace: srgb)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: srgb])
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

/// Turns camera frames into finished cutouts on a background thread, a few frames ahead of the render loop,
/// so segmentation runs alongside rendering instead of between frames.
private final class CutoutStage: @unchecked Sendable {
    private let output: AVAssetReaderTrackOutput
    private let make: (CVPixelBuffer) throws -> CIImage
    private let condition = NSCondition()
    private var ready: [(time: CMTime, image: CIImage)] = []
    private var current: CIImage?
    private var finished = false
    private var cancelled = false
    private var failure: Error?
    private let lookahead = 6

    init(output: AVAssetReaderTrackOutput, make: @escaping (CVPixelBuffer) throws -> CIImage) {
        self.output = output
        self.make = make
        let thread = Thread { [self] in run() }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func run() {
        while true {
            condition.lock()
            while ready.count >= lookahead, !cancelled { condition.wait() }
            let stop = cancelled
            condition.unlock()
            guard !stop, let sample = output.copyNextSampleBuffer() else { break }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            do {
                let image = try autoreleasepool { try make(buffer) }
                condition.lock()
                ready.append((time, image))
                condition.broadcast()
                condition.unlock()
            } catch {
                condition.lock()
                failure = error
                condition.unlock()
                break
            }
        }
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// The latest cutout whose camera frame is at or before `time`, waiting for the thread if it hasn't got there yet.
    func advance(to time: CMTime) throws -> CIImage? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let failure { throw failure }
            while let next = ready.first, next.time <= time {
                current = next.image
                ready.removeFirst()
                condition.broadcast()
            }
            if !ready.isEmpty || finished { return current }
            condition.wait()
        }
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
