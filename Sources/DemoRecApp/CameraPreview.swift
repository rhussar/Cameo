import AVFoundation
import CoreImage
import DemoRecKit
import Metal

/// Live, background-removed camera preview for the setup screen.
/// Runs its own capture session; stop it before recording so the recorder gets the camera.
final class CameraPreview: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Delivered on the main queue.
    var onImage: ((CGImage) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "demorec.preview.session")
    private let frameQueue = DispatchQueue(label: "demorec.preview.frames")
    private let masker = PersonMasker(quality: .balanced)
    private let ciContext: CIContext = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0) } ?? CIContext()
    private var mirror = false // frameQueue only
    private var look = Look() // frameQueue only
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
        let mask = try? masker.mask(for: pb)
        var layout = Layout(feather: 1.5, mirror: mirror)
        layout.look = look
        let cutout = Compositor(layout: layout).cutout(camera: CIImage(cvPixelBuffer: pb), mask: mask)
        guard let cg = ciContext.createCGImage(cutout, from: cutout.extent) else { return }
        DispatchQueue.main.async { self.onImage?(cg) }
    }
}
