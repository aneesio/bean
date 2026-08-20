import AppKit

// Bean's entry point.
//
// Bean is a menu-bar-only app, so it uses an AppKit application lifecycle
// (NSApplication + AppDelegate) rather than a SwiftUI `App` scene. This gives
// us precise control over activation policy (.accessory = no Dock icon) and
// the NSStatusItem. SwiftUI is still used for the Settings window, hosted via
// NSHostingController.
@main
struct BeanApp {
    @MainActor
    static func main() {
        // Native messaging host mode: Chrome launches this same binary with the
        // calling extension's chrome-extension:// origin as an argument. In that
        // case run the stdin/stdout host loop and never start the GUI.
        let args = CommandLine.arguments.dropFirst()
        if args.contains(where: { $0.hasPrefix("chrome-extension://") }) || args.contains("--native-messaging-host") {
            NativeMessagingHost.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // .accessory: the app lives in the menu bar only, with no Dock icon and
        // no main window on launch.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
