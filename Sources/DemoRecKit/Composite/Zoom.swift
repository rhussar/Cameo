import Foundation

/// The camera on the screen for one frame: how far in, and which point is in the middle.
/// x and y are fractions of the screen with a top-left origin, like CursorTrack.
public struct ZoomState: Sendable, Equatable {
    public var scale: Double
    public var x: Double
    public var y: Double
    public static let none = ZoomState(scale: 1, x: 0.5, y: 0.5)
}

public struct ZoomSettings: Sendable {
    /// Zoom in on clicks and on spots where the pointer comes to rest. Off = only the spots you mark with the hotkey.
    public var auto: Bool = true
    /// How far in, e.g. 2 = half the screen's width fills the frame.
    public var level: Double = 1.8

    public init(auto: Bool = true, level: Double = 1.8) {
        self.auto = auto
        self.level = level
    }
}

/// Plans a smooth, Screen Studio-style camera from a cursor track: zoom in around clicks, pauses and marked
/// spots, follow the pointer while zoomed (only once it nears the edge of the view), and zoom back out when
/// things go quiet. Close-together moments become one zoom that pans instead of zooming out and back in.
public enum ZoomPlanner {
    /// A stretch of time spent zoomed in. `focus` is where to look first.
    struct Segment {
        var start: Double
        var end: Double
        var focus: CursorTrack.Point
    }

    // Timings, in seconds. The lead lets the camera arrive just as the moment happens.
    static let clickLead = 0.5, clickHold = 2.2
    static let markLead = 0.3, markHold = 3.0
    static let restLead = 0.4, restMinHold = 1.5, restMaxHold = 4.0
    /// Moments closer than this stay zoomed and pan between them.
    static let mergeGap = 1.5
    /// The pointer counts as resting when it stays this close (fraction of the screen) for restMinDuration.
    static let restRadius = 0.012, restMinDuration = 0.8
    /// A rest only counts when the pointer travelled this far since the last one, so an idle pointer doesn't keep zooming.
    static let restMinTravel = 0.08

    static func segments(for track: CursorTrack, settings: ZoomSettings) -> [Segment] {
        var windows: [Segment] = track.marks.map { Segment(start: $0.t - markLead, end: $0.t + markHold, focus: $0) }
        if settings.auto {
            windows += track.clicks.map { Segment(start: $0.t - clickLead, end: $0.t + clickHold, focus: $0) }
            windows += rests(in: track.samples).map { rest in
                Segment(start: rest.point.t - restLead, end: rest.point.t + min(max(rest.duration, restMinHold), restMaxHold), focus: rest.point)
            }
        }
        windows.sort { $0.start < $1.start }
        var merged: [Segment] = []
        for w in windows {
            if let last = merged.last, w.start - last.end < mergeGap {
                merged[merged.count - 1].end = max(last.end, w.end)
            } else {
                merged.append(w)
            }
        }
        return merged
    }

    /// Places where the pointer stopped after going somewhere new.
    static func rests(in samples: [CursorTrack.Point]) -> [(point: CursorTrack.Point, duration: Double)] {
        guard var anchor = samples.first else { return [] }
        var result: [(CursorTrack.Point, Double)] = []
        var lastRest = anchor // where the recording starts counts as already looked at
        var runEnd = anchor
        func finishRun() {
            let duration = runEnd.t - anchor.t
            let travel = hypot(anchor.x - lastRest.x, anchor.y - lastRest.y)
            guard duration >= restMinDuration, travel >= restMinTravel,
                  (0...1).contains(anchor.x), (0...1).contains(anchor.y) else { return }
            result.append((anchor, duration))
            lastRest = anchor
        }
        for p in samples.dropFirst() {
            if hypot(p.x - anchor.x, p.y - anchor.y) > restRadius {
                finishRun()
                anchor = p
            }
            runEnd = p
        }
        finishRun()
        return result
    }

    /// One ZoomState per output frame. Frame i shows the moment `start + i / fps` (seconds on the cursor clock).
    public static func path(track: CursorTrack, settings: ZoomSettings, start: Double, fps: Int, frames: Int) -> [ZoomState] {
        let segments = segments(for: track, settings: settings)
        guard !segments.isEmpty, frames > 0 else { return Array(repeating: .none, count: max(frames, 0)) }
        let dt = 1 / Double(fps)
        var camera = Camera(level: settings.level)
        var segIndex = 0
        var path: [ZoomState] = []
        path.reserveCapacity(frames)

        for i in 0..<frames {
            let t = start + Double(i) * dt
            while segIndex < segments.count, segments[segIndex].end < t { segIndex += 1 }
            let seg = segIndex < segments.count && segments[segIndex].start <= t ? segments[segIndex] : nil
            // Already zoomed when the video starts: begin in place rather than animating in from frame one.
            if i == 0, let seg { camera.snap(to: seg.focus) }
            path.append(camera.step(t: t, focus: seg?.focus, cursor: position(in: track.samples, at: t + 0.15), dt: dt))
        }
        return path
    }

    /// Moves the view: zoomed in on `focus` while there is one, following the pointer once it nears the edge
    /// of the view, and back out to the whole screen when there isn't. Springs keep every move smooth.
    struct Camera {
        let level: Double
        /// Half the visible width/height when fully zoomed; the pointer can roam the middle 60% before the camera follows.
        let deadZone: Double
        var scale = Spring(value: 1), x = Spring(value: 0.5), y = Spring(value: 0.5)
        var targetX = 0.5, targetY = 0.5
        var wasZoomed = false

        init(level: Double) {
            self.level = max(level, 1)
            deadZone = 0.5 / self.level * 0.6
        }

        var isSettled: Bool {
            !wasZoomed && abs(scale.value - 1) < 0.001 && abs(scale.velocity) < 0.001
        }

        mutating func snap(to focus: CursorTrack.Point) {
            aim(at: focus.x, focus.y)
            scale.value = level; x.value = targetX; y.value = targetY
        }

        mutating func step(t: Double, focus: CursorTrack.Point?, cursor: (x: Double, y: Double)?, dt: Double) -> ZoomState {
            if let focus {
                if !wasZoomed || t < focus.t {
                    // Heading in: look where the moment is, not where the pointer is on its way.
                    aim(at: focus.x, focus.y)
                } else if let c = cursor {
                    var tx = targetX, ty = targetY
                    if abs(c.x - tx) > deadZone { tx = c.x - deadZone * (c.x > tx ? 1 : -1) }
                    if abs(c.y - ty) > deadZone { ty = c.y - deadZone * (c.y > ty ? 1 : -1) }
                    aim(at: tx, ty)
                }
            }
            wasZoomed = focus != nil
            scale.step(toward: focus == nil ? 1 : level, omega: 7, dt: dt)
            x.step(toward: targetX, omega: 8, dt: dt)
            y.step(toward: targetY, omega: 8, dt: dt)
            // Keep the view on the screen at whatever zoom it's at right now.
            let s = max(scale.value, 1)
            let half = 0.5 / s
            return ZoomState(scale: s, x: min(max(x.value, half), 1 - half), y: min(max(y.value, half), 1 - half))
        }

        private mutating func aim(at x: Double, _ y: Double) {
            let lo = 0.5 / level
            targetX = min(max(x, lo), 1 - lo)
            targetY = min(max(y, lo), 1 - lo)
        }
    }

    /// The pointer position at time t, interpolated between samples.
    static func position(in samples: [CursorTrack.Point], at t: Double) -> (x: Double, y: Double)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return (first.x, first.y) }
        if t >= last.t { return (last.x, last.y) }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }

    /// Critically damped spring, stepped implicitly so it never overshoots or blows up.
    struct Spring {
        var value: Double
        var velocity = 0.0

        mutating func step(toward target: Double, omega: Double, dt: Double) {
            let f = 1 + 2 * dt * omega
            let oo = omega * omega
            let hoo = dt * oo
            let hhoo = dt * hoo
            let detInv = 1 / (f + hhoo)
            let newValue = (f * value + dt * velocity + hhoo * target) * detInv
            velocity = (velocity + hoo * (target - value)) * detInv
            value = newValue
        }
    }
}

/// The same camera as ZoomPlanner, driven as things happen instead of from a finished recording, for the
/// live preview. It can't see ahead, so it zooms just after a click instead of arriving with it.
/// Feed it the pointer and step it from any threads; points use the same clock throughout.
public final class LiveZoom: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: ZoomSettings
    private var camera: ZoomPlanner.Camera
    private var focus: CursorTrack.Point?
    private var zoomedUntil = -Double.infinity
    private var cursor: CursorTrack.Point?
    // Rest detection, as in ZoomPlanner.rests.
    private var anchor: CursorTrack.Point?
    private var lastRest: CursorTrack.Point?
    private var resting = false

    public init(settings: ZoomSettings = ZoomSettings()) {
        self.settings = settings
        camera = ZoomPlanner.Camera(level: settings.level)
    }

    public func setAuto(_ auto: Bool) {
        lock.lock(); defer { lock.unlock() }
        settings.auto = auto
        if !auto { zoomedUntil = -.infinity } // drop any auto zoom in progress
    }

    /// Forget everything, e.g. when what's previewed changes.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        camera = ZoomPlanner.Camera(level: settings.level)
        focus = nil; zoomedUntil = -.infinity; cursor = nil; anchor = nil; lastRest = nil; resting = false
    }

    public func moved(_ p: CursorTrack.Point) {
        lock.lock(); defer { lock.unlock() }
        cursor = p
        guard let a = anchor else { anchor = p; lastRest = p; return }
        if hypot(p.x - a.x, p.y - a.y) > ZoomPlanner.restRadius {
            anchor = p
            resting = false
            return
        }
        let duration = p.t - a.t
        if !resting, duration >= ZoomPlanner.restMinDuration, let last = lastRest,
           hypot(a.x - last.x, a.y - last.y) >= ZoomPlanner.restMinTravel,
           (0...1).contains(a.x), (0...1).contains(a.y) {
            resting = true
            lastRest = a
        }
        if resting, settings.auto {
            zoom(on: a, until: a.t + min(max(duration, ZoomPlanner.restMinHold), ZoomPlanner.restMaxHold))
        }
    }

    public func clicked(_ p: CursorTrack.Point) {
        lock.lock(); defer { lock.unlock() }
        if settings.auto { zoom(on: p, until: p.t + ZoomPlanner.clickHold) }
    }

    public func marked(_ p: CursorTrack.Point) {
        lock.lock(); defer { lock.unlock() }
        zoom(on: p, until: p.t + ZoomPlanner.markHold)
    }

    /// True while the view is zoomed or moving, so the preview knows to keep redrawing.
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return focus != nil || !camera.isSettled
    }

    public func step(now: Double, dt: Double) -> ZoomState {
        lock.lock(); defer { lock.unlock() }
        if now > zoomedUntil { focus = nil }
        return camera.step(t: now, focus: focus, cursor: cursor.map { ($0.x, $0.y) }, dt: dt)
    }

    private func zoom(on p: CursorTrack.Point, until end: Double) {
        if focus == nil || p.t > zoomedUntil { focus = p }
        zoomedUntil = max(zoomedUntil, end)
    }
}
