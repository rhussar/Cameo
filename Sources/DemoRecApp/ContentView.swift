import AVFoundation
import DemoRecKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: RecorderModel

    var body: some View {
        let wide = model.windowWidth >= 1400
        VStack(spacing: wide ? 18 : 14) {
            Preview(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            BottomBar(model: model)
                .controlSize(wide ? .large : .regular)
        }
        .padding(.horizontal, wide ? 28 : 20)
        .padding(.top, 36) // room for the window buttons
        .padding(.bottom, wide ? 24 : 18)
        .frame(minWidth: 640, minHeight: 500)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.windowWidth = $0 }
        .background(WindowConfigurator(closable: !model.isBusy) { model.mainWindow = $0 })
        .onAppear(perform: model.appeared)
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @Bindable var model: RecorderModel

    var body: some View {
        switch model.phase {
        case .idle, .failed, .countdown, .recording:
            VStack(spacing: 10) {
                if case .failed(let msg, let needsSettings) = model.phase {
                    Notice(text: msg, action: needsSettings ? ("Open Settings", { model.openPrivacySettings() }) : nil)
                }
                // One row when it fits; otherwise "what" on top and "how it looks" + Record below.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: spacing) {
                        sources
                        adjustments
                        Spacer(minLength: 8)
                        primary
                    }
                    VStack(spacing: 10) {
                        HStack(spacing: spacing) {
                            sources
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: spacing) {
                            adjustments
                            Spacer(minLength: 8)
                            primary
                        }
                    }
                }
                .disabled(!model.isSetup)
            }
        case .processing(let p):
            processing(p)
        case .done:
            done
        }
    }

    private var wide: Bool { model.windowWidth >= 1400 }
    private var spacing: CGFloat { wide ? 20 : 14 }

    /// What you're recording, what shape the video is, and which camera.
    @ViewBuilder private var sources: some View {
        SourcePicker(model: model)
        FormatPicker(model: model)
        CameraPicker(model: model)
        MicrophonePicker(model: model)
    }

    /// How it looks.
    @ViewBuilder private var adjustments: some View {
        LookButton(model: model)
        SizeSlider(size: $model.size, width: wide ? 150 : 100)
        Toggle(isOn: $model.mirror) {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
        .toggleStyle(.button)
        .help("Mirror camera")
        Toggle(isOn: $model.styled) {
            Image(systemName: "rectangle.on.rectangle.angled")
        }
        .toggleStyle(.button)
        .help("Styled: screen as a tilted card over a blurred backdrop")
        if model.styled {
            TiltSlider(tilt: $model.tilt, width: wide ? 130 : 90)
        }
    }

    @ViewBuilder private var primary: some View {
        if case .countdown = model.phase {
            PrimaryButton(title: "Cancel", systemImage: nil, tint: .secondary, wide: wide, action: model.cancelCountdown)
                .keyboardShortcut(.cancelAction)
        } else {
            PrimaryButton(title: "Start Recording", systemImage: "record.circle", tint: .red, wide: wide, action: model.record)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func processing(_ p: Double) -> some View {
            HStack(spacing: 14) {
                ProgressView(value: p).tint(.red)
                Text("Making your video… \(Int(p * 100))%")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 190, alignment: .leading)
            }
            .frame(height: 34)
    }

    private var done: some View {
        HStack(spacing: 10) {
            Button("Record another", action: model.reset).buttonStyle(.link)
            Spacer()
            PrimaryButton(title: "Show in Finder", systemImage: "folder", tint: .secondary, wide: wide, action: model.revealInFinder)
            PrimaryButton(title: "Play", systemImage: "play.fill", tint: .accentColor, wide: wide, action: model.play)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The video's frame size, grouped by where it's going.
private struct FormatPicker: View {
    @Bindable var model: RecorderModel

    var body: some View {
        Menu {
            item(.original)
            ForEach(["YouTube", "X", "LinkedIn"], id: \.self) { platform in
                Section(platform) {
                    ForEach(OutputFormat.allCases.filter { $0.platform == platform }, id: \.self) { item($0) }
                }
            }
        } label: {
            Label(label, systemImage: "aspectratio")
        }
        .menuStyle(.button)
        .fixedSize()
        .help(sizeHelp)
    }

    private var label: String {
        let f = model.format
        return f == .original ? "Original size" : "\(f.platform) \(f.name)"
    }

    private var sizeHelp: String {
        guard let s = model.format.size else { return "Video size: same as what you record" }
        return "Video size: \(Int(s.width)) × \(Int(s.height))"
    }

    private func item(_ f: OutputFormat) -> some View {
        Button {
            model.format = f
        } label: {
            Image(systemName: f == model.format ? "checkmark" : "")
            Text(f.name)
            Text(f.note)
        }
    }
}

/// Colour presets and sliders for how you look.
private struct LookButton: View {
    @Bindable var model: RecorderModel

    var body: some View {
        Button {
            model.lookOpen.toggle()
        } label: {
            Label(model.lookName, systemImage: "camera.filters")
        }
        .help("Adjust how you look")
        .popover(isPresented: $model.lookOpen, arrowEdge: .top) {
            LookPanel(model: model)
        }
    }
}

private struct LookPanel: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your look").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Look.presets, id: \.name) { preset in
                    let selected = preset.look == model.look
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { model.look = preset.look }
                    } label: {
                        Text(preset.name).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(selected ? .accentColor : nil)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: selected ? 1.5 : 0))
                }
            }
            Divider()
            LookSlider(title: "Brightness", icon: "sun.max", value: $model.look.brightness, range: -1...1)
            LookSlider(title: "Contrast", icon: "circle.lefthalf.filled", value: $model.look.contrast, range: 0.5...1.5)
            LookSlider(title: "Colour", icon: "paintpalette", value: $model.look.saturation, range: 0...2)
            LookSlider(title: "Warmth", icon: "thermometer.medium", value: $model.look.warmth, range: -1...1)
            HStack {
                Text("Shows live in the preview").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { model.look = Look() }
                    .disabled(model.look.isNeutral)
            }
        }
        .padding(16)
        .frame(width: 320)
        .controlSize(.regular)
    }
}

private struct LookSlider: View {
    let title: String
    let icon: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon)
                .frame(width: 104, alignment: .leading)
            Slider(value: $value, in: range)
        }
    }
}

/// "What am I recording?" — a whole screen, or one window (for a browser, that's its current tab).
private struct SourcePicker: View {
    @Bindable var model: RecorderModel

    var body: some View {
        Menu {
            Section("Screens") {
                ForEach(model.displaySources) { s in
                    item(s, icon: "display")
                }
            }
            if !model.windowSources.isEmpty {
                Section("Windows") {
                    ForEach(model.windowSources) { s in
                        item(s, icon: "macwindow")
                    }
                }
            }
        } label: {
            Label(label, systemImage: isWindow ? "macwindow" : "display")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Choose what to record")
    }

    private var isWindow: Bool {
        if case .window = model.target { return true }
        return false
    }

    private var label: String {
        guard let s = model.selectedSource else { return "Choose screen" }
        let text = s.subtitle.isEmpty || !isWindow ? s.title : "\(s.title) – \(s.subtitle)"
        return text.count > 34 ? String(text.prefix(33)) + "…" : text
    }

    private func item(_ s: Source, icon: String) -> some View {
        Button {
            model.target = s.target
        } label: {
            let name = s.subtitle.isEmpty ? s.title : "\(s.title) – \(s.subtitle)"
            Label(name, systemImage: s.target == model.target ? "checkmark" : icon)
        }
    }
}

private struct CameraPicker: View {
    @Bindable var model: RecorderModel

    var body: some View {
        Picker(selection: $model.cameraChoice) {
            ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
        } label: {
            Image(systemName: "camera")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Camera. An iPhone nearby shows up here too (Continuity Camera).")
    }
}

private struct MicrophonePicker: View {
    @Bindable var model: RecorderModel

    var body: some View {
        Picker(selection: $model.microphoneChoice) {
            ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
        } label: {
            Image(systemName: "mic")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Microphone")
    }
}

private struct SizeSlider: View {
    @Binding var size: Double
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.fill").font(.system(size: 9))
            Slider(value: $size, in: 0.2...0.6).frame(width: width)
            Image(systemName: "person.fill").font(.system(size: 14))
        }
        .foregroundStyle(.secondary)
        .help("Your size")
    }
}

/// Shown while Styled is on.
private struct TiltSlider: View {
    @Binding var tilt: Double
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rotate.3d")
            Slider(value: $tilt, in: -15...15).frame(width: width)
        }
        .foregroundStyle(.secondary)
        .help("Tilt: \(Int(tilt.rounded()))°")
    }
}

// MARK: - Preview

/// A live miniature of the final video: what you're recording, with you in it.
/// Drag yourself anywhere (you snap to the edges and the middle), or click a corner to snap there.
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
                    if hovering, model.dragOrigin == nil { cornerTargets(in: geo.size) }
                    if model.snappedToMiddle {
                        Path { p in
                            p.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                            p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                        }
                        .stroke(.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    }
                    presenter(in: geo.size)
                    if case .countdown(let n) = model.phase {
                        Text("\(n)")
                            .font(.system(size: 120, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white).shadow(radius: 12)
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .contentShape(Rectangle())
            .onHover { model.previewHovering = $0 }
            .onTapGesture { loc in
                guard model.isSetup else { return }
                let left = loc.x < geo.size.width / 2
                let top = loc.y < geo.size.height / 2
                withAnimation(.spring(duration: 0.35)) {
                    model.corner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
                    model.position = nil
                }
            }
        }
        .aspectRatio(model.screenAspect, contentMode: .fit)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .overlay(alignment: .top) {
            if model.isSetup {
                Text("Drag yourself anywhere · click a corner to snap there")
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 10)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .animation(.spring(duration: 0.3), value: model.phase)
    }

    @ViewBuilder private func background(in size: CGSize) -> some View {
        if let screen = model.screenImage {
            Image(decorative: screen, scale: 1).resizable().interpolation(.high)
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
        if model.cameraDenied {
            VStack(spacing: 8) {
                Text("DemoRec needs your camera").foregroundStyle(.white)
                Button("Open Settings") { model.openPrivacySettings(camera: true) }
            }
            .padding(12)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        } else if let img = model.previewImage {
            let w = h * CGFloat(img.width) / CGFloat(img.height)
            let center = presenterCenter(w: w, h: h, margin: margin, in: size)
            Image(decorative: img, scale: 1).resizable()
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .pointerStyle(model.isSetup ? .grabIdle : .default)
                .onTapGesture {} // a click on you isn't a corner pick
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

    /// Moves you with the pointer, snapping flush to the sides, the middle, and the top and bottom edges.
    private func drag(w: CGFloat, h: CGFloat, center: CGPoint, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard model.isSetup else { return }
                if model.dragOrigin == nil { model.dragOrigin = center }
                guard let start = model.dragOrigin else { return }
                let W = size.width, H = size.height
                let snap = 0.02 * W
                var cx = start.x + g.translation.width
                let cy = start.y + g.translation.height
                var middle = false
                if abs(cx - w / 2) < snap { cx = w / 2 }
                else if abs(cx - (W - w / 2)) < snap { cx = W - w / 2 }
                else if abs(cx - W / 2) < snap { cx = W / 2; middle = true }
                cx = min(max(cx, 0), W)
                var py = (H - cy - h / 2) / max(H - h, 1) // 0 = flush with the bottom
                if py < 0.04 { py = 0 } else if py > 0.96 { py = 1 }
                model.snappedToMiddle = middle
                model.position = CGPoint(x: cx / W, y: min(max(py, 0), 1))
            }
            .onEnded { _ in
                model.dragOrigin = nil
                model.snappedToMiddle = false
            }
    }

    private func cornerTargets(in size: CGSize) -> some View {
        ForEach(Corner.allCases, id: \.self) { c in
            let w = size.width * 0.16, h = size.height * 0.16
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(isCurrent(c) ? 0 : 0.18))
                .strokeBorder(.white.opacity(isCurrent(c) ? 0 : 0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: w, height: h)
                .position(position(corner: c, w: w, h: h, margin: size.height * RecorderModel.margin(for: c), in: size))
        }
    }

    private func isCurrent(_ c: Corner) -> Bool { model.position == nil && c == model.corner }

    private func position(corner: Corner? = nil, w: CGFloat, h: CGFloat, margin: CGFloat, in size: CGSize) -> CGPoint {
        switch corner ?? model.corner {
        case .bottomRight: CGPoint(x: size.width - margin - w / 2, y: size.height - margin - h / 2)
        case .bottomLeft: CGPoint(x: margin + w / 2, y: size.height - margin - h / 2)
        case .topRight: CGPoint(x: size.width - margin - w / 2, y: margin + h / 2)
        case .topLeft: CGPoint(x: margin + w / 2, y: margin + h / 2)
        }
    }
}

// MARK: - Bits

private struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    let tint: Color
    var wide = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .font(.system(size: wide ? 16 : 14, weight: .semibold))
            .frame(minWidth: wide ? 190 : 150)
            .padding(.vertical, wide ? 6 : 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(tint)
    }
}

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
