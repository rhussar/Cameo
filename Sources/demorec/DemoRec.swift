import ArgumentParser
import AVFoundation
import DemoRecKit
import Foundation
import ScreenCaptureKit

@main
struct DemoRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demorec",
        abstract: "Record your screen and webcam, then composite a background-removed cutout of you over the screen recording.",
        subcommands: [Devices.self, Record.self, Composite.self]
    )
}

struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List displays, cameras and microphones.")

    func run() async throws {
        print("Displays:")
        do {
            for d in try await ScreenRecorder.displays() {
                print("  \(d.displayID)  \(d.width)x\(d.height) pt\(CGDisplayIsMain(d.displayID) != 0 ? "  (main)" : "")")
            }
        } catch {
            print("  unavailable: \(error.localizedDescription)")
            print("  -> allow Screen Recording for your terminal app in System Settings > Privacy & Security > Screen & System Audio Recording")
        }
        print("Cameras:")
        for c in CameraRecorder.cameras() { print("  \(c.localizedName)") }
        print("Microphones:")
        for m in CameraRecorder.microphones() { print("  \(m.localizedName)\(m == AVCaptureDevice.default(for: .audio) ? "  (default)" : "")") }
    }
}

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record screen.mov and camera.mov into a new session folder. Ctrl-C stops.")

    @Option(help: "Substring of the camera name to use.") var camera: String = "Dell"
    @Option(help: "Display ID from `demorec devices`. Default: main display.") var display: UInt32?
    @Option(help: "Frames per second for both recordings.") var fps: Int = 30
    @Option(help: "Folder that session folders are created in.") var out: String = "~/Movies/DemoRec"

    func run() async throws {
        let dir = try Session.makeFolder(in: URL(fileURLWithPath: NSString(string: out).expandingTildeInPath))

        do {
            try await CameraRecorder.requestAccess()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let t0 = SharedClock.now()
        let cam = CameraRecorder(url: dir.appendingPathComponent("camera.mov"), fps: fps, startTime: t0)
        let screen = ScreenRecorder(url: dir.appendingPathComponent("screen.mov"), fps: fps, startTime: t0)
        try cam.start(cameraName: camera)
        try await screen.start(displayID: display.map { CGDirectDisplayID($0) })
        let cursor = CursorRecorder(startTime: t0, target: display.map { .display(CGDirectDisplayID($0)) })
        cursor.start()
        print("screen: \(Int(screen.pixelSize.width))x\(Int(screen.pixelSize.height)) px")
        print("\nRecording to \(dir.path)\nPress Ctrl-C to stop.\n")

        await waitForInterrupt()

        print("\nStopping…")
        let track = cursor.stop()
        try await screen.stop()
        try await cam.stop()
        try track.save(to: dir)
        print("cursor: \(track.samples.count) samples, \(track.clicks.count) clicks")
        print("screen frames: \(screen.frameCount), camera frames: \(cam.frameCount)")
        print("Done. Next:\n  demorec composite \"\(dir.path)\"")
    }
}

struct Composite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Cut you out of camera.mov and overlay it on screen.mov, producing final.mp4.")

    @Argument(help: "Session folder containing screen.mov and camera.mov.") var session: String
    @Option(help: "Corner for the cutout: bottom-right, bottom-left, top-right, top-left.") var corner: Corner = .bottomRight
    @Option(help: "Cutout height as a fraction of the screen height.") var scale: Double = 0.35
    @Option(help: "Distance from the edges, in output pixels.") var margin: Double = 24
    @Option(help: "Edge softness (blur sigma). 0 = hard edge.") var feather: Double = 2
    @Flag(help: "Mirror the camera horizontally.") var mirror = false
    @Flag(name: .customLong("no-mask"), help: "Skip person segmentation and overlay the full camera frame.") var noMask = false
    @Option(help: "Segmentation quality: fast, balanced, accurate.") var quality: MaskQuality = .balanced
    @Option(help: "Output frame rate.") var fps: Int = 30
    @Option(name: .customLong("output-height"), help: "Downscale the output to this height (keeps aspect). Default: native screen size.") var outputHeight: Int?
    @Option(help: "Output file. Default: final.mp4 in the session folder.") var output: String?
    @Option(help: "Frame size preset: \(OutputFormat.allCases.map(\.rawValue).joined(separator: ", ")).") var format: OutputFormat = .original
    @Option(help: "How much the screen zooms on its own: \(ZoomStrength.allCases.map(\.rawValue).joined(separator: ", ")). Spots marked with the hotkey zoom at every strength.") var zoom: ZoomStrength = .subtle
    @Flag(name: .customLong("no-auto-zoom"), help: "Same as --zoom off.") var noAutoZoom = false
    @Flag(name: .customLong("no-zoom"), help: "Never zoom, ignoring cursor.json.") var noZoom = false
    @Option(name: .customLong("zoom-level"), help: "How far zooms go in, e.g. 2 = twice as close. Default: set by --zoom (1.4 to 1.8).") var zoomLevel: Double?
    @Option(help: "Show only part of the screen: x,y,width,height as fractions of it from the top-left, e.g. 0.25,0,0.5,1.") var crop: String?
    @Option(help: "Look preset for you: \(Look.presets.map { $0.name.lowercased() }.joined(separator: ", ")).") var look: String = "natural"

    @Option(help: "Whole scene at once: \(Scene.presets.map { $0.name.lowercased() }.joined(separator: ", ")). The options below override its parts.") var scene: String?
    @Option(help: "Behind the screen card: screen (a blurred copy of it), a wallpaper (\(Wallpaper.all.map { $0.name.lowercased().replacingOccurrences(of: " ", with: "-") }.joined(separator: ", "))), a colour like \"#5a6a80\", or the path of a picture.") var background: String?
    @Option(name: .customLong("background-blur"), help: "Blur for a background picture, as a fraction of the frame height. 0 = sharp.") var backgroundBlur: Double = 0.012
    @Option(help: "Grain on a colour background, 0 (smooth) to 0.12 (grainy).") var texture: Double = 0.03
    @Option(help: "How you appear: cutout, glass.") var presenter: Presenter.Style?
    @Option(help: "Glass tile shape: portrait, square, landscape.") var tile: Presenter.Tile?
    @Flag(help: "Straight padded card (no tilt) over the background.") var card = false
    @Flag(help: "Flat layout: full-frame screen with no backdrop, card or tilt.") var flat = false
    @Option(help: "Card height as a fraction of the frame height.") var inset: Double = 0.88
    @Option(name: .customLong("card-x"), help: "Horizontal position of the card centre, 0-1.") var cardX: Double = 0.47
    @Option(help: "Card tilt in degrees; positive brings the left edge closer.") var tilt: Double = 4
    @Option(help: "Card corner radius as a fraction of the frame height.") var radius: Double = 0.012
    @Option(name: .customLong("bg-blur"), help: "Backdrop blur as a fraction of the frame height.") var bgBlur: Double = 0.03
    @Option(name: .customLong("bg-zoom"), help: "Backdrop zoom factor.") var bgZoom: Double = 1.2
    @Option(name: .customLong("bg-dim"), help: "Backdrop darkening, 0-1.") var bgDim: Double = 0.35
    @Option(help: "Drop shadow opacity, 0-1.") var shadow: Double = 0.6

    /// "#5a6a80" or "5a6a80" as sRGB 0...1.
    static func hexColor(_ s: String) -> (Double, Double, Double)? {
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
    }

    func run() async throws {
        let dir = URL(fileURLWithPath: NSString(string: session).expandingTildeInPath)
        let screenURL = dir.appendingPathComponent("screen.mov")
        let cameraURL = dir.appendingPathComponent("camera.mov")
        for u in [screenURL, cameraURL] where !FileManager.default.fileExists(atPath: u.path) {
            throw DemoRecError("missing \(u.lastPathComponent) in \(dir.path)")
        }
        let outURL = output.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? dir.appendingPathComponent("final.mp4")
        var layout = Layout(corner: corner, scale: scale, margin: margin, feather: feather, mirror: mirror)
        layout.canvas = format.size
        guard let preset = Look.presets.first(where: { $0.name.lowercased() == look.lowercased() }) else {
            throw DemoRecError("unknown look \"\(look)\"")
        }
        layout.look = preset.look
        if let crop {
            let v = crop.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 4, v[2] > 0, v[3] > 0 else { throw DemoRecError("--crop needs x,y,width,height, e.g. 0.25,0,0.5,1") }
            layout.crop = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        var screenStyle: ScreenStyle = flat ? .flat : card ? .card : .tilted
        if let scene {
            guard let s = Scene.presets.first(where: { $0.name.lowercased() == scene.lowercased() }) else {
                throw DemoRecError("unknown scene \"\(scene)\"")
            }
            if !flat, !card { screenStyle = s.screen }
            layout.background = s.background
            layout.presenter = s.presenter
        }
        if let background {
            if background.lowercased() == "screen" {
                layout.background = .screen
            } else if let w = Wallpaper.named(background) {
                layout.background = .preset(w.name)
            } else if let rgb = Self.hexColor(background) {
                layout.background = .color(r: rgb.0, g: rgb.1, b: rgb.2, texture: min(max(texture, 0), 0.12))
            } else {
                let path = NSString(string: background).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else { throw DemoRecError("no such background wallpaper, colour or picture: \(background)") }
                layout.background = .image(path: path, blur: backgroundBlur)
            }
        }
        if let presenter { layout.presenter.style = presenter }
        if let tile { layout.presenter.tile = tile }
        switch screenStyle {
        case .flat: break
        case .card: layout.stage = .card
        case .tilted:
            var stage = Stage()
            stage.inset = inset
            stage.cardX = cardX
            stage.tilt = tilt
            stage.cornerRadius = radius
            stage.backgroundBlur = bgBlur
            stage.backgroundZoom = bgZoom
            stage.backgroundDim = bgDim
            stage.shadowOpacity = shadow
            layout.stage = stage
        }
        let cursor = noZoom ? nil : CursorTrack.load(from: dir)
        let transcoder = Transcoder(layout: layout, fps: fps, outputHeight: outputHeight, quality: quality, maskEnabled: !noMask,
                                    cursor: cursor, zoom: ZoomSettings(strength: noAutoZoom ? .off : zoom, level: zoomLevel))
        try await transcoder.run(screenURL: screenURL, cameraURL: cameraURL, outputURL: outURL)
        print("Wrote \(outURL.path)")
    }
}

private var interruptSource: DispatchSourceSignal?

func waitForInterrupt() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "demorec.signal"))
        src.setEventHandler { cont.resume() }
        src.resume()
        interruptSource = src
    }
}

extension Corner: ExpressibleByArgument {}
extension Presenter.Style: ExpressibleByArgument {}
extension Presenter.Tile: ExpressibleByArgument {}
extension MaskQuality: ExpressibleByArgument {}
extension OutputFormat: ExpressibleByArgument {}
extension ZoomStrength: ExpressibleByArgument {}
