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
    var microphones: [AVCaptureDevice] = []
    var previewImage: CGImage?
    var cameraDenied = false
    var thumbnail: CGImage?
    /// Past recordings, newest first.
    var recordings: [Recording] = []
    var previewHovering = false
    var lookOpen = false
    /// Window content width, so controls can grow with a bigger window.
    var windowWidth: CGFloat = 1100

    /// Output frame size, e.g. YouTube 4K or LinkedIn square.
    var format: OutputFormat {
        didSet {
            UserDefaults.standard.set(format.rawValue, forKey: "format")
            // A crop shaped like the old video would leave bars in the new one.
            if let crop, let k = cropRatio { self.crop = Self.reshaped(crop, ratio: k) }
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
            if target != oldValue {
                cropping = false
                updateScreenPreviewLayout() // each screen keeps its own crop
                if isSetup { startScreenPreview() }
            }
        }
    }
    var displaySources: [Source] = []
    var windowSources: [Source] = []
    var screenImage: CGImage?
    var screenAccess = CGPreflightScreenCaptureAccess()
    var selectedSource: Source? { (displaySources + windowSources).first { $0.target == target } }

    /// The camera and mic you picked. Kept while they're unplugged (say, the monitor's webcam when you
    /// undock), so they're used again as soon as they come back; meanwhile a fallback stands in.
    var cameraID: String? {
        didSet {
            UserDefaults.standard.set(cameraID, forKey: "cameraID")
            restartCameraPreviewIfNeeded()
        }
    }
    var microphoneID: String? {
        didSet { UserDefaults.standard.set(microphoneID, forKey: "microphoneID") }
    }
    var corner: Corner {
        didSet { UserDefaults.standard.set(corner.rawValue, forKey: "corner") }
    }
    /// Where you've dragged yourself (see Layout.position). nil = snapped to `corner`.
    var position: CGPoint? {
        didSet {
            if let position {
                UserDefaults.standard.set([position.x, position.y], forKey: "position")
            } else {
                UserDefaults.standard.removeObject(forKey: "position")
            }
        }
    }
    /// Drag state for the preview: your centre when the drag began, and whether you're snapped to the middle.
    var dragOrigin: CGPoint?
    /// The crop when a drag of the crop box began.
    var cropDragStart: CGRect?
    var snappedToMiddle = false
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
    /// Press to zoom in on the pointer and follow it, press again to zoom out. Works anywhere while DemoRec is open.
    var zoomShortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(zoomShortcut) { UserDefaults.standard.set(data, forKey: "zoomShortcut") }
            registerZoomHotKey()
        }
    }
    /// Another app already uses the zoom shortcut, so it does nothing here.
    var zoomShortcutTaken = false
    /// Waiting for you to press a new zoom shortcut.
    var capturingShortcut = false
    /// Why the last key pressed while capturing wasn't taken.
    var shortcutHint: String?
    private var shortcutMonitor: Any?
    /// Card tilt in degrees when styled; positive brings the left edge closer.
    var tilt: Double {
        didSet {
            UserDefaults.standard.set(tilt, forKey: "tilt")
            updateScreenPreviewLayout()
        }
    }
    /// The part of each screen or window that goes in the video (see Layout.crop), keyed by `cropKey`.
    private var crops: [String: CGRect] {
        didSet {
            // Window IDs don't survive a relaunch, so only screens' crops are kept.
            let saved = crops.filter { $0.key.hasPrefix("display-") }.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }
            UserDefaults.standard.set(saved, forKey: "crops")
        }
    }
    /// The crop for what you're recording. nil = all of it.
    var crop: CGRect? {
        get { target.flatMap { crops[Self.cropKey($0)] } }
        set {
            guard let target else { return }
            crops[Self.cropKey(target)] = newValue
            if !cropping { updateScreenPreviewLayout() }
        }
    }
    /// Editing the crop: the preview shows the whole screen with the crop box over it.
    var cropping = false {
        didSet {
            guard cropping != oldValue else { return }
            if cropping, crop == nil { crop = defaultCrop() }
            // A box around (nearly) everything is no crop at all.
            if !cropping, let c = crop, c.width > 0.995, c.height > 0.995 { crop = nil }
            updateScreenPreviewLayout()
        }
    }
    func clearCrop() {
        crop = nil
        cropping = false
    }
    /// Width / height of the crop box in fractions of the screen so the crop exactly fills the video's frame.
    /// nil (any shape) when the video takes its shape from the crop.
    var cropRatio: CGFloat? {
        guard let out = format.size, let src = selectedSource?.size, src.width > 0, src.height > 0 else { return nil }
        return (out.width / out.height) / (src.width / src.height)
    }
    private static func cropKey(_ target: CaptureTarget) -> String {
        switch target {
        case .display(let id): "display-\(id)"
        case .window(let id): "window-\(id)"
        }
    }
    /// The biggest box shaped like the video, or 80% of the screen when that's the whole screen anyway.
    private func defaultCrop() -> CGRect {
        var w: CGFloat = 1, h: CGFloat = 1
        if let k = cropRatio { if k > 1 { h = 1 / k } else { w = k } }
        if w * h > 0.95 { w *= 0.8; h *= 0.8 }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
    /// `rect` reshaped to `ratio`, keeping its centre and about the same area, inside the screen.
    static func reshaped(_ rect: CGRect, ratio k: CGFloat) -> CGRect {
        var h = (rect.width * rect.height / k).squareRoot(), w = h * k
        let over = max(w, h, 1)
        w /= over; h /= over
        let x = min(max(rect.midX - w / 2, 0), 1 - w), y = min(max(rect.midY - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func updateScreenPreviewLayout() {
        screenPreview.liveZoom.reset() // the zoom works in the crop's coordinates
        if cropping {
            screenPreview.setLayout(stage: nil, canvas: nil, crop: nil, zoom: false)
        } else {
            screenPreview.setLayout(stage: stage, canvas: format.size, crop: crop, zoom: true)
        }
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
    private var cursor: CursorRecorder?
    private var zoomHotKey: HotKey?
    /// Watches the pointer during setup so the preview zooms like the video will.
    private var previewCursor: CursorRecorder?
    private var sessionDir: URL?
    private let fps = 30

    init() {
        let d = UserDefaults.standard
        corner = d.string(forKey: "corner").flatMap(Corner.init(rawValue:)) ?? .bottomRight
        position = (d.array(forKey: "position") as? [Double]).flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        size = d.object(forKey: "size") as? Double ?? 0.35
        mirror = d.bool(forKey: "mirror")
        styled = d.bool(forKey: "styled")
        tilt = d.object(forKey: "tilt") as? Double ?? Stage().tilt
        zoomShortcut = d.data(forKey: "zoomShortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .defaultZoom
        cameraID = d.string(forKey: "cameraID")
        microphoneID = d.string(forKey: "microphoneID")
        format = d.string(forKey: "format").flatMap(OutputFormat.init(rawValue:)) ?? .original
        crops = (d.dictionary(forKey: "crops") as? [String: [Double]] ?? [:]).compactMapValues { v in
            v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
        }
        look = d.data(forKey: "look").flatMap { try? JSONDecoder().decode(Look.self, from: $0) } ?? Look()
        preview.setMirror(mirror)
        preview.setLook(look)
        updateScreenPreviewLayout()
        screenPreview.liveZoom.setSettings(Self.zoomSettings)
        preview.onImage = { [weak self] in self?.previewImage = $0 }
        screenPreview.onImage = { [weak self] in self?.screenImage = $0 }
        refreshDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            }
        }
    }

    /// The camera in use: your pick if it's connected, else an external webcam, a phone, then the built-in one.
    var selectedCamera: AVCaptureDevice? {
        cameras.first { $0.uniqueID == cameraID }
            ?? cameras.first { $0.deviceType == .external }
            ?? cameras.first { $0.deviceType == .continuityCamera }
            ?? cameras.first
    }
    /// The mic in use: your pick if it's connected, else the system default.
    var selectedMicrophone: AVCaptureDevice? {
        microphones.first { $0.uniqueID == microphoneID } ?? AVCaptureDevice.default(for: .audio)
    }
    /// What the pickers show and set.
    var cameraChoice: String? {
        get { selectedCamera?.uniqueID }
        set { cameraID = newValue }
    }
    var microphoneChoice: String? {
        get { selectedMicrophone?.uniqueID }
        set { microphoneID = newValue }
    }

    func refreshDevices() {
        cameras = CameraRecorder.cameras()
        microphones = CameraRecorder.microphones()
        restartCameraPreviewIfNeeded()
    }

    private var previewStarted = false
    private var previewCameraID: String?

    /// Switches the live preview when the camera in use changes (a pick, or a device coming or going).
    private func restartCameraPreviewIfNeeded() {
        guard previewStarted, isSetup, !cameraDenied, selectedCamera?.uniqueID != previewCameraID else { return }
        startCameraPreview()
    }

    private func startCameraPreview() {
        previewStarted = true
        previewCameraID = selectedCamera?.uniqueID
        preview.start(deviceID: previewCameraID)
    }

    func appeared() {
        if zoomHotKey == nil, !capturingShortcut { registerZoomHotKey() }
        Task {
            if await AVCaptureDevice.requestAccess(for: .video) {
                cameraDenied = false
                startCameraPreview()
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
        startPreviewCursor(target: target)
        Task {
            do {
                try await screenPreview.start(target: target)
            } catch {
                await refreshSources()
            }
        }
    }

    private func startPreviewCursor(target: CaptureTarget?) {
        _ = previewCursor?.stop()
        screenPreview.liveZoom.reset()
        // Time zero, so points carry plain host-clock seconds like ScreenPreview.now().
        let watcher = CursorRecorder(startTime: .zero, target: target ?? currentDisplayID().map { .display($0) }, keepsTrack: false)
        watcher.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.previewPointer(event) } }
        }
        watcher.start()
        previewCursor = watcher
    }

    /// Passes the pointer to the preview's zoom, in the crop's coordinates. Ignores moves and clicks over DemoRec's
    /// own windows: they aren't in the recording, and clicking DemoRec's buttons shouldn't zoom the preview.
    private func previewPointer(_ event: CursorRecorder.Event) {
        guard isSetup, !cropping else { return }
        let zoom = screenPreview.liveZoom
        let c = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        func map(_ p: CursorTrack.Point) -> CursorTrack.Point {
            CursorTrack.Point(t: p.t, x: (p.x - c.minX) / c.width, y: (p.y - c.minY) / c.height)
        }
        func inside(_ p: CursorTrack.Point) -> Bool { (0...1).contains(p.x) && (0...1).contains(p.y) }
        switch event {
        // The shortcut counts wherever the pointer is: it's what the recording would do.
        case .zoomIn(let p): if inside(map(p)) { zoom.zoomedIn(map(p)) }
        case .zoomOut(let t): zoom.zoomedOut(at: t)
        case .move(let p): if !overDemoRec() { zoom.moved(map(p)) }
        case .click(let p): if !overDemoRec(), inside(map(p)) { zoom.clicked(map(p)) }
        }
    }

    private func overDemoRec() -> Bool {
        let mouse = NSEvent.mouseLocation
        return NSApp.windows.contains { $0.isVisible && $0.frame.contains(mouse) }
    }

    // MARK: Zoom shortcut

    /// Zooms are only the ones you ask for with the shortcut, moving gently and following the pointer.
    static let zoomSettings = ZoomSettings(strength: .off)

    /// One shortcut for the app's lifetime: during setup it zooms the preview, while recording it zooms the video.
    private func registerZoomHotKey() {
        zoomHotKey?.unregister()
        zoomHotKey = HotKey(zoomShortcut) { [weak self] in
            guard let self else { return }
            if case .recording = phase {
                cursor?.toggleZoom { [weak self] zoomedIn in
                    MainActor.assumeIsolated { self?.pill.setZoomed(zoomedIn) }
                }
            } else if isSetup, !cropping {
                previewCursor?.toggleZoom()
            }
        }
        zoomShortcutTaken = zoomHotKey == nil && zoomShortcut.mouseButton == nil
        zoomShortcutNeedsAccess = zoomHotKey == nil && zoomShortcut.mouseButton != nil
        if zoomShortcutNeedsAccess, accessObserver == nil {
            // You grant access in System Settings; try again each time you come back to DemoRec.
            accessObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.zoomShortcutNeedsAccess, !self.capturingShortcut else { return }
                    self.registerZoomHotKey()
                }
            }
        }
    }

    private var accessObserver: NSObjectProtocol?

    /// A mouse-button shortcut is set but DemoRec doesn't have Accessibility access yet.
    var zoomShortcutNeedsAccess = false

    /// Asks macOS for Accessibility access (opening the prompt or Settings), then tries the mouse button again.
    func requestMouseAccess() {
        if !HotKey.mouseAccess(prompt: true),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        registerZoomHotKey()
    }

    /// Click the shortcut button, then press the new shortcut. Esc or a second click cancels.
    func toggleCapturingShortcut() {
        if capturingShortcut { finishCapturing(nil); return }
        capturingShortcut = true
        shortcutHint = nil
        // Off while capturing, or pressing the current shortcut would zoom instead of being captured.
        zoomHotKey?.unregister()
        zoomHotKey = nil
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .otherMouseDown {
                if let s = Shortcut(mouseButton: event.buttonNumber) { finishCapturing(s) }
            } else if event.keyCode == 53 { // Esc
                finishCapturing(nil)
            } else if let s = Shortcut(event: event) {
                finishCapturing(s)
            } else {
                shortcutHint = "Hold ⌘, ⌃ or ⌥ too, use an F-key, or press a mouse button"
            }
            return nil
        }
    }

    private func finishCapturing(_ shortcut: Shortcut?) {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        capturingShortcut = false
        shortcutHint = nil
        if let shortcut {
            // A mouse button needs Accessibility access; ask now, while you're looking at the app.
            if shortcut.mouseButton != nil { _ = HotKey.mouseAccess(prompt: true) }
            zoomShortcut = shortcut // registers it
        } else {
            registerZoomHotKey()
        }
    }

    private func startPreviews() {
        startCameraPreview()
        startScreenPreview()
    }

    private func stopPreviews() async {
        _ = previewCursor?.stop()
        previewCursor = nil
        await preview.stop()
        await screenPreview.stop()
    }

    // MARK: Recording

    func record() {
        cropping = false
        if capturingShortcut { finishCapturing(nil) }
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
            try cam.start(cameraName: selectedCamera?.localizedName, cameraID: selectedCamera?.uniqueID,
                          microphoneID: selectedMicrophone?.uniqueID)
            let recorded = target ?? currentDisplayID().map { .display($0) }
            try await scr.start(target: recorded, excludingCurrentApp: true)
            screen = scr
            sessionDir = dir
            let cur = CursorRecorder(startTime: t0, target: recorded)
            cur.start()
            cursor = cur
            let since = Date()
            cur.onEvent = LivePreview.shared.pointerHandler(startTime: t0, crop: crop)
            phase = .recording(since: since)
            pill.show(since: since, on: recordedScreen(), zoomHint: zoomHotKey == nil ? nil : zoomShortcut.label,
                      discard: { [weak self] in self?.discard() }, stop: { [weak self] in self?.stop() })
            mainWindow?.orderOut(nil)
        } catch is CancellationError {
            phase = .idle
            LivePreview.shared.start(model: self, camera: cam, target: recorded)
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
        let track = cursor?.stop()
        cursor = nil
        let zoom = Self.zoomSettings
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        var layout = Layout(corner: corner, scale: size, mirror: mirror)
        layout.crop = crop
        // Same margin the setup preview draws.
        let frameHeight = format.size?.height ?? layout.cropRect(in: screen.pixelSize).height
        layout.margin = Self.margin(for: corner) * frameHeight
        layout.stage = stage
        layout.canvas = format.size
        layout.look = look
        layout.position = position
        task = Task {
            do {
                try await screen.stop()
                try await camera.stop()
                try? track?.save(to: sessionDir)
                let transcoder = Transcoder(layout: layout, fps: fps, outputHeight: nil, quality: .balanced, cursor: track, zoom: zoom)
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
                loadRecordings()
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

    /// Stops the recording without making the video and moves its files to the Trash, after asking.
    func discard() {
        guard case .recording = phase else { return }
        NSApp.activate()
        guard Self.confirmDelete("Delete this recording?", detail: "It won't be saved. Its files go to the Trash.",
                                 keep: "Keep Recording") else { return }
        // Bring the window back before the pill goes, so the app never has zero windows up.
        mainWindow?.makeKeyAndOrderFront(nil)
        pill.hide()
        _ = cursor?.stop()
        cursor = nil
        let screen = screen, camera = camera, dir = sessionDir
        task = Task {
            try? await screen?.stop()
            try? await camera?.stop()
            self.screen = nil
            self.camera = nil
            self.sessionDir = nil
            if let dir { Self.trash(dir) }
            phase = .idle
            startPreviews()
        }
    }

    /// Moves the finished video and its source files to the Trash, after asking.
    func deleteFinished() {
        guard case .done(let url) = phase else { return }
        guard Self.confirmDelete("Delete this video?", detail: "The video and its recording files go to the Trash.",
                                 keep: "Cancel") else { return }
        Self.trash(url.deletingLastPathComponent())
        loadRecordings()
        reset()
    }

    private static func confirmDelete(_ title: String, detail: String, keep: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: keep).keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Trashes a session folder; refuses anything outside the recordings folder.
    private static func trash(_ folder: URL) {
        let base = Session.defaultBase.standardizedFileURL.path + "/"
        guard folder.standardizedFileURL.path.hasPrefix(base) else { return }
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }

    // MARK: History

    func loadRecordings() {
        let fm = FileManager.default
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folders = (try? fm.contentsOfDirectory(at: Session.defaultBase, includingPropertiesForKeys: nil)) ?? []
        recordings = folders.compactMap { folder in
            guard let date = fmt.date(from: folder.lastPathComponent) else { return nil }
            let recording = Recording(folder: folder, date: date)
            return fm.fileExists(atPath: recording.video.path) ? recording : nil
        }
        .sorted { $0.date > $1.date }
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.video])
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Session.defaultBase, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Session.defaultBase)
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
        let c = cropping ? nil : crop
        return f.width * (c?.width ?? 1) / max(f.height * (c?.height ?? 1), 1)
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

/// A finished recording: its session folder and the video in it.
struct Recording: Hashable, Identifiable {
    let folder: URL
    let date: Date
    var video: URL { folder.appendingPathComponent("final.mp4") }
    var id: URL { folder }
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
