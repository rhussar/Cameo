import Foundation

/// The camera on the screen for one frame: how far in, and which point is in the middle.
/// x and y are fractions of the screen with a top-left origin, like CursorTrack.
public struct ZoomState: Sendable, Equatable {
    public var scale: Double
    public var x: Double
    public var y: Double
    public static let none = ZoomState(scale: 1, x: 0.5, y: 0.5)
}

/// How eagerly and how hard the screen zooms on its own. The zoom shortcut works at every strength, even Off.
public enum ZoomStrength: String, CaseIterable, Sendable {
    case off, subtle, normal, strong

    public var name: String { rawValue.capitalized }

    public var note: String {
        switch self {
        case .off: "Only when you press the zoom shortcut"
        case .subtle: "A gentle zoom on clicks"
        case .normal: "Clicks, and where you stop to point at something"
        case .strong: "Close and quick, on every click and pause"
        }
    }
}

public struct ZoomSettings: Sendable {
    public var strength: ZoomStrength
    /// How far in, e.g. 2 = half the screen's width fills the frame.
    public var level: Double
    /// Spring stiffness for zooming in and out, and for panning. Lower is slower and calmer (~4 takes about a second).
    var zoomSpeed: Double
    var panSpeed: Double
    /// How much of the view the pointer can roam before the camera follows it: 0.8 = all but the outer 10% each side.
    var followSlack: Double
    /// Zoom where the pointer comes to rest, not just on clicks.
    var usesRests: Bool
    /// The pointer counts as resting after staying put this long, once it has travelled this far (fraction of the screen).
    var restMinDuration: Double
    var restMinTravel: Double
    /// Moments closer than this stay zoomed and pan between them.
    var mergeGap: Double
    /// After zooming out, wait this long before zooming in again on its own.
    var cooldown: Double

    /// `level` overrides the strength's own.
    public init(strength: ZoomStrength = .subtle, level: Double? = nil) {
        self.strength = strength
        switch strength {
        case .off:
            // Zooms you ask for with the shortcut: close enough to read, smooth, and following the pointer.
            self.level = 1.6; zoomSpeed = 4.5; panSpeed = 5; followSlack = 0.6
            usesRests = false; restMinDuration = 1.5; restMinTravel = 0.15; mergeGap = 3; cooldown = 6
        case .subtle:
            self.level = 1.4; zoomSpeed = 4.5; panSpeed = 4.5; followSlack = 0.8
            usesRests = false; restMinDuration = 1.5; restMinTravel = 0.15; mergeGap = 3; cooldown = 6
        case .normal:
            self.level = 1.6; zoomSpeed = 5.5; panSpeed = 5.5; followSlack = 0.75
            usesRests = true; restMinDuration = 1.5; restMinTravel = 0.15; mergeGap = 2.5; cooldown = 4
        case .strong:
            self.level = 1.8; zoomSpeed = 7; panSpeed = 8; followSlack = 0.6
            usesRests = true; restMinDuration = 0.8; restMinTravel = 0.08; mergeGap = 1.5; cooldown = 0
        }
        if let level { self.level = max(level, 1) }
    }

    /// Zooms on its own at all, rather than only when you press the zoom shortcut.
    public var auto: Bool { strength != .off }
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
        /// Contains a zoom you asked for with the shortcut, which always zooms.
        var marked = false
        /// Ends where you pressed the shortcut to zoom out, so it isn't stretched to meet the next zoom.
        var explicitEnd = false
    }

    // Timings, in seconds. The lead lets the camera arrive just as the moment happens.
    static let clickLead = 0.5, clickHold = 2.2
    static let markLead = 0.3, markHold = 3.0
    static let restLead = 0.4, restMinHold = 1.5, restMaxHold = 4.0
    /// The pointer counts as resting while it stays this close (fraction of the screen).
    static let restRadius = 0.012

    static func segments(for track: CursorTrack, settings: ZoomSettings) -> [Segment] {
        var windows: [Segment] = track.marks.map { mark in
            guard let outs = track.zoomOuts else {
                return Segment(start: mark.t - markLead, end: mark.t + markHold, focus: mark, marked: true)
            }
            // Zoomed in until you pressed the shortcut again, or to the end if you didn't.
            let end = outs.first { $0 > mark.t } ?? .infinity
            return Segment(start: mark.t - markLead, end: end, focus: mark, marked: true, explicitEnd: true)
        }
        if settings.auto {
            windows += track.clicks.map { Segment(start: $0.t - clickLead, end: $0.t + clickHold, focus: $0) }
            if settings.usesRests {
                windows += rests(in: track.samples, settings: settings).map { rest in
                    Segment(start: rest.point.t - restLead, end: rest.point.t + min(max(rest.duration, restMinHold), restMaxHold), focus: rest.point)
                }
            }
        }
        windows.sort { $0.start < $1.start }
        var merged: [Segment] = []
        for w in windows {
            if let last = merged.last, w.start - last.end < settings.mergeGap, !last.explicitEnd {
                merged[merged.count - 1].end = max(last.end, w.end)
                merged[merged.count - 1].marked = last.marked || w.marked
                merged[merged.count - 1].explicitEnd = w.end >= last.end ? w.explicitEnd : last.explicitEnd
            } else if let last = merged.last, w.start - last.end < settings.cooldown, !w.marked {
                continue // just zoomed out: let the full view breathe before zooming in again
            } else {
                merged.append(w)
            }
        }
        return merged
    }

    /// Places where the pointer stopped after going somewhere new.
    static func rests(in samples: [CursorTrack.Point], settings: ZoomSettings) -> [(point: CursorTrack.Point, duration: Double)] {
        guard var anchor = samples.first else { return [] }
        var result: [(CursorTrack.Point, Double)] = []
        var lastRest = anchor // where the recording starts counts as already looked at
        var runEnd = anchor
        func finishRun() {
            let duration = runEnd.t - anchor.t
            let travel = hypot(anchor.x - lastRest.x, anchor.y - lastRest.y)
            guard duration >= settings.restMinDuration, travel >= settings.restMinTravel,
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
        var camera = Camera(settings: settings)
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
        let zoomSpeed: Double
        let panSpeed: Double
        /// How far (fraction of the screen) the pointer can get from the middle of the view before the camera follows.
        let deadZone: Double
        var scale = Spring(value: 1), x = Spring(value: 0.5), y = Spring(value: 0.5)
        var targetX = 0.5, targetY = 0.5
        var wasZoomed = false

        init(settings: ZoomSettings) {
            level = max(settings.level, 1)
            zoomSpeed = settings.zoomSpeed
            panSpeed = settings.panSpeed
            deadZone = 0.5 / level * settings.followSlack
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
            scale.step(toward: focus == nil ? 1 : level, omega: zoomSpeed, dt: dt)
            x.step(toward: targetX, omega: panSpeed, dt: dt)
            y.step(toward: targetY, omega: panSpeed, dt: dt)
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
    /// When the last zoom ended, for the cooldown.
    private var zoomedOutAt = -Double.infinity

    public init(settings: ZoomSettings = ZoomSettings()) {
        self.settings = settings
        camera = ZoomPlanner.Camera(settings: settings)
    }

    /// Switches strength, starting over from the whole screen.
    public func setSettings(_ settings: ZoomSettings) {
        lock.lock()
        self.settings = settings
        lock.unlock()
        reset()
    }

    /// Forget everything, e.g. when what's previewed changes.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        camera = ZoomPlanner.Camera(settings: settings)
        zoomedOutAt = -.infinity
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
        if !resting, duration >= settings.restMinDuration, let last = lastRest,
           hypot(a.x - last.x, a.y - last.y) >= settings.restMinTravel,
           (0...1).contains(a.x), (0...1).contains(a.y) {
            resting = true
            lastRest = a
        }
        if resting, settings.auto, settings.usesRests {
            autoZoom(on: a, until: a.t + min(max(duration, ZoomPlanner.restMinHold), ZoomPlanner.restMaxHold))
        }
    }

    public func clicked(_ p: CursorTrack.Point) {
        lock.lock(); defer { lock.unlock() }
        if settings.auto { autoZoom(on: p, until: p.t + ZoomPlanner.clickHold) }
    }

    /// The zoom shortcut: stays zoomed in until `zoomedOut`.
    public func zoomedIn(_ p: CursorTrack.Point) {
        lock.lock(); defer { lock.unlock() }
        focus = p
        zoomedUntil = .infinity
    }

    public func zoomedOut(at t: Double) {
        lock.lock(); defer { lock.unlock() }
        zoomedUntil = t
    }

    /// True while the view is zoomed or moving, so the preview knows to keep redrawing.
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return focus != nil || !camera.isSettled
    }

    public func step(now: Double, dt: Double) -> ZoomState {
        lock.lock(); defer { lock.unlock() }
        if now > zoomedUntil, focus != nil {
            focus = nil
            zoomedOutAt = now
        }
        return camera.step(t: now, focus: focus, cursor: cursor.map { ($0.x, $0.y) }, dt: dt)
    }

    /// A zoom it decided on itself, which waits out the cooldown. It can't see ahead to stay zoomed between
    /// close moments like the video does, so it holds a zoom a little longer instead.
    private func autoZoom(on p: CursorTrack.Point, until end: Double) {
        guard focus != nil || p.t - zoomedOutAt >= settings.cooldown else { return }
        zoom(on: p, until: end + settings.mergeGap / 2)
    }

    private func zoom(on p: CursorTrack.Point, until end: Double) {
        if focus == nil || p.t > zoomedUntil { focus = p }
        zoomedUntil = max(zoomedUntil, end)
    }
}
