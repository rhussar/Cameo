import AVFoundation
import DemoRecKit
import SwiftUI

/// The row under the preview: one click for the things you change often (what to record, crop, video size,
/// camera and mic on or off), and three small panels for the rest (how you look, the scene, the shortcuts).
struct ControlBar: View {
    @Bindable var model: RecorderModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                setup
                Spacer(minLength: 12)
                trailing
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { setup }
                HStack(spacing: 10) { Spacer(); trailing }
            }
        }
    }

    @ViewBuilder private var setup: some View {
        Group {
            SourceMenu(model: model)
            Toggle(isOn: $model.cropping) { Image(systemName: "crop") }
                .toggleStyle(.button)
                .help(model.crop == nil ? "Crop: show only part of the screen" : "Crop: change which part of the screen is shown")
                .accessibilityLabel("Crop")
            FormatMenu(model: model)
            BarDivider()
            DeviceButton(model: model, kind: .camera)
            DeviceButton(model: model, kind: .microphone)
            BarDivider()
            PanelButton(model: model, panel: .you)
            PanelButton(model: model, panel: .scene)
            PanelButton(model: model, panel: .shortcuts)
        }
        .disabled(!model.isSetup)
    }

    @ViewBuilder private var trailing: some View {
        RecordingsButton(model: model)
        if case .countdown = model.phase {
            PrimaryButton(title: "Cancel", systemImage: nil, tint: .secondary, action: model.cancelCountdown)
                .keyboardShortcut(.cancelAction)
        } else {
            PrimaryButton(title: "Start Recording", systemImage: "record.circle", tint: .red, action: model.record)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isSetup || model.cropping)
        }
    }
}

private struct BarDivider: View {
    var body: some View {
        Divider().frame(height: 18).padding(.horizontal, 2)
    }
}

// MARK: - One-click controls

/// "What am I recording?" — a whole screen, or one window (for a browser, that's its current tab).
private struct SourceMenu: View {
    @Bindable var model: RecorderModel

    var body: some View {
        Menu {
            Section("Screens") {
                ForEach(model.displaySources) { item($0, icon: "display") }
            }
            if !model.windowSources.isEmpty {
                Section("Windows") {
                    ForEach(model.windowSources) { item($0, icon: "macwindow") }
                }
            }
        } label: {
            Label(label, systemImage: isWindow ? "macwindow" : "display")
        }
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
        return text.count > 24 ? String(text.prefix(23)) + "…" : text
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

/// The video's frame size, grouped by where it's going.
private struct FormatMenu: View {
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
        .fixedSize()
        .help(help)
    }

    private var label: String {
        let f = model.format
        return f == .original ? "Original" : "\(f.platform) \(f.name.split(separator: " ").first.map(String.init) ?? f.name)"
    }

    private var help: String {
        guard let s = model.format.size else { return "Video size: same as what you record" }
        return "Video size: \(Int(s.width)) × \(Int(s.height)). \(model.format.note)"
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

/// Click to turn the camera or mic on and off; the arrow picks which one.
private struct DeviceButton: View {
    @Bindable var model: RecorderModel
    enum Kind { case camera, microphone }
    let kind: Kind

    var body: some View {
        Menu {
            Section(kind == .camera ? "Camera" : "Microphone") {
                ForEach(devices, id: \.uniqueID) { d in
                    Button {
                        if kind == .camera { model.cameraChoice = d.uniqueID } else { model.microphoneChoice = d.uniqueID }
                        on = true
                    } label: {
                        Label(d.localizedName, systemImage: d.uniqueID == chosen ? "checkmark" : "")
                    }
                }
            }
            Divider()
            Button(on ? "Turn \(name) Off" : "Turn \(name) On") { on.toggle() }
        } label: {
            // Menus draw their labels in one colour, so "Off" spells it out.
            if on { Image(systemName: icon) } else { Label("Off", systemImage: icon) }
        } primaryAction: {
            on.toggle()
        }
        .fixedSize()
        .help(help)
        .accessibilityLabel(on ? "\(name) on" : "\(name) off")
    }

    private var name: String { kind == .camera ? "Camera" : "Microphone" }
    private var on: Bool {
        get { kind == .camera ? model.cameraOn : model.micOn }
        nonmutating set { if kind == .camera { model.cameraOn = newValue } else { model.micOn = newValue } }
    }
    private var devices: [AVCaptureDevice] { kind == .camera ? model.cameras : model.microphones }
    private var chosen: String? { kind == .camera ? model.cameraChoice : model.microphoneChoice }
    private var icon: String {
        switch (kind, on) {
        case (.camera, true): "video.fill"
        case (.camera, false): "video.slash.fill"
        case (.microphone, true): "mic.fill"
        case (.microphone, false): "mic.slash.fill"
        }
    }
    private var help: String {
        let device = devices.first { $0.uniqueID == chosen }?.localizedName ?? name
        switch (kind, on) {
        case (.camera, true): return "\(device). Click to turn the camera off (just the screen and your voice)."
        case (.camera, false): return "Camera off: you're not in the video. Click to turn it on."
        case (.microphone, true): return "\(device). Click to mute."
        case (.microphone, false): return "Muted: the video has no sound. Click to unmute."
        }
    }
}

/// Opens one of the three settings panels.
private struct PanelButton: View {
    @Bindable var model: RecorderModel
    let panel: RecorderModel.Panel

    var body: some View {
        Button {
            model.openPanel = model.openPanel == panel ? nil : panel
        } label: {
            Label(title, systemImage: icon)
        }
        .fixedSize()
        .help(help)
        .popover(isPresented: Binding(get: { model.openPanel == panel },
                                      set: { if !$0, model.openPanel == panel { model.openPanel = nil } }),
                 arrowEdge: .top) {
            Group {
                switch panel {
                case .you: YouPanel(model: model)
                case .scene: ScenePanel(model: model)
                case .shortcuts: ShortcutsPanel(model: model)
                }
            }
            .padding(16)
            .controlSize(.regular)
        }
    }

    private var title: String {
        switch panel {
        case .you: "You"
        case .scene: model.sceneName == "Custom" ? "Scene" : model.sceneName
        case .shortcuts: "Shortcuts"
        }
    }
    private var icon: String {
        switch panel {
        case .you: "person.crop.rectangle"
        case .scene: "rectangle.on.rectangle.angled"
        case .shortcuts: model.shortcutProblem ? "exclamationmark.triangle" : "keyboard"
        }
    }
    private var help: String {
        switch panel {
        case .you: "How you appear: cutout or glass tile, size, mirror and look"
        case .scene: "Scene: how the screen sits and what's behind it"
        case .shortcuts: "Zoom, trail and highlight shortcuts for while you record"
        }
    }
}

// MARK: - Panels

/// A label on the left, the control on the right, so every panel lines up the same way.
private struct PanelRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            content
        }
    }
}

private struct YouPanel: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.cameraOn {
                Label("The camera is off, so you're not in the video.", systemImage: "video.slash")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Turn Camera On") { model.cameraOn = true }
                Divider()
            }
            Group {
                PanelRow("Style") {
                    Picker("Style", selection: $model.presenter.style) {
                        Text("Cutout").tag(Presenter.Style.cutout)
                        Text("Glass tile").tag(Presenter.Style.glass)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                if model.presenter.style == .glass {
                    PanelRow("Tile") {
                        Picker("Tile", selection: $model.presenter.tile) {
                            ForEach(Presenter.Tile.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                PanelRow("Size") {
                    Image(systemName: "person.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                    Slider(value: $model.size, in: 0.2...0.6)
                    Image(systemName: "person.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                PanelRow("Mirror") {
                    Toggle("Mirror camera", isOn: $model.mirror).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Spacer()
                }
                Divider()
                Text("Look").foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Look.presets, id: \.name) { preset in
                        ChoiceButton(title: preset.name, selected: preset.look == model.look) {
                            model.look = preset.look
                        }
                    }
                }
                DisclosureGroup("Fine-tune") {
                    VStack(spacing: 8) {
                        PanelRow("Brightness") { Slider(value: $model.look.brightness, in: -1...1) }
                        PanelRow("Contrast") { Slider(value: $model.look.contrast, in: 0.5...1.5) }
                        PanelRow("Colour") { Slider(value: $model.look.saturation, in: 0...2) }
                        PanelRow("Warmth") { Slider(value: $model.look.warmth, in: -1...1) }
                        HStack {
                            Spacer()
                            Button("Reset") { model.look = Look() }.disabled(model.look.isNeutral)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .disabled(!model.cameraOn)
        }
        .frame(width: 320)
    }
}

private struct ScenePanel: View {
    @Bindable var model: RecorderModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(DemoRecKit.Scene.presets, id: \.name) { scene in
                    ChoiceButton(title: scene.name, selected: model.sceneName == scene.name) {
                        withAnimation(.easeOut(duration: 0.15)) { model.apply(scene) }
                    }
                }
            }
            Divider()
            PanelRow("Screen") {
                Picker("Screen", selection: $model.screenStyle) {
                    ForEach(ScreenStyle.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if model.screenStyle == .tilted {
                PanelRow("Tilt") {
                    Slider(value: $model.tilt, in: -45...45)
                    Text("\(Int(model.tilt.rounded()))°").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            if model.screenStyle != .flat {
                PanelRow("Position") {
                    // Sticks at the middle, so it's easy to put back.
                    Slider(value: Binding(get: { model.screenShift }, set: { model.screenShift = abs($0) < 0.06 ? 0 : $0 }), in: -1...1)
                }
                .help("Slide the screen left or right to leave room for you beside it")
            }
            Divider()
            Text("Background").foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                swatch(.screen, title: "Screen")
                ForEach(Wallpaper.all, id: \.name) { w in swatch(.preset(w.name), title: w.name) }
                swatch(model.colorBackground, title: "Colour", selected: isColor, badge: "eyedropper") {
                    model.background = model.colorBackground
                }
                imageSwatch
            }
            if isColor {
                PanelRow("Colour") {
                    ColorPicker("Colour", selection: Binding(get: { Color(nsColor: model.backgroundColor) },
                                                             set: { model.backgroundColor = NSColor($0) }),
                                supportsOpacity: false)
                        .labelsHidden()
                    Text("Smooth").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $model.backgroundTexture, in: Background.textureRange)
                    Text("Grainy").font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .image = model.background {
                Toggle("Soften the picture", isOn: $model.backgroundBlurred)
            }
            if model.screenStyle == .flat, model.background != .screen {
                Text("Shows around the screen when it doesn't fill the frame.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 440)
    }

    private var isColor: Bool { if case .color = model.background { true } else { false } }

    private func swatch(_ background: Background, title: String) -> some View {
        swatch(background, title: title, selected: model.background == background) { model.background = background }
    }

    private func swatch(_ background: Background?, title: String, selected: Bool, badge: String? = nil,
                        action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15), action)
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let background { BackgroundSwatch(background: background) }
                    else {
                        Color.secondary.opacity(0.2)
                            .overlay(Image(systemName: "photo.badge.plus").font(.system(size: 13)).foregroundStyle(.secondary))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Image(systemName: badge).font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85)).padding(3)
                    }
                }
                .frame(height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                Text(title).font(.caption2).lineLimit(1).foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel("\(title) background")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Your own picture: the current one if there is one, else a prompt to pick.
    private var imageSwatch: some View {
        let current: Background? = if case .image = model.background { model.background } else { nil }
        return swatch(current, title: "Picture…", selected: current != nil, action: model.chooseBackgroundImage)
    }
}

private struct ShortcutsPanel: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShortcutRow(model: model, slot: .zoom)
            ShortcutRow(model: model, slot: .trail)
            ShortcutRow(model: model, slot: .highlight)
            if model.zoomShortcutNeedsAccess || model.trailShortcutNeedsAccess || model.highlightShortcutNeedsAccess {
                Divider()
                HStack {
                    Label("Highlighting and mouse buttons need Accessibility access.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("Allow…", action: model.requestMouseAccess)
                }
            }
            Text("Click a shortcut to change it. They work anywhere while Cameo is open; try them on the preview.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 360)
    }
}

/// A shortcut (zoom, the trail you draw while holding it, or the highlight box): shows it, and click to set a new one.
private struct ShortcutRow: View {
    @Bindable var model: RecorderModel
    let slot: RecorderModel.ShortcutSlot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: taken ? "exclamationmark.triangle.fill" : icon)
                .foregroundStyle(taken ? .orange : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(capturing ? (model.shortcutHint ?? "Press keys, or Esc to cancel") : detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let color {
                ColorPicker("\(name) colour", selection: color, supportsOpacity: false).labelsHidden()
            }
            Button { model.toggleCapturingShortcut(slot) } label: {
                Text(capturing ? "Press…" : shortcut.label).monospaced().frame(minWidth: 64)
            }
            .tint(capturing ? .accentColor : nil)
            .buttonStyle(.bordered)
        }
        .help(help)
    }

    private var capturing: Bool { model.capturingShortcut == slot }
    /// The trail's or highlight's colour; zoom has none.
    private var color: Binding<Color>? {
        let rgb: ReferenceWritableKeyPath<RecorderModel, RGB>
        switch slot {
        case .zoom: return nil
        case .trail: rgb = \.trailColor
        case .highlight: rgb = \.highlightColor
        }
        return Binding(
            get: { Color(.sRGB, red: model[keyPath: rgb].r, green: model[keyPath: rgb].g, blue: model[keyPath: rgb].b) },
            set: { new in
                guard let c = NSColor(new).usingColorSpace(.sRGB) else { return }
                model[keyPath: rgb] = RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
            })
    }
    private var name: String {
        switch slot { case .zoom: "Zoom"; case .trail: "Trail"; case .highlight: "Highlight" }
    }
    private var detail: String {
        if taken { return "Already used by another app" }
        switch slot {
        case .zoom: return "Press to zoom in on the pointer, again to zoom out"
        case .trail: return "Hold and move the pointer to draw"
        case .highlight: return "Press to box what's under the pointer"
        }
    }
    private var shortcut: Shortcut {
        switch slot { case .zoom: model.zoomShortcut; case .trail: model.trailShortcut; case .highlight: model.highlightShortcut }
    }
    private var taken: Bool {
        switch slot { case .zoom: model.zoomShortcutTaken; case .trail: model.trailShortcutTaken; case .highlight: model.highlightShortcutTaken }
    }
    private var icon: String {
        if shortcut.mouseButton != nil { return "computermouse" }
        switch slot { case .zoom: return "plus.magnifyingglass"; case .trail: return "scribble"; case .highlight: return "rectangle.dashed" }
    }
    private var help: String {
        if capturing {
            return "Press the shortcut you want: a key combo, or a mouse button with the pointer over Cameo "
                + "(middle, back, forward or a side button). Esc cancels."
        }
        if taken { return "\(shortcut.label) is already in use. Click to choose a different shortcut." }
        return "\(name): \(shortcut.label). Click the shortcut to change it."
    }
}

/// A preset you pick from a small grid; the current one is outlined.
private struct ChoiceButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : nil)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: selected ? 1.5 : 0))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Shared buttons

/// Your recordings: one click opens the folder in Finder.
struct RecordingsButton: View {
    @Bindable var model: RecorderModel

    var body: some View {
        Button(action: model.openRecordingsFolder) {
            Image(systemName: "folder")
        }
        .controlSize(.large)
        .fixedSize()
        .help("Open your recordings folder in Finder")
        .accessibilityLabel("Open recordings folder")
    }
}

struct PrimaryButton: View {
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
