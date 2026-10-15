import AVFoundation
import DemoRecKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(spacing: 14) {
            Stage(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            BottomBar(model: model)
        }
        .padding(.horizontal, 20)
        .padding(.top, 36) // room for the window buttons
        .padding(.bottom, 18)
        .frame(minWidth: 720, minHeight: 500)
        .background(WindowConfigurator { model.mainWindow = $0 })
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
                HStack(spacing: 16) {
                    SourcePicker(model: model)
                    CameraPicker(model: model)
                    SizeSlider(size: $model.size)
                    Toggle(isOn: $model.mirror) {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .toggleStyle(.button)
                    .help("Mirror camera")
                    Spacer(minLength: 8)
                    if case .countdown = model.phase {
                        PrimaryButton(title: "Cancel", systemImage: nil, tint: .secondary, action: model.cancelCountdown)
                            .keyboardShortcut(.cancelAction)
                    } else {
                        PrimaryButton(title: "Start Recording", systemImage: "record.circle", tint: .red, action: model.record)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .disabled(!model.isSetup)
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
                Button("Record another", action: model.reset).buttonStyle(.link)
                Spacer()
                PrimaryButton(title: "Show in Finder", systemImage: "folder", tint: .secondary, action: model.revealInFinder)
                PrimaryButton(title: "Play", systemImage: "play.fill", tint: .accentColor, action: model.play)
                    .keyboardShortcut(.defaultAction)
            }
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
        Picker(selection: $model.cameraID) {
            ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
        } label: {
            Image(systemName: "camera")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Camera")
    }
}

private struct SizeSlider: View {
    @Binding var size: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.fill").font(.system(size: 9))
            Slider(value: $size, in: 0.2...0.6).frame(width: 100)
            Image(systemName: "person.fill").font(.system(size: 14))
        }
        .foregroundStyle(.secondary)
        .help("Your size")
    }
}

// MARK: - Stage

/// A live miniature of the final video: what you're recording, with you in the corner.
/// Click a corner to move yourself.
private struct Stage: View {
    @Bindable var model: RecorderModel
    private var hovering: Bool { model.stageHovering }

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
                    if hovering { cornerTargets(in: geo.size) }
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
            .onHover { model.stageHovering = $0 }
            .onTapGesture { loc in
                guard model.isSetup else { return }
                let left = loc.x < geo.size.width / 2
                let top = loc.y < geo.size.height / 2
                withAnimation(.spring(duration: 0.35)) {
                    model.corner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
                }
            }
        }
        .aspectRatio(model.screenAspect, contentMode: .fit)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .overlay(alignment: .top) {
            if model.isSetup {
                Text("Click a corner to move yourself")
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
        let margin = size.height * 0.025
        if model.cameraDenied {
            VStack(spacing: 8) {
                Text("DemoRec needs your camera").foregroundStyle(.white)
                Button("Open Settings") { model.openPrivacySettings(camera: true) }
            }
            .padding(12)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        } else if let img = model.previewImage {
            let w = h * CGFloat(img.width) / CGFloat(img.height)
            Image(decorative: img, scale: 1).resizable()
                .frame(width: w, height: h)
                .position(position(w: w, h: h, margin: margin, in: size))
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: h * 0.6)).foregroundStyle(.white.opacity(0.25))
                .frame(width: h, height: h)
                .position(position(w: h, h: h, margin: margin, in: size))
        }
    }

    private func cornerTargets(in size: CGSize) -> some View {
        ForEach(Corner.allCases, id: \.self) { c in
            let w = size.width * 0.16, h = size.height * 0.16
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(c == model.corner ? 0 : 0.18))
                .strokeBorder(.white.opacity(c == model.corner ? 0 : 0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: w, height: h)
                .position(position(corner: c, w: w, h: h, margin: size.height * 0.025, in: size))
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

// MARK: - Bits

private struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .font(.system(size: 14, weight: .semibold))
            .frame(minWidth: 150)
            .padding(.vertical, 4)
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
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            onWindow(window)
        }
    }
}
