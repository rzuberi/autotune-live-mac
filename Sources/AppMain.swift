import SwiftUI
import AppKit

@main
struct AutoTuneLiveMacApp: App {
    @StateObject private var controller = AudioEngineController()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("AutoTune Live") {
            ContentView(controller: controller)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 700, height: 500)
    }
}
