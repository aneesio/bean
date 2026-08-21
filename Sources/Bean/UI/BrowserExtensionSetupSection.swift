import AppKit
import SwiftUI

/// A user-facing setup flow shared by first-run onboarding and Settings. The
/// app discovers the unpacked extension and writes the native-host manifest;
/// users never need to construct or run a Terminal command.
struct BrowserExtensionSetupSection: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var bridge = BrowserBridgeManager()
    @State private var manualExtensionID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
            HStack {
                Toggle("Enable Web Inline Support", isOn: $settings.webInlineEnabled)
                Spacer()
                StatusPill(text: "Beta", kind: .experimental, showsIcon: false)
            }

            Text("Web apps need the Bean browser extension. Setup stays local to this Mac, and the extension starts with no site access and no paid AI calls.")
                .font(.caption).foregroundColor(.secondary)

            setupStep(
                number: 1,
                title: "Load the extension",
                detail: "Reveal Bean's extension, open your browser's Extensions page, enable Developer mode, then choose Load unpacked."
            ) {
                HStack {
                    Button("Reveal Bean Extension") { revealExtensionFolder() }
                    Button("Open Browser Extensions") { openBrowserExtensions() }
                }
            }

            Divider().opacity(0.4)

            setupStep(
                number: 2,
                title: "Install the local connection",
                detail: "Bean detects the loaded extension and securely allows only its exact extension ID."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    bridgeStatus
                    if bridge.status.extensionIDs.isEmpty {
                        TextField("Extension ID (only if detection fails)", text: $manualExtensionID)
                            .textFieldStyle(.roundedBorder)
                        Text("You can copy this ID from the extension's Options page. Most users can leave it blank.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    HStack {
                        Button(bridge.status.state == .installed ? "Repair Browser Connection" : "Detect and Install") {
                            bridge.installOrRepair(manualExtensionID: manualExtensionID)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(bridge.isWorking)
                        Button("Scan Again") { bridge.refresh() }
                            .disabled(bridge.isWorking)
                    }
                }
            }

            Divider().opacity(0.4)

            setupStep(
                number: 3,
                title: "Reload and choose sites",
                detail: "Reload the extension once, open its Options, approve only the sites you want, and click Test Connection."
            ) { EmptyView() }

            Text("Provider-backed web checks remain off until you also enable them in extension Options. Local checks use no tokens.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .onAppear { bridge.refresh() }
    }

    private var bridgeStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.callout).fontWeight(.medium)
                Text(bridge.message ?? bridge.status.detail)
                    .font(.caption).foregroundColor(.secondary)
                if !bridge.status.extensionIDs.isEmpty {
                    Text("Detected \(bridge.status.extensionIDs.count) Bean extension installation\(bridge.status.extensionIDs.count == 1 ? "" : "s").")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func setupStep<Content: View>(
        number: Int, title: String, detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: BeanDesign.Spacing.sm) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(BeanDesign.subtleBorder))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundColor(.secondary)
                content()
            }
        }
    }

    private var statusTitle: String {
        switch bridge.status.state {
        case .installed: return "Browser connection is installed"
        case .readyToInstall: return "Bean extension found"
        case .needsRepair: return "Browser connection needs repair"
        case .extensionNotFound: return "Bean extension not detected yet"
        case .unavailable: return "Supported browser not detected"
        }
    }

    private var statusSymbol: String {
        bridge.status.state == .installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        bridge.status.state == .installed ? BeanDesign.success : BeanDesign.warning
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
            let appURL = URL(fileURLWithPath: path)
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(
                [extensionsURL], withApplicationAt: appURL,
                configuration: configuration, completionHandler: nil
            )
        } else {
            NSWorkspace.shared.open(extensionsURL)
        }
    }
}
