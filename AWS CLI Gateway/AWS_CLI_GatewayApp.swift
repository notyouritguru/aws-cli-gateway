import SwiftUI

@main
struct AWS_CLI_GatewayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Remove all default menu items
            CommandGroup(replacing: .appInfo) {}
            CommandGroup(replacing: .systemServices) {}
            CommandGroup(replacing: .newItem) {}
        }
    }
}
