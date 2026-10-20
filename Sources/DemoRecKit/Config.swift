import Foundation

public enum Corner: String, CaseIterable, Sendable, Codable {
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
    case topRight = "top-right"
    case topLeft = "top-left"
}

public enum MaskQuality: String, CaseIterable, Sendable {
    case fast, balanced, accurate
}

/// How the presenter cutout is placed over the screen recording.
public struct Layout: Sendable, Codable {
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
    /// What fills the frame behind the screen card (and shows through a glass tile). Only visible when the screen
    /// doesn't cover the whole frame: a staged card, or a canvas of a different shape.
    public var background: Background = .screen
    /// How you appear: a background-removed cutout, or the whole camera picture in a glass tile.
    public var presenter = Presenter()

    public init(corner: Corner = .bottomRight, scale: Double = 0.35, margin: Double = 24, feather: Double = 2, mirror: Bool = false) {
        self.corner = corner
        self.scale = scale
        self.margin = margin
        self.feather = feather
        self.mirror = mirror
    }

    private enum CodingKeys: String, CodingKey {
        case corner, scale, margin, feather, mirror, stage, canvas, look, position, crop, background, presenter
    }

    /// Layouts saved by older versions lack the newer keys; they take the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        corner = try c.decodeIfPresent(Corner.self, forKey: .corner) ?? .bottomRight
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 0.35
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 24
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 2
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? false
        stage = try c.decodeIfPresent(Stage.self, forKey: .stage)
        canvas = try c.decodeIfPresent(CGSize.self, forKey: .canvas)
        look = try c.decodeIfPresent(Look.self, forKey: .look) ?? Look()
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position)
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop)
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? .screen
        presenter = try c.decodeIfPresent(Presenter.self, forKey: .presenter) ?? Presenter()
    }
}

/// What fills the frame behind the screen.
public enum Background: Sendable, Codable, Equatable, Hashable {
    /// A zoomed, blurred, dimmed copy of the screen itself (the classic look).
    case screen
    /// One of `BackgroundPreset.all`, by name: soft colour washes like a blurred wallpaper.
    case preset(String)
    /// A picture of your own, scaled to cover the frame. `blur` is a sigma as a fraction of the frame height; 0 = sharp.
    case image(path: String, blur: Double)

    public var preset: BackgroundPreset? {
        if case .preset(let name) = self { return BackgroundPreset.named(name) }
        return nil
    }

    /// A name for menus and the CLI: "screen", a preset name, or "image".
    public var label: String {
        switch self {
        case .screen: "Screen"
        case .preset(let name): name
        case .image: "Image"
        }
    }
}

/// A soft wash of a few colour blobs over a base colour, like a blurred wallpaper. Positions and radii are
/// fractions of the frame (x left to right, y bottom to top, radius of the frame's long side).
public struct BackgroundPreset: Sendable, Equatable, Hashable {
    public struct RGB: Sendable, Equatable, Hashable {
        public var r: Double, g: Double, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    }
    public struct Blob: Sendable, Equatable, Hashable {
        public var color: RGB
        public var x: Double, y: Double, radius: Double
        public init(_ color: RGB, x: Double, y: Double, radius: Double) { self.color = color; self.x = x; self.y = y; self.radius = radius }
    }
    public var name: String
    public var base: RGB
    public var blobs: [Blob]
    /// Strength of a fine single-pixel grain over the wash: its peak-to-peak swing in display values. 0 = none;
    /// around 0.035 reads as a soft pastel card, 0.055 as the grain on a dark poster. It survives H.264 at the
    /// video's bitrate at roughly 80% strength.
    public var grain: Double = 0

    /// The colours, base first, for drawing a swatch.
    public var colors: [RGB] { [base] + blobs.map(\.color) }

    public static func named(_ name: String) -> BackgroundPreset? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public static let all: [BackgroundPreset] = [
        // Soft pastel cards with a fine grain.
        BackgroundPreset(name: "Mist", base: RGB(0.85, 0.85, 0.87), blobs: [
            Blob(RGB(0.95, 0.95, 0.96), x: 0.2, y: 0.85, radius: 0.5),
            Blob(RGB(0.72, 0.72, 0.76), x: 0.85, y: 0.15, radius: 0.55),
        ], grain: 0.03),
        BackgroundPreset(name: "Sage", base: RGB(0.71, 0.79, 0.69), blobs: [
            Blob(RGB(0.84, 0.89, 0.80), x: 0.2, y: 0.85, radius: 0.5),
            Blob(RGB(0.56, 0.66, 0.54), x: 0.85, y: 0.15, radius: 0.55),
        ], grain: 0.035),
        BackgroundPreset(name: "Blush", base: RGB(0.93, 0.78, 0.78), blobs: [
            Blob(RGB(0.98, 0.89, 0.85), x: 0.2, y: 0.85, radius: 0.5),
            Blob(RGB(0.85, 0.62, 0.67), x: 0.85, y: 0.15, radius: 0.55),
        ], grain: 0.035),
        BackgroundPreset(name: "Lavender", base: RGB(0.78, 0.75, 0.90), blobs: [
            Blob(RGB(0.89, 0.87, 0.96), x: 0.2, y: 0.85, radius: 0.5),
            Blob(RGB(0.62, 0.58, 0.82), x: 0.85, y: 0.15, radius: 0.55),
        ], grain: 0.035),
        BackgroundPreset(name: "Sand", base: RGB(0.87, 0.80, 0.68), blobs: [
            Blob(RGB(0.95, 0.91, 0.81), x: 0.2, y: 0.85, radius: 0.5),
            Blob(RGB(0.74, 0.65, 0.52), x: 0.85, y: 0.15, radius: 0.55),
        ], grain: 0.035),
        BackgroundPreset(name: "Sky", base: RGB(0.72, 0.83, 0.93), blobs: [
            Blob(RGB(0.87, 0.93, 0.98), x: 0.2, y: 0.85, radius: 0.5),
            Blob(RGB(0.54, 0.70, 0.86), x: 0.85, y: 0.15, radius: 0.55),
        ], grain: 0.03),
        // Richer washes, like a blurred photo.
        BackgroundPreset(name: "Meadow", base: RGB(0.44, 0.52, 0.30), blobs: [
            Blob(RGB(0.70, 0.76, 0.46), x: 0.15, y: 0.85, radius: 0.45),
            Blob(RGB(0.30, 0.38, 0.18), x: 0.85, y: 0.15, radius: 0.6),
            Blob(RGB(0.62, 0.68, 0.40), x: 0.6, y: 0.6, radius: 0.35),
        ]),
        BackgroundPreset(name: "Peach", base: RGB(0.86, 0.62, 0.48), blobs: [
            Blob(RGB(0.45, 0.55, 0.70), x: 0.1, y: 0.9, radius: 0.5),
            Blob(RGB(0.95, 0.45, 0.40), x: 0.9, y: 0.3, radius: 0.5),
            Blob(RGB(0.98, 0.88, 0.70), x: 0.45, y: 0.4, radius: 0.25),
        ]),
        BackgroundPreset(name: "Sunset", base: RGB(0.92, 0.50, 0.36), blobs: [
            Blob(RGB(0.98, 0.78, 0.40), x: 0.2, y: 0.8, radius: 0.5),
            Blob(RGB(0.55, 0.25, 0.50), x: 0.85, y: 0.15, radius: 0.6),
            Blob(RGB(0.98, 0.45, 0.55), x: 0.55, y: 0.5, radius: 0.35),
        ]),
        BackgroundPreset(name: "Ocean", base: RGB(0.10, 0.32, 0.52), blobs: [
            Blob(RGB(0.30, 0.75, 0.80), x: 0.2, y: 0.8, radius: 0.5),
            Blob(RGB(0.05, 0.12, 0.30), x: 0.9, y: 0.1, radius: 0.6),
            Blob(RGB(0.45, 0.65, 0.90), x: 0.6, y: 0.55, radius: 0.35),
        ]),
        BackgroundPreset(name: "Dusk", base: RGB(0.22, 0.16, 0.38), blobs: [
            Blob(RGB(0.72, 0.30, 0.60), x: 0.15, y: 0.85, radius: 0.5),
            Blob(RGB(0.08, 0.06, 0.18), x: 0.9, y: 0.1, radius: 0.6),
            Blob(RGB(0.35, 0.30, 0.70), x: 0.6, y: 0.5, radius: 0.4),
        ]),
        // Neutrals.
        BackgroundPreset(name: "Cocoa", base: RGB(0.16, 0.115, 0.11), blobs: [
            Blob(RGB(0.075, 0.06, 0.06), x: 0.0, y: 0.4, radius: 0.7),
            Blob(RGB(0.26, 0.18, 0.165), x: 1.0, y: 0.75, radius: 0.65),
        ], grain: 0.055),
        BackgroundPreset(name: "Grey", base: RGB(0.50, 0.50, 0.52), blobs: [
            Blob(RGB(0.60, 0.60, 0.62), x: 0.2, y: 0.85, radius: 0.5),
            Blob(RGB(0.40, 0.40, 0.42), x: 0.85, y: 0.15, radius: 0.55),
        ], grain: 0.045),
        BackgroundPreset(name: "Graphite", base: RGB(0.14, 0.14, 0.15), blobs: [
            Blob(RGB(0.26, 0.26, 0.28), x: 0.2, y: 0.85, radius: 0.5),
            Blob(RGB(0.06, 0.06, 0.07), x: 0.9, y: 0.1, radius: 0.6),
        ], grain: 0.05),
    ]
}

/// How you appear in the video.
public struct Presenter: Sendable, Codable, Equatable, Hashable {
    public enum Style: String, CaseIterable, Sendable, Codable {
        /// You, cut out of the camera picture, floating over the screen.
        case cutout
        /// The whole camera picture in a rounded glass tile with a soft rim and shadow.
        case glass
    }
    public enum Tile: String, CaseIterable, Sendable, Codable {
        case portrait, square, landscape

        /// Width / height.
        public var aspect: Double {
            switch self {
            case .portrait: 0.68
            case .square: 1
            case .landscape: 16.0 / 9.0
            }
        }
        public var name: String {
            switch self {
            case .portrait: "Portrait"
            case .square: "Square"
            case .landscape: "Landscape"
            }
        }
    }
    public var style: Style = .cutout
    /// Shape of the glass tile; the camera picture is centre-cropped to it.
    public var tile: Tile = .portrait

    public init(style: Style = .cutout, tile: Tile = .portrait) {
        self.style = style
        self.tile = tile
    }

    /// Whether person segmentation is needed at all.
    public var needsMask: Bool { style == .cutout }

    // The glass tile's look, shared by the video and the previews. Fractions of the tile height unless noted.
    /// Corner radius.
    public static let cornerRadius: CGFloat = 0.065
    /// Width of the light along the edge.
    public static let edgeWidth: CGFloat = 0.005
    public static let edgeOpacityTop: CGFloat = 0.22
    public static let edgeOpacityBottom: CGFloat = 0.06
    /// Shadow blur sigma, offset downwards and opacity; blur and offset are fractions of the frame height.
    public static let shadowBlur: CGFloat = 0.035
    public static let shadowOffset: CGFloat = 0.018
    public static let shadowOpacity: CGFloat = 0.5
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
public struct Stage: Sendable, Codable {
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

    /// The classic look: a slightly tilted card.
    public static let tilted = Stage()

    /// A straight, padded card with softer corners, sitting on the background.
    public static var card: Stage {
        var s = Stage()
        s.tilt = 0
        s.cardX = 0.5
        s.inset = 0.9
        s.cornerRadius = 0.02
        s.shadowOpacity = 0.45
        s.shadowBlur = 0.04
        s.shadowOffset = 0.015
        return s
    }
}

/// How the screen sits in the frame.
public enum ScreenStyle: String, CaseIterable, Sendable, Codable {
    /// Fills the frame; nothing around it.
    case flat
    /// A straight rounded card with padding, over the background.
    case card
    /// A rounded card turned a few degrees, over the background.
    case tilted

    public var name: String {
        switch self {
        case .flat: "Flat"
        case .card: "Card"
        case .tilted: "Tilted"
        }
    }

    /// The stage for this style; nil for flat.
    public func stage(tilt: Double) -> Stage? {
        switch self {
        case .flat: return nil
        case .card: return .card
        case .tilted:
            var s = Stage.tilted
            s.tilt = tilt
            return s
        }
    }
}

/// A whole look at once: how the screen sits, what's behind it, and how you appear.
public struct Scene: Sendable, Equatable {
    public var name: String
    public var screen: ScreenStyle
    public var background: Background
    public var presenter: Presenter

    public static let presets: [Scene] = [
        Scene(name: "Classic", screen: .flat, background: .screen, presenter: Presenter(style: .cutout)),
        Scene(name: "Studio", screen: .tilted, background: .screen, presenter: Presenter(style: .cutout)),
        Scene(name: "Showcase", screen: .card, background: .preset("Meadow"), presenter: Presenter(style: .glass, tile: .portrait)),
        Scene(name: "Desk", screen: .card, background: .preset("Peach"), presenter: Presenter(style: .glass, tile: .landscape)),
        Scene(name: "Night", screen: .card, background: .preset("Graphite"), presenter: Presenter(style: .cutout)),
    ]
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

    /// The layout a recording is made with, saved beside its files when it starts, so a recording that never
    /// became a video (a crash, a failed render) can be finished later exactly as it would have been.
    public static let layoutFileName = "layout.json"

    public static func saveLayout(_ layout: Layout, in dir: URL) throws {
        try JSONEncoder().encode(layout).write(to: dir.appendingPathComponent(layoutFileName))
    }

    public static func loadLayout(from dir: URL) -> Layout? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(layoutFileName)) else { return nil }
        return try? JSONDecoder().decode(Layout.self, from: data)
    }

    private static let folderName: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return fmt
    }()

    /// When the recording in a folder made by `makeFolder` started.
    public static func startedAt(folder: URL) -> Date? {
        folderName.date(from: folder.lastPathComponent)
    }

    public static func makeFolder(in base: URL = defaultBase) throws -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = base.appendingPathComponent(fmt.string(from: Date()))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
