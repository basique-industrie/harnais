import HarnaisCore
import Infrastructure
import SwiftUI

@main
struct HarnaisApp: App {
    init() {
        MCPCommand.exitIfInvoked()
    }

    @State private var runtime = HarnaisRuntime()

    var body: some Scene {
        Window("Harnais", id: "harnais.accounts") {
            HarnaisRootView(runtime: runtime)
        }
        .defaultSize(width: 1000, height: 820)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            HarnaisAccountCommands()
            HarnaisUpdateCommands()
        }
    }
}
