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

    public init(corner: Corner = .bottomRight, scale: Double = 0.35, margin: Double = 24, feather: Double = 2, mirror: Bool = false) {
        self.corner = corner
        self.scale = scale
        self.margin = margin
        self.feather = feather
        self.mirror = mirror
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
