import DemoRecKit
import ImageIO
import SwiftUI

/// You in the previews, drawn the way the video will show you: the cutout as is, or the camera picture in a
/// floating pane with soft corners, a hairline of light and a wide shadow, drawn with the same numbers as the video.
struct PresenterTile: View {
    let image: PreviewFrame
    let presenter: Presenter
    let width: CGFloat
    let height: CGFloat
    /// Tile height as a fraction of the frame height (Layout.scale), so the shadow scales with the frame as in the video.
    var presenterScale: CGFloat = 0.35

    /// The tile's width for its height: the picture's own shape for a cutout, the tile shape for glass.
    static func width(for height: CGFloat, image: PreviewFrame, presenter: Presenter) -> CGFloat {
        switch presenter.style {
        case .cutout: height * CGFloat(image.width) / CGFloat(max(image.height, 1))
        case .glass: (height * CGFloat(presenter.tile.aspect)).rounded()
        }
    }

    var body: some View {
        switch presenter.style {
        case .cutout:
            SurfaceView(frame: image)
                .frame(width: width, height: height)
        case .glass:
            let radius = Presenter.cornerRadius * height
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            SurfaceView(frame: image, fill: true)
                .frame(width: width, height: height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(Presenter.edgeOpacityTop), .white.opacity(Presenter.edgeOpacityBottom)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: max(1, Presenter.edgeWidth * height))
                    .blur(radius: max(0.5, Presenter.edgeWidth * height * 0.8)))
                // The shadow is a fraction of the frame; the preview's frame is about height / size tall.
                .shadow(color: .black.opacity(Presenter.shadowOpacity),
                        radius: Presenter.shadowBlur * height / presenterScale, y: Presenter.shadowOffset * height / presenterScale)
        }
    }
}

/// A little picture of a background for the scene panel. Wallpapers are drawn by the same code as the video.
struct BackgroundSwatch: View {
    let background: Background

    var body: some View {
        switch background {
        case .screen:
            LinearGradient(colors: [Color(white: 0.35), Color(white: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Image(systemName: "display").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)))
        case .preset(let name):
            if let img = WallpaperThumbnails.image(name) {
                Image(decorative: img, scale: 1).resizable().scaledToFill()
            } else {
                Color.gray
            }
        case .color(let r, let g, let b, _):
            // Same light from the top left as the video's colour background.
            Color(red: r, green: g, blue: b)
                .overlay(LinearGradient(colors: [.white.opacity(0.10), .black.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .image(let path, _):
            if let img = WallpaperThumbnails.picture(path) {
                Image(decorative: img, scale: 1).resizable().scaledToFill()
            } else {
                Color.gray.overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.7)))
            }
        }
    }
}

/// Small renders of each wallpaper, made once.
@MainActor
enum WallpaperThumbnails {
    private static var cache: [String: CGImage] = [:]

    static func image(_ name: String) -> CGImage? {
        if let img = cache[name] { return img }
        guard let img = Wallpaper.named(name)?.render(width: 192, height: 120) else { return nil }
        cache[name] = img
        return img
    }

    private static var pictures: [String: CGImage] = [:]

    /// A small copy of your background picture. Decoding the full-size file on every redraw stalled the window.
    static func picture(_ path: String) -> CGImage? {
        if let img = pictures[path] { return img }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        pictures[path] = img
        return img
    }
}
