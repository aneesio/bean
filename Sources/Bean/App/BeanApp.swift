import AppKit

// Bean's entry point.
//
// Bean uses an AppKit application lifecycle so it can live quietly in the menu
// bar, then show its Dock icon only while a user-facing Bean window is open.
// SwiftUI supplies the windows through NSHostingController.
@main
struct BeanApp {
    @MainActor
    static func main() {
        // Native messaging host mode: Chrome launches this same binary with the
        // calling extension's chrome-extension:// origin as an argument. In that
        // case run the stdin/stdout host loop and never start the GUI.
        let args = Array(CommandLine.arguments.dropFirst())
        switch BrowserBridgeInstaller().nativeHostLaunchDecision(arguments: args) {
        case .nativeHost:
            // The native host performs blocking stdin reads. Running that loop
            // on the main actor deadlocks status requests, because usage and
            // preferences intentionally hop back to MainActor. Keep the main
            // queue alive for those hops and own the pipe loop on a worker.
            DispatchQueue.global(qos: .userInitiated).async {
                NativeMessagingHost.run()
                exit(EXIT_SUCCESS)
            }
            dispatchMain()
        case .reject:
            // Never enter the pipe loop for a bare developer flag, malformed or
            // duplicate origin, stale manifest origin, or unrelated extension.
            exit(EXIT_FAILURE)
        case .gui:
            break
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // Start quietly in the menu bar. DockPresence switches to `.regular`
        // while onboarding, Settings, About, the action menu, or a preview is
        // open, and restores Bean's standard application menu at the same time.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
