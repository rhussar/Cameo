import AppKit
import CoreMedia

/// Where the pointer was, where you clicked, and where you asked for a zoom, during a recording.
/// Times are seconds after the shared start clock (so they line up with screen.mov), positions are
/// fractions of the recorded area with a top-left origin. Saved next to the recordings as cursor.json.
public struct CursorTrack: Codable, Sendable {
    public struct Point: Codable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }
    public var samples: [Point] = []
    public var clicks: [Point] = []
    /// Where you pressed the zoom shortcut to zoom in.
    public var marks: [Point] = []
    /// When you pressed the zoom shortcut again to zoom back out. nil in recordings from before the shortcut
    /// toggled; their marks zoom out on their own after a few seconds.
    public var zoomOuts: [Double]?

    public init() {}

    public static let fileName = "cursor.json"

    public static func load(from dir: URL) -> CursorTrack? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(CursorTrack.self, from: data)
    }

    public func save(to dir: URL) throws {
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent(Self.fileName))
    }

    /// The same track in the coordinates of a crop of the recorded area (see Layout.crop).
    /// Clicks and marks outside the crop are dropped, since there's nothing there to zoom in on.
    public func cropped(to crop: CGRect) -> CursorTrack {
        guard crop.width > 0, crop.height > 0 else { return self }
        func map(_ p: Point) -> Point { Point(t: p.t, x: (p.x - crop.minX) / crop.width, y: (p.y - crop.minY) / crop.height) }
        func inside(_ p: Point) -> Bool { (0...1).contains(p.x) && (0...1).contains(p.y) }
        var out = CursorTrack()
        out.samples = samples.map(map)
        out.clicks = clicks.map(map).filter(inside)
        out.marks = marks.map(map).filter(inside)
        out.zoomOuts = zoomOuts
        return out
    }
}

/// Polls the pointer and mouse buttons while recording. Polling needs no extra privacy permission
/// (unlike event taps) and no run loop, so it works the same in the app and the CLI.
public final class CursorRecorder: @unchecked Sendable {
    private let startTime: CMTime
    private let target: CaptureTarget?
    private let queue = DispatchQueue(label: "demorec.cursor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var track = CursorTrack()
    private var area = CGRect.zero
    private var tick = 0
    private var buttonsDown = false
    private var zoomedIn = false // queue only
    private let lock = NSLock()
    private let keepsTrack: Bool

    public enum Event: Sendable {
        case move(CursorTrack.Point)
        case click(CursorTrack.Point)
        /// The zoom shortcut: zoom in on this point.
        case zoomIn(CursorTrack.Point)
        /// The zoom shortcut again: zoom back out, at this time.
        case zoomOut(Double)
    }
    /// Called on the recorder's own queue as things happen. Set it before `start()`.
    public var onEvent: ((Event) -> Void)?

    /// `target` nil means the main display. With `keepsTrack` false nothing is kept, only reported through `onEvent`
    /// (for a live preview that runs for as long as the app is open).
    public init(startTime: CMTime, target: CaptureTarget?, keepsTrack: Bool = true) {
        self.startTime = startTime
        self.target = target
        self.keepsTrack = keepsTrack
        track.zoomOuts = []
    }

    public func start() {
        area = currentArea() ?? .zero
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    /// Asks for a zoom on wherever the pointer is right now.
    /// The zoom shortcut: zooms in on the pointer, or back out if already zoomed in.
    /// `done` gets whether it's now zoomed in, on the main queue.
    public func toggleZoom(done: (@Sendable (Bool) -> Void)? = nil) {
        queue.async { [self] in
            if zoomedIn {
                let t = (SharedClock.now() - startTime).seconds
                if keepsTrack { lock.lock(); track.zoomOuts?.append(t); lock.unlock() }
                zoomedIn = false
                onEvent?(.zoomOut(t))
            } else if let p = point(), (0...1).contains(p.x), (0...1).contains(p.y) {
                // (Off on another screen there's nothing here to zoom in on.)
                if keepsTrack { lock.lock(); track.marks.append(p); lock.unlock() }
                zoomedIn = true
                onEvent?(.zoomIn(p))
            }
            let now = zoomedIn
            DispatchQueue.main.async { done?(now) }
        }
    }

    /// Stops polling and returns what was recorded.
    public func stop() -> CursorTrack {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
        lock.lock(); defer { lock.unlock() }
        return track
    }

    private func poll() {
        tick += 1
        // A window can be moved mid-recording; checking its frame ~10 times a second is plenty.
        if case .window = target, tick % 12 == 0, let a = currentArea() { area = a }
        guard let p = point() else { return }
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
        // ~60 samples a second is enough to follow the pointer; the 120 Hz poll is for catching short clicks.
        let sample = tick % 2 == 0
        let click = down && !buttonsDown && (0...1).contains(p.x) && (0...1).contains(p.y)
        buttonsDown = down
        if keepsTrack {
            lock.lock()
            if sample { track.samples.append(p) }
            if click { track.clicks.append(p) }
            lock.unlock()
        }
        if sample { onEvent?(.move(p)) }
        if click { onEvent?(.click(p)) }
    }

    private func point() -> CursorTrack.Point? {
        guard area.width > 0, area.height > 0, let loc = CGEvent(source: nil)?.location else { return nil }
        let t = (SharedClock.now() - startTime).seconds
        guard t >= 0 else { return nil }
        // Both the pointer and the area are in global, top-left-origin points.
        return CursorTrack.Point(t: t, x: (loc.x - area.minX) / area.width, y: (loc.y - area.minY) / area.height)
    }

    private func currentArea() -> CGRect? {
        switch target {
        case .window(let id):
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  let bounds = info[kCGWindowBounds as String],
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { return nil }
            return rect
        case .display(let id):
            return CGDisplayBounds(id)
        case nil:
            return CGDisplayBounds(CGMainDisplayID())
        }
    }
}
