import AppKit
import CoreMedia
import DemoRecKit
import Observation
import SwiftUI

/// A small floating window showing the video as it's being recorded: your screen (cropped, sized and styled
/// like the output) with you in your spot. It's hidden from the recording. Show or hide it with the eye on the
/// recording pill; the choice is remembered for next time.
@MainActor @Observable
final class LivePreview {
    static let shared = LivePreview()

    /// Show the preview while recording.
    private(set) var enabled = UserDefaults.standard.bool(forKey: "previewWhileRecording")
    var screenImage: PreviewFrame?
    var personImage: PreviewFrame?

    @ObservationIgnored private weak var model: RecorderModel?
    @ObservationIgnored private weak var camera: CameraRecorder?
    @ObservationIgnored private var target: CaptureTarget?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var closer: Closer?
    @ObservationIgnored private var screen: ScreenPreview?
    @ObservationIgnored private var person: CameraPreview?
    @ObservationIgnored private var recording = false
    @ObservationIgnored private let zoomLink = ZoomLink()
    /// The trail being drawn, kept here rather than in the preview so a preview opened mid-stroke shows it too.
    @ObservationIgnored private let ink = LiveInk()

    /// For the recording's CursorRecorder: forwards the pointer and the zoom shortcut to the preview's zoom, so the
    /// preview zooms with the recording, and the trail to the preview's trail. Times move from recording time to the host clock the preview steps on,
    /// and points into the crop's coordinates, as in the setup preview.
    nonisolated func pointerHandler(startTime: CMTime, crop: CGRect?) -> (CursorRecorder.Event) -> Void {
        let link = zoomLink
        let ink = ink
        ink.clear()
        let offset = startTime.seconds
        let c = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return { event in
            func map(_ p: CursorTrack.Point) -> CursorTrack.Point {
                CursorTrack.Point(t: p.t + offset, x: (p.x - c.minX) / c.width, y: (p.y - c.minY) / c.height)
            }
            func inside(_ p: CursorTrack.Point) -> Bool { (0...1).contains(p.x) && (0...1).contains(p.y) }
            switch event {
            case .zoomIn(let p):
                // Near or just past the crop's edge, zoom on the nearest spot inside, as the video will.
                let q = map(p)
                link.zoomedIn(CursorTrack.Point(t: q.t, x: min(max(q.x, 0), 1), y: min(max(q.y, 0), 1)))
            case .zoomOut(let t): link.zoomedOut(t + offset)
            case .move(let p):
                ink.add(map(p))
                link.zoom?.moved(map(p))
            case .inkDown(let p): ink.begin(map(p))
            case .inkUp: ink.end()
            case .highlight(let h): ink.highlight(CursorTrack.Highlight(t: h.t + offset, x: h.x, y: h.y, w: h.w, h: h.h).cropped(to: c))
            case .click(let p):
                let q = map(p)
                if inside(q) { link.zoom?.clicked(q) }
            }
        }
    }

    /// Called when recording starts. Opens the window if you had it on last time.
    func setInkColors(trail: RGB, highlight: RGB) {
        ink.setColors(trail: trail, highlight: highlight)
    }

    func start(model: RecorderModel, camera: CameraRecorder?, target: CaptureTarget?) {
        setInkColors(trail: model.trailColor, highlight: model.highlightColor)
        self.model = model
        self.camera = camera
        self.target = target
        recording = true
        if enabled { open() }
    }

    /// Called when recording ends; keeps your show/hide choice.
    func stop() {
        recording = false
        close()
        model = nil
        camera = nil
    }

    func toggle() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "previewWhileRecording")
        guard recording else { return }
        enabled ? open() : close()
    }

    private func open() {
        guard panel == nil, let model else { return }

        let person = CameraPreview()
        person.setMirror(model.mirror)
        person.setLook(model.look)
        person.setMasking(model.presenter.needsMask)
        person.onImage = { [weak self] in self?.personImage = $0 }
        camera?.onVideoFrame = { [person] in person.feed($0) }
        self.person = person

        let screen = ScreenPreview(liveInk: ink)
        screen.liveZoom.setSettings(RecorderModel.zoomSettings)
        zoomLink.attach(screen.liveZoom)
        screen.setLayout(stage: model.stage, background: model.background, canvas: model.format.size, crop: model.crop, zoom: true)
        screen.onImage = { [weak self] in self?.screenImage = $0 }
        let target = target
        Task { try? await screen.start(target: target) }
        self.screen = screen

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Live Preview"
        panel.contentView = NSHostingView(rootView: LivePreviewView(preview: self, model: model))
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let closer = Closer { [weak self] in
            // Closing the window is the same as turning the preview off.
            guard let self, self.enabled else { return }
            self.toggle()
        }
        panel.delegate = closer
        self.closer = closer
        // Back where you last put it, as long as that's still on a screen; else the bottom-left corner.
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString),
           saved.width > 0, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            panel.setFrame(saved, display: false)
        } else if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.minX + 16, y: visible.minY + 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private nonisolated static let frameKey = "livePreviewFrame"

    private func close() {
        if let panel { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey) }
        zoomLink.attach(nil)
        if !recording { zoomLink.clear() }
        camera?.onVideoFrame = nil
        if let screen { Task { await screen.stop() } }
        screen = nil
        person = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        closer = nil
        screenImage = nil
        personImage = nil
    }

    /// Hands pointer events from the recorder's queue to whichever preview zoom is open, and remembers an ongoing
    /// zoom so a preview opened mid-zoom starts zoomed in too.
    private final class ZoomLink: @unchecked Sendable {
        private let lock = NSLock()
        private var _zoom: LiveZoom?
        private var zoomedAt: CursorTrack.Point?

        var zoom: LiveZoom? { lock.withLock { _zoom } }

        func attach(_ zoom: LiveZoom?) {
            let pending = lock.withLock { () -> CursorTrack.Point? in
                _zoom = zoom
                return zoomedAt
            }
            if let zoom, let pending { zoom.zoomedIn(pending) }
        }

        func zoomedIn(_ p: CursorTrack.Point) {
            let zoom = lock.withLock { zoomedAt = p; return _zoom }
            zoom?.zoomedIn(p)
        }

        func zoomedOut(_ t: Double) {
            let zoom = lock.withLock { zoomedAt = nil; return _zoom }
            zoom?.zoomedOut(at: t)
        }

        func clear() { lock.withLock { zoomedAt = nil } }
    }

    private final class Closer: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
        // Saved as you move or resize it, so a crash or quit mid-recording still keeps the spot.
        func windowDidMove(_ notification: Notification) { save(notification) }
        func windowDidEndLiveResize(_ notification: Notification) { save(notification) }
        private func save(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: LivePreview.frameKey)
        }
    }
}

/// The video as it's being recorded, laid out with the same maths as the setup preview and the final video.
private struct LivePreviewView: View {
    let preview: LivePreview
    let model: RecorderModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let screen = preview.screenImage {
                    SurfaceView(frame: screen)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView().controlSize(.small)
                }
                if let person = preview.personImage {
                    let h = geo.size.height * model.size
                    let w = PresenterTile.width(for: h, image: person, presenter: model.presenter)
                    PresenterTile(image: person, presenter: model.presenter, width: w, height: h, presenterScale: model.size)
                        .position(center(w: w, h: h, in: geo.size))
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(minWidth: 240, minHeight: 135)
    }

    private var aspect: CGFloat {
        if let s = preview.screenImage { return CGFloat(s.width) / CGFloat(max(s.height, 1)) }
        if let f = model.format.size { return f.width / f.height }
        return 16 / 9
    }

    private func center(w: CGFloat, h: CGFloat, in size: CGSize) -> CGPoint {
        if let p = model.position {
            let bottom = p.y * max(size.height - h, 0)
            return CGPoint(x: p.x * size.width, y: size.height - bottom - h / 2)
        }
        let m = size.height * RecorderModel.margin(for: model.corner)
        return switch model.corner {
        case .bottomRight: CGPoint(x: size.width - m - w / 2, y: size.height - m - h / 2)
        case .bottomLeft: CGPoint(x: m + w / 2, y: size.height - m - h / 2)
        case .topRight: CGPoint(x: size.width - m - w / 2, y: m + h / 2)
        case .topLeft: CGPoint(x: m + w / 2, y: m + h / 2)
        }
    }
}
