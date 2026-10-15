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
