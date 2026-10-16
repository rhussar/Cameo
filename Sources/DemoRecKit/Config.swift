import Foundation

public enum Corner: String, CaseIterable, Sendable {
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
    case topRight = "top-right"
    case topLeft = "top-left"
}

public enum MaskQuality: String, CaseIterable, Sendable {
    case fast, balanced, accurate
}

/// How the presenter cutout is placed over the screen recording.
public struct Layout: Sendable {
    public var corner: Corner = .bottomRight
    /// Cutout height as a fraction of the screen height.
    public var scale: Double = 0.35
    /// Distance from the two nearest edges, in output pixels.
    public var margin: Double = 24
    /// Gaussian blur sigma applied to the mask edge. 0 disables.
    public var feather: Double = 2
    /// Flip the camera horizontally (selfie-style).
    public var mirror: Bool = false
    /// Presentation styling for the screen (blurred backdrop, rounded tilted card). nil = flat full-frame screen.
    public var stage: Stage? = nil
    /// Output frame size in pixels. nil = the screen recording's own size. When the screen's shape differs,
    /// it's fitted inside and the rest is filled with a blurred copy of it. Scale and margin are then relative to this frame.
    public var canvas: CGSize? = nil
    /// Colour adjustments applied to you (the cutout), not the screen.
    public var look = Look()
    /// Free placement, overriding `corner` and `margin`.
    /// x: centre of the cutout as a fraction of the frame width, so you can sit closer to a side than a corner allows
    /// (anything past the edge is cropped). y: 0 = flush with the bottom, 1 = flush with the top, so a flush
    /// bottom stays flush when the size changes.
    public var position: CGPoint? = nil
    /// The part of the screen recording to show, as fractions of it with a top-left origin (like CursorTrack).
    /// nil = all of it. Applied before zoom, staging and fitting, so everything else treats the crop as the screen.
    public var crop: CGRect? = nil

    public init(corner: Corner = .bottomRight, scale: Double = 0.35, margin: Double = 24, feather: Double = 2, mirror: Bool = false) {
        self.corner = corner
        self.scale = scale
        self.margin = margin
        self.feather = feather
        self.mirror = mirror
    }
}

extension Layout {
    /// The crop in pixels of a `size` screen, CoreImage's bottom-left origin, whole and even-sized
    /// so the video encoder takes it as is. The whole screen when there's no crop.
    public func cropRect(in size: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        guard let c = crop?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), !c.isEmpty else { return full }
        let w = max(2, (c.width * size.width).rounded()), h = max(2, (c.height * size.height).rounded())
        let x = (c.minX * size.width).rounded(), y = ((1 - c.maxY) * size.height).rounded()
        let r = CGRect(x: x, y: y, width: CGFloat(Int(w) & ~1), height: CGFloat(Int(h) & ~1))
        return r.intersection(full)
    }
}

/// Presentation styling: the screen becomes a rounded, slightly tilted card with a drop shadow,
/// floating over a zoomed and blurred copy of itself. Fractions are relative to the output frame height.
public struct Stage: Sendable {
    /// Card height as a fraction of the frame height.
    public var inset: Double = 0.88
    /// Horizontal position of the card centre, 0 = left edge, 1 = right edge.
    public var cardX: Double = 0.47
    /// Vertical position of the card centre, 0 = bottom, 1 = top.
    public var cardY: Double = 0.5
    /// Rotation about the vertical axis, in degrees. Positive brings the left edge closer.
    public var tilt: Double = 4
    /// Corner radius as a fraction of the frame height.
    public var cornerRadius: Double = 0.012
    /// Backdrop blur sigma as a fraction of the frame height.
    public var backgroundBlur: Double = 0.03
    /// Backdrop zoom factor.
    public var backgroundZoom: Double = 1.2
    /// Backdrop darkening, 0 = none, 1 = black.
    public var backgroundDim: Double = 0.35
    /// Drop shadow opacity, 0 disables.
    public var shadowOpacity: Double = 0.6
    /// Drop shadow blur sigma as a fraction of the frame height.
    public var shadowBlur: Double = 0.03
    /// Drop shadow vertical offset as a fraction of the frame height.
    public var shadowOffset: Double = 0.02

    public init() {}
}

/// Colour adjustments for the presenter cutout.
public struct Look: Sendable, Equatable, Codable {
    /// -1...1, 0 = unchanged.
    public var brightness: Double = 0
    /// 0.5...1.5, 1 = unchanged.
    public var contrast: Double = 1
    /// 0...2, 1 = unchanged, 0 = black and white.
    public var saturation: Double = 1
    /// -1 (cooler) ... 1 (warmer), 0 = unchanged.
    public var warmth: Double = 0

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, warmth: Double = 0) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
    }

    public var isNeutral: Bool { self == Look() }

    public static let presets: [(name: String, look: Look)] = [
        ("Natural", Look()),
        ("Bright", Look(brightness: 0.25, contrast: 1.05, saturation: 1.05)),
        ("Warm", Look(brightness: 0.1, saturation: 1.05, warmth: 0.45)),
        ("Cool", Look(contrast: 1.05, saturation: 0.95, warmth: -0.4)),
        ("Vivid", Look(contrast: 1.15, saturation: 1.35)),
        ("Mono", Look(contrast: 1.15, saturation: 0)),
    ]
}

/// Output frame sizes tuned for where the video is going.
public enum OutputFormat: String, CaseIterable, Sendable {
    case original
    case youtube4K, youtube1440
    case x1080
    case linkedin1080, linkedinSquare, linkedinPortrait

    /// nil = keep the screen recording's own size and shape.
    public var size: CGSize? {
        switch self {
        case .original: nil
        case .youtube4K: CGSize(width: 3840, height: 2160)
        case .youtube1440: CGSize(width: 2560, height: 1440)
        case .x1080, .linkedin1080: CGSize(width: 1920, height: 1080)
        case .linkedinSquare: CGSize(width: 1080, height: 1080)
        case .linkedinPortrait: CGSize(width: 1080, height: 1350)
        }
    }

    public var platform: String {
        switch self {
        case .original: ""
        case .youtube4K, .youtube1440: "YouTube"
        case .x1080: "X"
        case .linkedin1080, .linkedinSquare, .linkedinPortrait: "LinkedIn"
        }
    }

    public var name: String {
        switch self {
        case .original: "Original size"
        case .youtube4K: "4K · 16:9"
        case .youtube1440: "1440p · 16:9"
        case .x1080: "1080p · 16:9"
        case .linkedin1080: "1080p · 16:9"
        case .linkedinSquare: "Square · 1:1"
        case .linkedinPortrait: "Portrait · 4:5"
        }
    }

    public var note: String {
        switch self {
        case .original: "Same shape as what you record"
        case .youtube4K: "Sharpest text; YouTube gives 4K uploads more bitrate"
        case .youtube1440: "Smaller file, still crisp"
        case .x1080: "Safe max for X; keep under 2:20 without Premium"
        case .linkedin1080: "Best for desktop viewers"
        case .linkedinSquare: "Bigger in the mobile feed"
        case .linkedinPortrait: "Tallest the LinkedIn feed shows"
        }
    }
}

/// Where recordings go. The CLI keeps each recording's files in a timestamped folder under ~/Movies/DemoRec.
/// The app keeps only the finished videos there, side by side, and does its recording in `workBase`.
public enum Session {
    public static let defaultBase = URL(fileURLWithPath: NSString(string: "~/Movies/DemoRec").expandingTildeInPath)
    /// The app's working folders (screen.mov, camera.mov, cursor.json) while it records and makes the video.
    public static let workBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DemoRec/Recordings")

    private static func videoName(_ app: String) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "'\(app)' yyyy-MM-dd 'at' HH.mm.ss"
        return fmt
    }
    private static let videoName = videoName("Cameo")
    /// The app was called DemoRec before; its videos are named that way.
    private static let videoNames = [videoName, videoName("DemoRec")]

    /// A new video's file in `base`, named for when it was recorded like macOS's own screen recordings,
    /// e.g. "Cameo 2026-10-15 at 20.27.42.mp4". Never one that's already there.
    public static func videoURL(recordedAt date: Date, in base: URL = defaultBase) throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let name = videoName.string(from: date)
        var url = base.appendingPathComponent(name + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = base.appendingPathComponent("\(name) \(n).mp4")
            n += 1
        }
        return url
    }

    /// When a video named by `videoURL` was recorded.
    public static func recordedAt(video: URL) -> Date? {
        let name = video.deletingPathExtension().lastPathComponent
        // "… at 20.27.42 2" was the second video that second.
        for fmt in videoNames {
            if let date = fmt.date(from: name) ?? name.lastIndex(of: " ").flatMap({ fmt.date(from: String(name[..<$0])) }) { return date }
        }
        return nil
    }

    public static func makeFolder(in base: URL = defaultBase) throws -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = base.appendingPathComponent(fmt.string(from: Date()))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
