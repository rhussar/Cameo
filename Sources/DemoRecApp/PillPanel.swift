import AppKit
import SwiftUI

/// The small floating "● 0:42  Stop" control shown while recording, at the top of the recorded screen.
/// It's hidden from screen capture, and the main window is tucked away while it's up.
@MainActor
final class PillPanel {
    private var panel: NSPanel?

    func show(since: Date, on screen: NSScreen?, stop: @escaping () -> Void) {
        hide()
        let host = NSHostingView(rootView: RecordingPill(since: since, stop: stop))
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
}

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
