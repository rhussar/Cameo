import DemoRecKit
import SwiftUI

/// You in the previews, drawn the way the video will show you: the cutout as is, or the camera picture in a
/// rounded glass tile over whatever is behind it. The system material stands in for the compositor's frosted rim.
struct PresenterTile: View {
    let image: CGImage
    let presenter: Presenter
    let width: CGFloat
    let height: CGFloat

    /// The tile's width for its height: the picture's own shape for a cutout, the tile shape for glass.
    static func width(for height: CGFloat, image: CGImage, presenter: Presenter) -> CGFloat {
        switch presenter.style {
        case .cutout: height * CGFloat(image.width) / CGFloat(max(image.height, 1))
        case .glass: (height * CGFloat(presenter.tile.aspect)).rounded()
        }
    }

    var body: some View {
        switch presenter.style {
        case .cutout:
            Image(decorative: image, scale: 1).resizable()
                .frame(width: width, height: height)
        case .glass:
            let rim = max(2, (0.018 * height).rounded())
            let radius = 0.075 * height
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: width - 2 * rim, height: height - 2 * rim)
                    .clipShape(RoundedRectangle(cornerRadius: max(radius - rim, 1), style: .continuous))
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom),
                    lineWidth: max(1, 0.004 * height))
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.35), radius: 0.025 * height, y: 0.012 * height)
        }
    }
}

/// A little picture of a background for the scene panel.
struct BackgroundSwatch: View {
    let background: Background

    var body: some View {
        switch background {
        case .screen:
            LinearGradient(colors: [Color(white: 0.35), Color(white: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Image(systemName: "display").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)))
        case .preset(let name):
            if let p = BackgroundPreset.named(name) {
                ZStack {
                    color(p.base)
                    ForEach(Array(p.blobs.enumerated()), id: \.offset) { _, blob in
                        GeometryReader { geo in
                            let r = blob.radius * max(geo.size.width, geo.size.height)
                            RadialGradient(colors: [color(blob.color).opacity(0.95), color(blob.color).opacity(0)],
                                           center: .init(x: blob.x, y: 1 - blob.y), startRadius: 0, endRadius: r)
                        }
                    }
                }
            } else {
                Color.gray
            }
        case .image(let path, _):
            if let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.gray.overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.7)))
            }
        }
    }

    private func color(_ c: BackgroundPreset.RGB) -> Color { Color(red: c.r, green: c.g, blue: c.b) }
}
