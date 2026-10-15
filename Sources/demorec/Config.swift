import Foundation
import ArgumentParser

enum Corner: String, CaseIterable, ExpressibleByArgument {
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
    case topRight = "top-right"
    case topLeft = "top-left"
}

enum MaskQuality: String, CaseIterable, ExpressibleByArgument {
    case fast, balanced, accurate
}

/// How the presenter cutout is placed over the screen recording.
struct Layout {
    var corner: Corner = .bottomRight
    /// Cutout height as a fraction of the screen height.
    var scale: Double = 0.35
    /// Distance from the two nearest edges, in output pixels.
    var margin: Double = 24
    /// Gaussian blur sigma applied to the mask edge. 0 disables.
    var feather: Double = 2
    /// Flip the camera horizontally (selfie-style).
    var mirror: Bool = false
}
