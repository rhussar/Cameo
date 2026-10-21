import AVFoundation
import CoreImage
import DemoRecKit
import Metal

/// Live, background-removed camera preview for the setup screen.
/// Runs its own capture session; stop it before recording so the recorder gets the camera.
final class CameraPreview: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Delivered on the main queue.
    var onImage: ((PreviewFrame) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "demorec.preview.session")
    private let frameQueue = DispatchQueue(label: "demorec.preview.frames")
    private let masker = PersonMasker(quality: .balanced)
    private let renderer = FrameRenderer() // frameQueue only
    private var mirror = false // frameQueue only
    private var look = Look() // frameQueue only
    private var masking = true // frameQueue only
    private var frameIndex = 0 // frameQueue only

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
    }

    func setMirror(_ value: Bool) {
        frameQueue.async { self.mirror = value }
    }

    func setLook(_ value: Look) {
        frameQueue.async { self.look = value }
    }

    /// Off for a glass tile, which shows the whole picture, so no segmentation runs.
    func setMasking(_ value: Bool) {
        frameQueue.async { self.masking = value }
    }

    func start(deviceID: String?) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
            let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Returns once the camera is released.
    func stop() async {
        await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                cont.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameIndex += 1
        guard frameIndex % 2 == 0, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return } // ~15 fps is plenty
        process(pb)
    }

    private let feedLock = NSLock()
    private var feedBusy = false
    private var feedIndex = 0

    /// Takes frames from another capture (the recorder's camera), dropping any that arrive while one is still
    /// being cut out, so the recorder's buffers are never held up.
    func feed(_ pb: CVPixelBuffer) {
        let take = feedLock.withLock {
            feedIndex += 1
            guard feedIndex % 2 == 0, !feedBusy else { return false }
            feedBusy = true
            return true
        }
        guard take else { return }
        frameQueue.async {
            self.process(pb)
            self.feedLock.withLock { self.feedBusy = false }
        }
    }

    private func process(_ pb: CVPixelBuffer) {
        let mask = masking ? try? masker.mask(for: pb) : nil
        var layout = Layout(feather: 1.5, mirror: mirror)
        layout.look = look
        let cutout = Compositor(layout: layout).cutout(camera: CIImage(cvPixelBuffer: pb), mask: mask)
        guard let frame = renderer.render(cutout) else { return }
        DispatchQueue.main.async { self.onImage?(frame) }
    }
}
