import AppKit
import SwiftUI

/// A human-readable setup flow shared by onboarding and Settings. Bean handles
/// the native connection itself; no Terminal command is ever required.
struct BrowserExtensionSetupSection: View {
    @ObservedObject var settings: AppSettings
    var onboarding: Bool = false

    @StateObject private var bridge = BrowserBridgeManager()
    @State private var manualExtensionID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
            statusCard

            if bridge.status.state != .installed {
                setupGuide
            } else {
                Text("Reload the extension once after a Bean update. Click Bean's browser toolbar icon anytime to change blocked websites or check the connection.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Repair Connection") {
                    bridge.installOrRepair(manualExtensionID: manualExtensionID)
                }
                .disabled(bridge.isWorking)
            }

            Divider().opacity(0.4)

            Toggle("Allow deeper AI checks from the browser", isOn: $settings.webInlineEnabled)
            Text("Optional. The free offline checker works without this. AI checks use your configured provider and automatic-call limit.")
                .font(.caption).foregroundColor(.secondary)

            DisclosureGroup("Connection help") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If Bean cannot detect the extension, copy its 32-letter ID from the browser's Extensions page and paste it here.")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("Extension ID", text: $manualExtensionID)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Try This ID") {
                            bridge.installOrRepair(manualExtensionID: manualExtensionID)
                        }
                        .disabled(bridge.isWorking || manualExtensionID.isEmpty)
                        Button("Scan Again") { bridge.refresh() }
                            .disabled(bridge.isWorking)
                    }
                }
                .padding(.top, 6)
            }
        }
        .onAppear { bridge.refresh() }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(symbol: statusSymbol, tint: statusColor, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle).font(.callout).fontWeight(.semibold)
                Text(bridge.message ?? bridge.status.detail)
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(BeanDesign.warmBackground))
    }

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
            Text(onboarding ? "Two quick steps" : "Finish browser setup")
                .font(.callout).fontWeight(.semibold)

            guideRow(number: 1, title: "Add the extension") {
                Text("Open your browser's Extensions page, turn on Developer mode, and drag or load Bean's extension folder.")
                HStack {
                    Button("Show Extension Folder") { revealExtensionFolder() }
                    Button("Open Extensions Page") { openBrowserExtensions() }
                }
            }

            guideRow(number: 2, title: "Connect it to Bean") {
                Text("After the extension appears in your browser, come back and let Bean finish the local connection.")
                Button(bridge.isWorking ? "Connecting…" : "Connect Bean to Browser") {
                    bridge.installOrRepair(manualExtensionID: manualExtensionID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(bridge.isWorking)
            }
        }
    }

    @ViewBuilder
    private func guideRow<Content: View>(number: Int, title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(BeanDesign.subtleBorder))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout).fontWeight(.semibold)
                content().font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var statusTitle: String {
        switch bridge.status.state {
        case .installed: return "Browser connected"
        case .readyToInstall: return "Extension found — ready to connect"
        case .needsRepair: return "Connection needs a quick repair"
        case .extensionNotFound: return "Add the Bean extension"
        case .unavailable: return "Open a supported browser first"
        }
    }

    private var statusSymbol: String {
        bridge.status.state == .installed ? "checkmark.circle.fill" : "globe"
    }

    private var statusColor: Color {
        bridge.status.state == .installed ? BeanDesign.success : BeanDesign.accent
    }

    private func revealExtensionFolder() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
           FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func openBrowserExtensions() {
        guard let extensionsURL = URL(string: "chrome://extensions/") else { return }
        let candidates = [
            "/Applications/Google Chrome.app",
            "/Applications/Brave Browser.app",
            "/Applications/Microsoft Edge.app",
            "/Applications/Chromium.app"
        ]
        if let path = candidates.first(where: FileManager.default.fileExists(atPath:)) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(
                [extensionsURL], withApplicationAt: URL(fileURLWithPath: path),
                configuration: configuration, completionHandler: nil
            )
        } else {
            NSWorkspace.shared.open(extensionsURL)
        }
    }
}
