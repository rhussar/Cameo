import AppKit
import SwiftUI

/// The small floating "● 0:42  🗑  Stop" control shown while recording, at the top of the recorded screen.
/// It's hidden from screen capture, and the main window is tucked away while it's up.
@MainActor
final class PillPanel {
    private var panel: NSPanel?
    private let zoomMarks = ZoomMarks()

    /// `zoomHint` is the zoom shortcut to show, if it could be registered.
    func show(since: Date, on screen: NSScreen?, zoomHint: String?, discard: @escaping () -> Void, stop: @escaping () -> Void) {
        hide()
        zoomMarks.count = 0
        zoomMarks.zoomedIn = false
        let host = NSHostingView(rootView: RecordingPill(since: since, zoomHint: zoomHint, marks: zoomMarks, discard: discard, stop: stop))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        LivePreview.shared.stop() // recording ended (stopped or discarded)
    }

    /// Acknowledges the zoom shortcut with a bounce, and shows whether you're zoomed in now.
    func setZoomed(_ zoomedIn: Bool) {
        zoomMarks.count += 1
        zoomMarks.zoomedIn = zoomedIn
        // The "Zoomed in" badge is wider than the idle icon; regrow the pill around its top centre.
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel, let host = panel.contentView else { return }
            let size = host.fittingSize
            let old = panel.frame
            panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height),
                           display: true, animate: false)
        }
    }
}

@MainActor @Observable
private final class ZoomMarks {
    var count = 0
    var zoomedIn = false
}

private struct RecordingPill: View {
    let since: Date
    let zoomHint: String?
    let marks: ZoomMarks
    let discard: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9)).foregroundStyle(.red)
                .symbolEffect(.pulse)
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text(elapsed(ctx.date)).font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
            if let zoomHint {
                ZoomIndicator(marks: marks)
                    .help(marks.zoomedIn ? "Zoomed in. Press \(zoomHint) to zoom back out" : "Not zoomed. Press \(zoomHint) to zoom in on the pointer")
            }
            PreviewToggle(preview: LivePreview.shared)
            Button(action: discard) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this recording without saving")
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.red)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .padding(6) // room for the shadow
        .fixedSize()
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shows or hides the live preview window while recording.
private struct PreviewToggle: View {
    let preview: LivePreview

    var body: some View {
        Button(action: preview.toggle) {
            Image(systemName: preview.enabled ? "eye.fill" : "eye.slash")
                .foregroundStyle(preview.enabled ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(preview.enabled ? "Hide the live preview" : "Show a live preview of the video")
        .accessibilityLabel(preview.enabled ? "Hide live preview" : "Show live preview")
    }
}

/// Zoom state at a glance: a faint magnifier when you're not zoomed, a bright "Zoomed in" badge when you are,
/// so you don't forget to zoom back out.
private struct ZoomIndicator: View {
    let marks: ZoomMarks

    var body: some View {
        Group {
            if marks.zoomedIn {
                Label("Zoomed in", systemImage: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.yellow, in: Capsule())
                    .symbolEffect(.pulse, options: .repeating)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.25), value: marks.zoomedIn)
        .accessibilityLabel(marks.zoomedIn ? "Zoomed in" : "Not zoomed")
    }
}
