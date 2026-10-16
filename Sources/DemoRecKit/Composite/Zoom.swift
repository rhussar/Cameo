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
        let level = max(settings.level, 1)
        let dt = 1 / Double(fps)
        // Half the visible width/height when fully zoomed; the pointer can roam the middle 60% before the camera follows.
        let deadZone = 0.5 / level * 0.6
        var scale = Spring(value: 1), x = Spring(value: 0.5), y = Spring(value: 0.5)
        var targetX = 0.5, targetY = 0.5
        var segIndex = 0
        var path: [ZoomState] = []
        path.reserveCapacity(frames)

        for i in 0..<frames {
            let t = start + Double(i) * dt
            while segIndex < segments.count, segments[segIndex].end < t { segIndex += 1 }
            let seg = segIndex < segments.count && segments[segIndex].start <= t ? segments[segIndex] : nil
            if let seg {
                if t < seg.focus.t {
                    // Heading in: look where the moment will be, not where the pointer is on its way.
                    targetX = seg.focus.x
                    targetY = seg.focus.y
                } else if let c = position(in: track.samples, at: t + 0.15) {
                    if abs(c.x - targetX) > deadZone { targetX = c.x - deadZone * (c.x > targetX ? 1 : -1) }
                    if abs(c.y - targetY) > deadZone { targetY = c.y - deadZone * (c.y > targetY ? 1 : -1) }
                }
                let lo = 0.5 / level
                targetX = min(max(targetX, lo), 1 - lo)
                targetY = min(max(targetY, lo), 1 - lo)
            }
            if i == 0, seg != nil {
                // Already zoomed when the video starts: begin in place rather than animating in from frame one.
                scale.value = level; x.value = targetX; y.value = targetY
            }
            scale.step(toward: seg == nil ? 1 : level, omega: 7, dt: dt)
            x.step(toward: targetX, omega: 8, dt: dt)
            y.step(toward: targetY, omega: 8, dt: dt)
            // Keep the view on the screen at whatever zoom it's at right now.
            let s = max(scale.value, 1)
            let half = 0.5 / s
            path.append(ZoomState(scale: s, x: min(max(x.value, half), 1 - half), y: min(max(y.value, half), 1 - half)))
        }
        return path
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
