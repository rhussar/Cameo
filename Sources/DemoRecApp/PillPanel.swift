import AppKit
import SwiftUI

/// The small floating "● 0:42  Stop" control shown while recording, at the top of the recorded screen.
/// It's hidden from screen capture, and the main window is tucked away while it's up.
@MainActor
final class PillPanel {
    private var panel: NSPanel?
    private let zoomMarks = ZoomMarks()

    /// `zoomHint` is the zoom shortcut to show, if it could be registered.
    func show(since: Date, on screen: NSScreen?, zoomHint: String?, stop: @escaping () -> Void) {
        hide()
        zoomMarks.count = 0
        let host = NSHostingView(rootView: RecordingPill(since: since, zoomHint: zoomHint, marks: zoomMarks, stop: stop))
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
    }

    /// Acknowledges the zoom shortcut with a bounce, so you know the spot was marked.
    func flashZoom() {
        zoomMarks.count += 1
    }
}

@MainActor @Observable
private final class ZoomMarks {
    var count = 0
}

private struct RecordingPill: View {
    let since: Date
    let zoomHint: String?
    let marks: ZoomMarks
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
                HStack(spacing: 4) {
                    Image(systemName: "plus.magnifyingglass")
                        .symbolEffect(.bounce, value: marks.count)
                        .foregroundStyle(marks.count > 0 ? Color.accentColor : .secondary)
                    Text(zoomHint).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .help("Press \(zoomHint) to zoom in on the pointer here")
            }
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
