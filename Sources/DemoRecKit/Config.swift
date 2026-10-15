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

    public init(corner: Corner = .bottomRight, scale: Double = 0.35, margin: Double = 24, feather: Double = 2, mirror: Bool = false) {
        self.corner = corner
        self.scale = scale
        self.margin = margin
        self.feather = feather
        self.mirror = mirror
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

/// Timestamped session folders under ~/Movies/DemoRec.
public enum Session {
    public static let defaultBase = URL(fileURLWithPath: NSString(string: "~/Movies/DemoRec").expandingTildeInPath)

    public static func makeFolder(in base: URL = defaultBase) throws -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = base.appendingPathComponent(fmt.string(from: Date()))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
