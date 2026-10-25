import AVFoundation
import DemoRecKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(spacing: 14) {
            Preview(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ActionBar(model: model)
        }
        .padding(.horizontal, 20)
        .padding(.top, 36) // room for the window buttons
        .padding(.bottom, 18)
        .frame(minWidth: 640, minHeight: 500)
        .background(WindowConfigurator(closable: !model.isBusy) { model.mainWindow = $0 })
        .onAppear(perform: model.appeared)
    }
}

// MARK: - Action bar

/// Under the preview: notices and the controls, then progress, then what to do with the finished video.
private struct ActionBar: View {
    @Bindable var model: RecorderModel

    var body: some View {
        switch model.phase {
        case .idle, .failed, .countdown, .recording:
            VStack(spacing: 10) {
                if case .failed(let msg, let needsSettings) = model.phase {
                    Notice(text: msg, action: needsSettings ? ("Open Settings", { model.openPrivacySettings() }) : nil)
                }
                if let dir = model.visibleUnfinished.first, model.phase == .idle || isFailed {
                    UnfinishedNotice(model: model, dir: dir)
                }
                ControlBar(model: model)
            }
        case .processing(let p):
            HStack(spacing: 14) {
                ProgressView(value: p).tint(.red)
                Text("Making your video… \(Int(p * 100))%")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 190, alignment: .leading)
            }
            .frame(height: 34)
        case .done:
            HStack(spacing: 10) {
                Button("Record Another", action: model.reset).buttonStyle(.link)
                Spacer()
                RecordingsButton(model: model)
                Button(action: model.deleteFinished) {
                    Image(systemName: "trash")
                }
                .controlSize(.large)
                .help("Delete this video")
                .accessibilityLabel("Delete this video")
                PrimaryButton(title: "Show in Finder", systemImage: "folder", tint: .secondary, action: model.revealInFinder)
                PrimaryButton(title: "Play", systemImage: "play.fill", tint: .accentColor, action: model.play)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }
}

// MARK: - Preview

/// A live miniature of the final video: what you're recording, with you in it.
/// Drag yourself anywhere; you line up with the edges and the middle when you're close to them.
private struct Preview: View {
    @Bindable var model: RecorderModel
    private var hovering: Bool { model.previewHovering }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background(in: geo.size)

                switch model.phase {
                case .done:
                    if let thumb = model.thumbnail {
                        Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                    }
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.white, .green)
                        .shadow(radius: 8)
                case .processing, .recording:
                    Rectangle().fill(.black.opacity(0.55))
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.8))
                        .symbolEffect(.pulse)
                default:
                    if model.cropping {
                        CropBox(model: model, size: geo.size)
                    } else {
                        setupOverlay(in: geo.size)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .contentShape(Rectangle())
            .onHover { model.previewHovering = $0 }
        }
        .aspectRatio(model.screenAspect, contentMode: .fit)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .overlay(alignment: .top) {
            if model.isSetup {
                Text(model.cropping ? "Drag the box to move it · drag a corner to resize it" : "Drag yourself anywhere · you line up with the edges and the middle when you're close")
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 10)
                    .opacity(hovering || model.cropping ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if model.cropping { CropControls(model: model).padding(.bottom, 12) }
        }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .animation(.spring(duration: 0.3), value: model.phase)
    }

    /// You and the middle guide, plus the countdown.
    @ViewBuilder private func setupOverlay(in size: CGSize) -> some View {
        if model.snappedToMiddle {
            Path { p in
                p.move(to: CGPoint(x: size.width / 2, y: 0))
                p.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            }
            .stroke(.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        }
        presenter(in: size)
        if case .countdown(let n) = model.phase {
            Text("\(n)")
                .font(.system(size: 120, weight: .semibold, design: .rounded))
                .foregroundStyle(.white).shadow(radius: 12)
                .contentTransition(.numericText(countsDown: true))
        }
    }

    @ViewBuilder private func background(in size: CGSize) -> some View {
        if let screen = model.screenImage {
            SurfaceView(frame: screen)
                .frame(width: size.width, height: size.height)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            if !model.screenAccess, model.isSetup {
                VStack(spacing: 10) {
                    Image(systemName: "display").font(.system(size: 30, weight: .light))
                    Text("Allow screen access to see what you'll record")
                    Button("Allow Screen Access", action: model.requestScreenAccess)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    @ViewBuilder private func presenter(in size: CGSize) -> some View {
        let h = size.height * model.size
        let margin = size.height * RecorderModel.margin(for: model.corner)
        if !model.cameraOn {
            EmptyView() // camera off: you're not in the video
        } else if model.cameraDenied {
            VStack(spacing: 8) {
                Text("Cameo needs your camera").foregroundStyle(.white)
                Button("Open Settings") { model.openPrivacySettings(camera: true) }
            }
            .padding(12)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        } else if let img = model.previewImage {
            let w = PresenterTile.width(for: h, image: img, presenter: model.presenter)
            let center = presenterCenter(w: w, h: h, margin: margin, in: size)
            PresenterTile(image: img, presenter: model.presenter, width: w, height: h, presenterScale: model.size)
                .contentShape(Rectangle())
                .pointerStyle(model.isSetup ? .grabIdle : .default)
                .gesture(drag(w: w, h: h, center: center, in: size))
                .position(center)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: h * 0.6)).foregroundStyle(.white.opacity(0.25))
                .frame(width: h, height: h)
                .position(presenterCenter(w: h, h: h, margin: margin, in: size))
        }
    }

    /// Where you are in the preview: your dragged spot, or your corner.
    private func presenterCenter(w: CGFloat, h: CGFloat, margin: CGFloat, in size: CGSize) -> CGPoint {
        guard let p = model.position else { return position(w: w, h: h, margin: margin, in: size) }
        // Same maths as Compositor.place, flipped to SwiftUI's top-left origin.
        let bottom = p.y * max(size.height - h, 0)
        return CGPoint(x: p.x * size.width, y: size.height - bottom - h / 2)
    }

    /// Moves you with the pointer. Within a few points of a side, the middle, or the top or bottom you snap flush to it;
    /// any further and you stay exactly where you put yourself.
    private func drag(w: CGFloat, h: CGFloat, center: CGPoint, in size: CGSize) -> some Gesture {
        // Measured in window coordinates: in the default local space the frame moves with you, so each move
        // shifts the next reading and the cutout jitters back and forth.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { g in
                guard model.isSetup else { return }
                if model.dragOrigin == nil { model.dragOrigin = center }
                guard let start = model.dragOrigin else { return }
                let W = size.width, H = size.height
                let snap: CGFloat = 6
                var cx = start.x + g.translation.width
                var cy = start.y + g.translation.height
                var middle = false
                if abs(cx - w / 2) < snap { cx = w / 2 }
                else if abs(cx - (W - w / 2)) < snap { cx = W - w / 2 }
                else if abs(cx - W / 2) < snap { cx = W / 2; middle = true }
                cx = min(max(cx, 0), W)
                if abs(cy - h / 2) < snap { cy = h / 2 }
                else if abs(cy - (H - h / 2)) < snap { cy = H - h / 2 }
                let py = (H - cy - h / 2) / max(H - h, 1) // 0 = flush with the bottom
                model.snappedToMiddle = middle
                model.position = CGPoint(x: cx / W, y: min(max(py, 0), 1))
            }
            .onEnded { _ in
                model.dragOrigin = nil
                model.snappedToMiddle = false
            }
    }

    private func position(corner: Corner? = nil, w: CGFloat, h: CGFloat, margin: CGFloat, in size: CGSize) -> CGPoint {
        switch corner ?? model.corner {
        case .bottomRight: CGPoint(x: size.width - margin - w / 2, y: size.height - margin - h / 2)
        case .bottomLeft: CGPoint(x: margin + w / 2, y: size.height - margin - h / 2)
        case .topRight: CGPoint(x: size.width - margin - w / 2, y: margin + h / 2)
        case .topLeft: CGPoint(x: margin + w / 2, y: margin + h / 2)
        }
    }
}

// MARK: - Crop

/// The crop box over the whole screen: drag inside it to move it, drag a corner to resize it.
/// When the video has a fixed shape (say YouTube 16:9) the box keeps that shape, so the crop fills the video exactly.
private struct CropBox: View {
    @Bindable var model: RecorderModel
    let size: CGSize

    private static let corners: [(sx: CGFloat, sy: CGFloat, resize: FrameResizePosition)] = [
        (0, 0, .topLeading), (1, 0, .topTrailing), (0, 1, .bottomLeading), (1, 1, .bottomTrailing),
    ]

    var body: some View {
        let c = model.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let box = CGRect(x: c.minX * size.width, y: c.minY * size.height, width: c.width * size.width, height: c.height * size.height)
        ZStack {
            // Dim what's left out.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(box)
            }
            .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            thirds(in: box)
            Rectangle()
                .strokeBorder(.white, lineWidth: 2)
                .contentShape(Rectangle())
                .frame(width: box.width, height: box.height)
                .pointerStyle(.grabIdle)
                .gesture(move(c))
                .position(x: box.midX, y: box.midY)
            ForEach(Self.corners.indices, id: \.self) { i in
                let k = Self.corners[i]
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: k.resize))
                    .gesture(resize(c, sx: k.sx, sy: k.sy))
                    .position(x: box.minX + k.sx * box.width, y: box.minY + k.sy * box.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func thirds(in box: CGRect) -> some View {
        Path { p in
            for f in [1.0 / 3, 2.0 / 3] {
                p.move(to: CGPoint(x: box.minX + box.width * f, y: box.minY))
                p.addLine(to: CGPoint(x: box.minX + box.width * f, y: box.maxY))
                p.move(to: CGPoint(x: box.minX, y: box.minY + box.height * f))
                p.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * f))
            }
        }
        .stroke(.white.opacity(0.3), lineWidth: 1)
        .allowsHitTesting(false)
    }

    /// Slides the box, snapping to the screen's edges and centre.
    private func move(_ current: CGRect) -> some Gesture {
        // Window coordinates, like dragging yourself: the box moves under the pointer, so its own space would jitter.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                let s = model.cropDragStart ?? current
                model.cropDragStart = s
                func place(_ v: CGFloat, length: CGFloat) -> CGFloat {
                    let v = min(max(v, 0), 1 - length), snap: CGFloat = 0.015
                    if v < snap { return 0 }
                    if v > 1 - length - snap { return 1 - length }
                    if abs(v + length / 2 - 0.5) < snap { return 0.5 - length / 2 }
                    return v
                }
                let x = place(s.minX + g.translation.width / size.width, length: s.width)
                let y = place(s.minY + g.translation.height / size.height, length: s.height)
                model.crop = CGRect(x: x, y: y, width: s.width, height: s.height)
            }
            .onEnded { _ in model.cropDragStart = nil }
    }

    /// Drags corner (sx, sy) (0 = left/top, 1 = right/bottom) with the opposite corner pinned.
    private func resize(_ current: CGRect, sx: CGFloat, sy: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                let s = model.cropDragStart ?? current
                model.cropDragStart = s
                let ax = sx == 0 ? s.maxX : s.minX, ay = sy == 0 ? s.maxY : s.minY
                let px = (sx == 0 ? s.minX : s.maxX) + g.translation.width / size.width
                let py = (sy == 0 ? s.minY : s.maxY) + g.translation.height / size.height
                let roomX = sx == 0 ? ax : 1 - ax, roomY = sy == 0 ? ay : 1 - ay
                let least: CGFloat = 0.08
                var w = min(max(sx == 0 ? ax - px : px - ax, least), roomX)
                var h = min(max(sy == 0 ? ay - py : py - ay, least), roomY)
                if let k = model.cropRatio {
                    // Follow the direction you're mostly dragging, keep the shape, then fit the room.
                    if abs(g.translation.width) >= abs(g.translation.height) { h = w / k } else { w = h * k }
                    if w < least { w = least; h = w / k }
                    if h < least { h = least; w = h * k }
                    if w > roomX { w = roomX; h = w / k }
                    if h > roomY { h = roomY; w = h * k }
                }
                model.crop = CGRect(x: sx == 0 ? ax - w : ax, y: sy == 0 ? ay - h : ay, width: w, height: h)
            }
            .onEnded { _ in model.cropDragStart = nil }
    }
}

private struct CropControls: View {
    @Bindable var model: RecorderModel

    var body: some View {
        HStack(spacing: 12) {
            if model.videoCropRatio == nil {
                Text("Any shape: the video takes the box's shape")
                    .font(.callout).foregroundStyle(.white.opacity(0.85))
            } else {
                Toggle(isOn: $model.cropFillsVideo) {
                    Label("Fill the \(model.format.name) video", systemImage: model.cropFillsVideo ? "lock" : "lock.open")
                }
                .toggleStyle(.button)
                .help(model.cropFillsVideo
                      ? "The box keeps the video's shape and fills it edge to edge"
                      : "Any shape: what's in the box sits inside the video, over the background")
            }
            Button("Whole Screen", action: model.clearCrop)
            Button("Done") { model.cropping = false }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.regular)
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 7)
        .background(.black.opacity(0.6), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Bits

private struct Notice: View {
    let text: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A recording that never became a video (say, the Mac stopped while making it): its files are safe, one click finishes it.
private struct UnfinishedNotice: View {
    @Bindable var model: RecorderModel
    let dir: URL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "film.stack").foregroundStyle(.tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Show Files") { model.revealUnfinished(dir) }.controlSize(.small)
            Button("Make the Video") { model.finish(dir) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { model.hideUnfinished(dir) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            .help("Hide this notice. The recording's files stay where they are.")
            .accessibilityLabel("Hide")
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var text: String {
        let more = model.visibleUnfinished.count - 1
        let when = Session.startedAt(folder: dir).map { "from \($0.formatted(date: .abbreviated, time: .shortened)) " } ?? ""
        return "Your recording \(when)wasn't made into a video yet. It's safe."
            + (more > 0 ? " (\(more) more after this one.)" : "")
    }
}

/// Hands the hosting NSWindow to the model and sets a few window traits SwiftUI doesn't expose.
private struct WindowConfigurator: NSViewRepresentable {
    /// Off while recording or making the video, so the window can't be closed mid-way.
    let closable: Bool
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.closeButton)?.isEnabled = closable
            onWindow(window)
        }
    }
}
