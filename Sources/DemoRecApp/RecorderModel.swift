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
    var previewHovering = false
    var lookOpen = false
    /// Window content width, so controls can grow with a bigger window.
    var windowWidth: CGFloat = 1100

    /// Output frame size, e.g. YouTube 4K or LinkedIn square.
    var format: OutputFormat {
        didSet {
            UserDefaults.standard.set(format.rawValue, forKey: "format")
            updateScreenPreviewLayout()
        }
    }
    /// Colour adjustments for you (the cutout).
    var look: Look {
        didSet {
            if let data = try? JSONEncoder().encode(look) { UserDefaults.standard.set(data, forKey: "look") }
            preview.setLook(look)
        }
    }
    var lookName: String { Look.presets.first { $0.look == look }?.name ?? "Custom" }

    /// What gets recorded. Nil until the first refresh picks the display DemoRec is on.
    var target: CaptureTarget? {
        didSet {
            if case .display(let id) = target { UserDefaults.standard.set(Int(id), forKey: "displayID") }
            if target != oldValue, isSetup { startScreenPreview() }
        }
    }
    var displaySources: [Source] = []
    var windowSources: [Source] = []
    var screenImage: CGImage?
    var screenAccess = CGPreflightScreenCaptureAccess()
    var selectedSource: Source? { (displaySources + windowSources).first { $0.target == target } }

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
    /// Present the screen as a rounded, tilted card over a blurred backdrop.
    var styled: Bool {
        didSet {
            UserDefaults.standard.set(styled, forKey: "styled")
            updateScreenPreviewLayout()
        }
    }
    /// Card tilt in degrees when styled; positive brings the left edge closer.
    var tilt: Double {
        didSet {
            UserDefaults.standard.set(tilt, forKey: "tilt")
            updateScreenPreviewLayout()
        }
    }
    private func updateScreenPreviewLayout() {
        screenPreview.setLayout(stage: stage, canvas: format.size)
    }

    private var stage: Stage? {
        guard styled else { return nil }
        var stage = Stage()
        stage.tilt = tilt
        return stage
    }

    /// Recording, or making the video: quitting or closing now would lose it.
    var isBusy: Bool {
        switch phase {
        case .recording, .processing: true
        default: false
        }
    }

    /// Asks before quitting while busy. True = go ahead and quit.
    func confirmQuit() -> Bool {
        let alert = NSAlert()
        switch phase {
        case .recording:
            alert.messageText = "You're still recording."
            alert.informativeText = "If you quit now, this recording will be lost."
            alert.addButton(withTitle: "Keep Recording")
        case .processing:
            alert.messageText = "DemoRec is still making your video."
            alert.informativeText = "If you quit now, the video won't be finished."
            alert.addButton(withTitle: "Keep Making It")
        default:
            return true
        }
        alert.addButton(withTitle: "Quit Anyway")
        alert.alertStyle = .warning
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    var isSetup: Bool {
        switch phase {
        case .idle, .countdown, .failed: true
        default: false
        }
    }

    private let preview = CameraPreview()
    private let screenPreview = ScreenPreview()
    private let pill = PillPanel()
    weak var mainWindow: NSWindow?
    private var refreshLoop: Task<Void, Never>?
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
        styled = d.bool(forKey: "styled")
        tilt = d.object(forKey: "tilt") as? Double ?? Stage().tilt
        cameraID = d.string(forKey: "cameraID")
        format = d.string(forKey: "format").flatMap(OutputFormat.init(rawValue:)) ?? .original
        look = d.data(forKey: "look").flatMap { try? JSONDecoder().decode(Look.self, from: $0) } ?? Look()
        preview.setMirror(mirror)
        preview.setLook(look)
        updateScreenPreviewLayout()
        preview.onImage = { [weak self] in self?.previewImage = $0 }
        screenPreview.onImage = { [weak self] in self?.screenImage = $0 }
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
        // Keep the screen/window list current while you're setting up (windows open and close).
        refreshLoop?.cancel()
        refreshLoop = Task {
            while !Task.isCancelled {
                if isSetup { await refreshSources() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func requestScreenAccess() {
        CGRequestScreenCaptureAccess()
        Task { await refreshSources() }
    }

    func refreshSources() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            screenAccess = false
            return
        }
        let firstAccess = !screenAccess
        screenAccess = true
        let names = Dictionary(NSScreen.screens.compactMap { s in s.displayID.map { ($0, s.localizedName) } }, uniquingKeysWith: { a, _ in a })
        displaySources = content.displays.map { d in
            Source(target: .display(d.displayID), title: names[d.displayID] ?? "Display \(d.displayID)",
                   subtitle: d.displayID == CGMainDisplayID() ? "Main screen" : "", frame: d.frame)
        }
        let hidden: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.notificationcenterui", Bundle.main.bundleIdentifier ?? ""]
        windowSources = content.windows
            .filter { w in
                w.windowLayer == 0 && w.isOnScreen && w.frame.width >= 200 && w.frame.height >= 150
                    && !(w.title ?? "").isEmpty // untitled windows are mostly invisible helper overlays
                    && !hidden.contains(w.owningApplication?.bundleIdentifier ?? "")
                    && w.owningApplication?.processID != getpid()
            }
            .map { w in
                let app = w.owningApplication?.applicationName ?? "Window"
                return Source(target: .window(w.windowID), title: app, subtitle: w.title ?? "", frame: w.frame)
            }
            .sorted { ($0.title.lowercased(), $0.subtitle) < ($1.title.lowercased(), $1.subtitle) }

        // Pick a default, or fall back to a screen if the chosen window was closed.
        if target == nil || selectedSource == nil {
            let saved = UserDefaults.standard.object(forKey: "displayID") as? Int
            let preferred = saved.map { CGDirectDisplayID($0) } ?? currentDisplayID()
            target = (displaySources.first { $0.target == .display(preferred ?? 0) } ?? displaySources.first)?.target
        } else if firstAccess, isSetup {
            startScreenPreview()
        }
    }

    private func startScreenPreview() {
        screenImage = nil
        let target = target
        Task {
            do {
                try await screenPreview.start(target: target)
            } catch {
                await refreshSources()
            }
        }
    }

    private func startPreviews() {
        preview.start(deviceID: cameraID)
        startScreenPreview()
    }

    private func stopPreviews() async {
        await preview.stop()
        await screenPreview.stop()
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
            await stopPreviews()
            let dir = try Session.makeFolder()
            let t0 = SharedClock.now()
            let cam = CameraRecorder(url: dir.appendingPathComponent("camera.mov"), fps: fps, startTime: t0)
            let scr = ScreenRecorder(url: dir.appendingPathComponent("screen.mov"), fps: fps, startTime: t0)
            camera = cam
            try cam.start(cameraName: selectedCamera?.localizedName)
            try await scr.start(target: target ?? currentDisplayID().map { .display($0) }, excludingCurrentApp: true)
            screen = scr
            sessionDir = dir
            let since = Date()
            phase = .recording(since: since)
            pill.show(since: since, on: recordedScreen(), stop: { [weak self] in self?.stop() })
            mainWindow?.orderOut(nil)
        } catch is CancellationError {
            phase = .idle
            startPreviews()
        } catch {
            try? await camera?.stop()
            camera = nil
            phase = .failed(message(for: error), needsSettings: false)
            startPreviews()
        }
    }

    func stop() {
        guard case .recording = phase, let screen, let camera, let sessionDir else { return }
        phase = .processing(0)
        pill.hide()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Same margin the setup preview draws.
        let frameHeight = format.size?.height ?? screen.pixelSize.height
        var layout = Layout(corner: corner, scale: size, margin: Self.margin(for: corner) * frameHeight, mirror: mirror)
        layout.stage = stage
        layout.canvas = format.size
        layout.look = look
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
        startPreviews()
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

    /// Aspect ratio of what's being recorded, for the setup preview.
    var screenAspect: CGFloat {
        if let img = screenImage { return CGFloat(img.width) / CGFloat(max(img.height, 1)) }
        let f = selectedSource?.size ?? (NSScreen.main?.frame.size ?? CGSize(width: 16, height: 10))
        return f.width / max(f.height, 1)
    }

    // MARK: Helpers

    /// Cutout inset as a fraction of the frame height. In a bottom corner you sit flush on the frame's edges,
    /// so where the camera crops your body lines up with the edge of the video; up top you get a little room.
    static func margin(for corner: Corner) -> Double {
        switch corner {
        case .bottomLeft, .bottomRight: 0
        case .topLeft, .topRight: 0.025
        }
    }

    /// The display the DemoRec window is on, so you record the screen you're looking at.
    private func currentDisplayID() -> CGDirectDisplayID? {
        (mainWindow?.screen ?? NSScreen.main)?.displayID
    }

    /// The screen the recording is happening on, where the stop pill should sit.
    private func recordedScreen() -> NSScreen? {
        guard let frame = selectedSource?.frame else { return mainWindow?.screen }
        // SCDisplay/SCWindow frames and CGDisplayBounds share global, top-left-origin coordinates.
        return NSScreen.screens.max { a, b in
            func overlap(_ s: NSScreen) -> CGFloat {
                guard let id = s.displayID else { return 0 }
                let r = CGDisplayBounds(id).intersection(frame)
                return r.isNull ? 0 : r.width * r.height
            }
            return overlap(a) < overlap(b)
        } ?? mainWindow?.screen
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

/// One thing you can record: a screen or a window.
struct Source: Hashable, Identifiable {
    let target: CaptureTarget
    let title: String
    let subtitle: String
    /// Global, top-left-origin coordinates.
    let frame: CGRect
    var size: CGSize { frame.size }
    var id: CaptureTarget { target }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
