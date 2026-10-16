import SwiftUI

@main
struct DemoRecApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // Plain stored property: the Command Line Tools SDK lacks the SwiftUI @State macro plugin.
    private let model = RecorderModel()

    var body: some Scene {
        Window("Cameo", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)

        // Cameo lives in the menu bar rather than the Dock.
        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle")
        }
    }
}

/// The menu under the menu bar icon: record or stop, open the window, quit.
private struct MenuBarMenu: View {
    let model: RecorderModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.phase {
        case .recording:
            Button("Stop Recording", action: model.stop)
        case .countdown:
            Button("Cancel Countdown", action: model.cancelCountdown)
        case .processing(let p):
            Text("Making your video… \(Int(p * 100))%")
        default:
            Button("Start Recording") {
                showWindow()
                if case .done = model.phase { model.reset() }
                model.record()
            }
            .disabled(!model.isSetup && !model.isDone)
        }
        Button("Show Cameo", action: showWindow)
        Divider()
        Button("Quit Cameo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        if let window = model.mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon: Cameo lives in the menu bar (Info.plist's LSUIElement does the same inside Cameo.app).
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
    }

    /// Quitting mid-recording or mid-render loses the video, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { model?.confirmQuit() ?? true } ? .terminateNow : .terminateCancel
    }

    // The menu bar icon stays after the window closes, so closing it doesn't quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
