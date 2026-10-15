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
        print("screen: \(Int(screen.pixelSize.width))x\(Int(screen.pixelSize.height)) px")
        print("\nRecording to \(dir.path)\nPress Ctrl-C to stop.\n")

        await waitForInterrupt()

        print("\nStopping…")
        try await screen.stop()
        try await cam.stop()
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
    @Option(help: "Segmentation quality: fast, balanced, accurate.") var quality: MaskQuality = .accurate
    @Option(help: "Output frame rate.") var fps: Int = 30
    @Option(name: .customLong("output-height"), help: "Downscale the output to this height (keeps aspect). Default: native screen size.") var outputHeight: Int?
    @Option(help: "Output file. Default: final.mp4 in the session folder.") var output: String?

    func run() async throws {
        let dir = URL(fileURLWithPath: NSString(string: session).expandingTildeInPath)
        let screenURL = dir.appendingPathComponent("screen.mov")
        let cameraURL = dir.appendingPathComponent("camera.mov")
        for u in [screenURL, cameraURL] where !FileManager.default.fileExists(atPath: u.path) {
            throw DemoRecError("missing \(u.lastPathComponent) in \(dir.path)")
        }
        let outURL = output.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? dir.appendingPathComponent("final.mp4")
        let layout = Layout(corner: corner, scale: scale, margin: margin, feather: feather, mirror: mirror)
        let transcoder = Transcoder(layout: layout, fps: fps, outputHeight: outputHeight, quality: quality, maskEnabled: !noMask)
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
extension MaskQuality: ExpressibleByArgument {}
