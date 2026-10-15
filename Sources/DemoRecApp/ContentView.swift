import AVFoundation
import DemoRecKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: RecorderModel

    var body: some View {
        Group {
            if case .recording(let since) = model.phase {
                RecordingPill(since: since, stop: model.stop)
            } else {
                MainPanel(model: model)
            }
        }
        .background(WindowConfigurator(compact: isRecording))
        .onAppear(perform: model.appeared)
    }

    private var isRecording: Bool {
        if case .recording = model.phase { return true }
        return false
    }
}

// MARK: - Main panel

private struct MainPanel: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(spacing: 14) {
            Stage(model: model)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 34) // room for the window buttons
        .padding(.bottom, 20)
        .frame(width: 420)
    }

    @ViewBuilder private var footer: some View {
        switch model.phase {
        case .idle, .failed:
            if case .failed(let msg, let needsSettings) = model.phase {
                Notice(text: msg, action: needsSettings ? ("Open Settings", { model.openPrivacySettings() }) : nil)
            }
            Controls(model: model)
            PrimaryButton(title: "Start Recording", systemImage: "record.circle", tint: .red, action: model.record)
                .keyboardShortcut(.defaultAction)
        case .countdown:
            PrimaryButton(title: "Cancel", systemImage: nil, tint: .secondary, action: model.cancelCountdown)
                .keyboardShortcut(.cancelAction)
        case .processing(let p):
            VStack(spacing: 8) {
                ProgressView(value: p).tint(.red)
                Text("Making your video… \(Int(p * 100))%")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 6)
        case .done:
            HStack(spacing: 10) {
                PrimaryButton(title: "Play", systemImage: "play.fill", tint: .accentColor, action: model.play)
                    .keyboardShortcut(.defaultAction)
                PrimaryButton(title: "Show in Finder", systemImage: "folder", tint: .secondary, action: model.revealInFinder)
            }
            Button("Record another", action: model.reset)
                .buttonStyle(.link)
                .font(.callout)
        case .recording:
            EmptyView()
        }
    }
}

/// A miniature of your screen showing where (and how big) you'll appear. Click a corner to move yourself.
private struct Stage: View {
    @Bindable var model: RecorderModel
    private var hovering: Bool { model.stageHovering }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))

                switch model.phase {
                case .done:
                    if let thumb = model.thumbnail {
                        Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                    }
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(.white, .green)
                        .shadow(radius: 8)
                case .processing:
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.white.opacity(0.6))
                        .symbolEffect(.pulse)
                default:
                    if hovering, model.isSetup { cornerTargets(in: geo.size) }
                    presenter(in: geo.size)
                    if case .countdown(let n) = model.phase {
                        Text("\(n)")
                            .font(.system(size: 88, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white).shadow(radius: 10)
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .overlay(alignment: .bottom) {
            if model.isSetup {
                Text("Click a corner to move yourself")
                    .font(.caption).foregroundStyle(.white.opacity(hovering ? 0.7 : 0))
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .animation(.spring(duration: 0.3), value: model.phase)
    }

    @ViewBuilder private func presenter(in size: CGSize) -> some View {
        let h = size.height * model.size
        let margin = size.height * 0.025
        if model.cameraDenied {
            VStack(spacing: 8) {
                Text("DemoRec needs your camera").foregroundStyle(.white)
                Button("Open Settings") { model.openPrivacySettings(camera: true) }
            }
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
            let w = size.width * 0.18, h = size.height * 0.18
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(c == model.corner ? 0 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: w, height: h)
                .position(position(corner: c, w: w, h: h, margin: 8, in: size))
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

private struct Controls: View {
    @Bindable var model: RecorderModel

    var body: some View {
        HStack(spacing: 14) {
            Picker(selection: $model.cameraID) {
                ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            } label: {
                Image(systemName: "camera")
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "person.fill").font(.system(size: 9))
                Slider(value: $model.size, in: 0.2...0.55).frame(width: 90)
                Image(systemName: "person.fill").font(.system(size: 14))
            }
            .foregroundStyle(.secondary)
            .help("Your size")

            Toggle(isOn: $model.mirror) {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .toggleStyle(.button)
            .help("Mirror camera")
        }
        .controlSize(.regular)
    }
}

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
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
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

// MARK: - Recording pill

private struct RecordingPill: View {
    let since: Date
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9)).foregroundStyle(.red)
                .symbolEffect(.pulse)
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text(elapsed(ctx.date)).font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize()
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Window

/// While recording, the window becomes a small floating pill that follows you across Spaces.
private struct WindowConfigurator: NSViewRepresentable {
    let compact: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.sharingType = compact ? .none : .readOnly
            window.level = compact ? .floating : .normal
            window.collectionBehavior = compact ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(b)?.isHidden = compact
            }
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}
