import AppKit
import AVFoundation
import DemoRecKit
import Observation
import ScreenCaptureKit

@MainActor @Observable
final class RecorderModel {
    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording(since: Date)
        case processing(Double)
        case done(URL)
        case failed(String, needsSettings: Bool)
    }

    var phase: Phase = .idle
    var cameras: [AVCaptureDevice] = []
    var previewImage: CGImage?
    var cameraDenied = false
    var thumbnail: CGImage?
    var stageHovering = false

    var cameraID: String? {
        didSet {
            UserDefaults.standard.set(cameraID, forKey: "cameraID")
            if cameraID != oldValue, isSetup { preview.start(deviceID: cameraID) }
        }
    }
    var corner: Corner {
        didSet { UserDefaults.standard.set(corner.rawValue, forKey: "corner") }
    }
    /// Cutout height as a fraction of the screen height.
    var size: Double {
        didSet { UserDefaults.standard.set(size, forKey: "size") }
    }
    var mirror: Bool {
        didSet {
            UserDefaults.standard.set(mirror, forKey: "mirror")
            preview.setMirror(mirror)
        }
    }

    var isSetup: Bool {
        switch phase {
        case .idle, .countdown, .failed: true
        default: false
        }
    }

    private let preview = CameraPreview()
    private var task: Task<Void, Never>?
    private var screen: ScreenRecorder?
    private var camera: CameraRecorder?
    private var sessionDir: URL?
    private let fps = 30

    init() {
        let d = UserDefaults.standard
        corner = d.string(forKey: "corner").flatMap(Corner.init(rawValue:)) ?? .bottomRight
        size = d.object(forKey: "size") as? Double ?? 0.35
        mirror = d.bool(forKey: "mirror")
        cameraID = d.string(forKey: "cameraID")
        preview.setMirror(mirror)
        preview.onImage = { [weak self] in self?.previewImage = $0 }
        refreshCameras()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCameras() }
            }
        }
    }

    var selectedCamera: AVCaptureDevice? { cameras.first { $0.uniqueID == cameraID } }

    func refreshCameras() {
        cameras = CameraRecorder.cameras()
        if selectedCamera == nil {
            // Prefer an external webcam over the built-in one.
            cameraID = (cameras.first { $0.deviceType == .external } ?? cameras.first)?.uniqueID
        }
    }

    func appeared() {
        Task {
            if await AVCaptureDevice.requestAccess(for: .video) {
                cameraDenied = false
                preview.start(deviceID: cameraID)
            } else {
                cameraDenied = true
            }
        }
    }

    // MARK: Recording

    func record() {
        task = Task { await startRecording() }
    }

    func cancelCountdown() {
        task?.cancel()
    }

    private func startRecording() async {
        do {
            try await CameraRecorder.requestAccess()
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                phase = .failed("DemoRec needs permission to record your screen. Turn it on in System Settings, then try again.", needsSettings: true)
                return
            }
            for n in [3, 2, 1] {
                phase = .countdown(n)
                try await Task.sleep(for: .seconds(1))
            }
            await preview.stop()
            let dir = try Session.makeFolder()
            let t0 = SharedClock.now()
            let cam = CameraRecorder(url: dir.appendingPathComponent("camera.mov"), fps: fps, startTime: t0)
            let scr = ScreenRecorder(url: dir.appendingPathComponent("screen.mov"), fps: fps, startTime: t0)
            camera = cam
            try cam.start(cameraName: selectedCamera?.localizedName)
            try await scr.start(displayID: currentDisplayID(), excludingCurrentApp: true)
            screen = scr
            sessionDir = dir
            phase = .recording(since: Date())
        } catch is CancellationError {
            phase = .idle
            preview.start(deviceID: cameraID)
        } catch {
            try? await camera?.stop()
            camera = nil
            phase = .failed(message(for: error), needsSettings: false)
            preview.start(deviceID: cameraID)
        }
    }

    func stop() {
        guard case .recording = phase, let screen, let camera, let sessionDir else { return }
        phase = .processing(0)
        let layout = Layout(corner: corner, scale: size, margin: 24 * (NSScreen.main?.backingScaleFactor ?? 2), mirror: mirror)
        task = Task {
            do {
                try await screen.stop()
                try await camera.stop()
                let transcoder = Transcoder(layout: layout, fps: fps, outputHeight: nil, quality: .accurate)
                transcoder.onProgress = { p in
                    Task { @MainActor in
                        if case .processing = self.phase { self.phase = .processing(p) }
                    }
                }
                let out = sessionDir.appendingPathComponent("final.mp4")
                try await transcoder.run(screenURL: sessionDir.appendingPathComponent("screen.mov"),
                                         cameraURL: sessionDir.appendingPathComponent("camera.mov"),
                                         outputURL: out)
                thumbnail = await Self.thumbnail(for: out)
                phase = .done(out)
                NSApp.requestUserAttention(.informationalRequest)
            } catch {
                phase = .failed(message(for: error), needsSettings: false)
            }
            self.screen = nil
            self.camera = nil
        }
    }

    func reset() {
        phase = .idle
        thumbnail = nil
        preview.start(deviceID: cameraID)
    }

    func play() {
        if case .done(let url) = phase { NSWorkspace.shared.open(url) }
    }

    func revealInFinder() {
        if case .done(let url) = phase { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func openPrivacySettings(camera: Bool = false) {
        let pane = camera ? "Privacy_Camera" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Aspect ratio of the screen being recorded, for the setup preview.
    var screenAspect: CGFloat {
        let f = (NSApp.keyWindow?.screen ?? NSScreen.main)?.frame.size ?? CGSize(width: 16, height: 10)
        return f.width / max(f.height, 1)
    }

    // MARK: Helpers

    /// The display the DemoRec window is on, so you record the screen you're looking at.
    private func currentDisplayID() -> CGDirectDisplayID? {
        let screen = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.screen ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func message(for error: Error) -> String {
        if let e = error as? DemoRecError { return e.description }
        return error.localizedDescription
    }

    private static func thumbnail(for url: URL) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 800, height: 800)
        return try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }
}
