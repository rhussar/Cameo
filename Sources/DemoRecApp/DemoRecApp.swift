import SwiftUI

@main
struct DemoRecApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // Plain stored property: the Command Line Tools SDK lacks the SwiftUI @State macro plugin.
    private let model = RecorderModel()

    var body: some Scene {
        Window("DemoRec", id: "main") {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets the raw binary (swift run) show a window too; inside DemoRec.app this is already the default.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    // Hiding the main window while recording also triggers this check; stay alive while the stop pill is up.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !sender.windows.contains { $0.isVisible }
    }
}
