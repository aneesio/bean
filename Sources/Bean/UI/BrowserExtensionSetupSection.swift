import AppKit
import SwiftUI

/// A browser destination is derived from Bean's validated profile metadata,
/// then resolved through Launch Services at the moment the user opens it. Do
/// not infer an application by whichever hard-coded path happens to exist
/// first; many people keep more than one Chromium browser installed.
enum BrowserExtensionsPageTarget: String, CaseIterable, Identifiable {
    case chrome = "Chrome"
    case brave = "Brave"
    case edge = "Edge"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.edgemac"
        }
    }

    var extensionsPageURL: URL {
        switch self {
        case .chrome: return URL(string: "chrome://extensions/")!
        case .brave: return URL(string: "brave://extensions/")!
        case .edge: return URL(string: "edge://extensions/")!
        }
    }
}

enum BrowserExtensionsPageRouting {
    /// Prefer a browser where Bean found the exact extension, then a browser
    /// with a current Mac connection. If neither identifies one browser, offer
    /// every detected browser as an explicit choice instead of guessing.
    static func targets(for status: BrowserBridgeStatus) -> [BrowserExtensionsPageTarget] {
        for names in [
            status.detectedExtensionBrowserNames,
            status.configuredBrowserNames,
            status.browserNames
        ] {
            let targets = uniqueKnownTargets(in: names)
            if !targets.isEmpty { return targets }
        }
        return []
    }

    private static func uniqueKnownTargets(
        in names: [String]
    ) -> [BrowserExtensionsPageTarget] {
        var seen = Set<BrowserExtensionsPageTarget>()
        return names.compactMap(BrowserExtensionsPageTarget.init(rawValue:)).filter {
            seen.insert($0).inserted
        }
    }
}

/// A human-readable setup flow shared by onboarding and Settings. Bean handles
/// the native connection itself; no Terminal command is ever required.
struct BrowserExtensionSetupSection: View {
    @ObservedObject var settings: AppSettings
    var onboarding: Bool = false

    @StateObject private var bridge = BrowserBridgeManager()
    @State private var manualExtensionID = ""
    @State private var browserOpenError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
            statusCard

            if bridge.status.state != .installed {
                setupGuide
            } else {
                Text("Open Bean's browser toolbar icon and choose Check again to verify the live app connection. Reload the extension once after a Bean update. Blocked websites are managed there too.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Repair Mac Connection") {
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
                Text(statusDetail)
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
                    extensionsPageControl
                }
                if let browserOpenError {
                    Label(browserOpenError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(BeanDesign.danger)
                        .accessibilityLabel("Browser error: \(browserOpenError)")
                }
            }

            guideRow(number: 2, title: "Install the Mac connection") {
                Text("After the extension appears in your browser, come back and let Bean install its local connection file. The extension checks live app status after installation.")
                Button(bridge.isWorking ? "Installing…" : "Install Mac Connection") {
                    bridge.installOrRepair(manualExtensionID: manualExtensionID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(bridge.isWorking)
            }
        }
    }

    @ViewBuilder
    private var extensionsPageControl: some View {
        let targets = BrowserExtensionsPageRouting.targets(for: bridge.status)
        if let target = targets.first, targets.count == 1 {
            Button("Open Extensions Page") { openBrowserExtensions(in: target) }
                .accessibilityHint("Opens the Extensions page in \(target.displayName)")
        } else if targets.isEmpty {
            Button("Open Extensions Page") {}
                .disabled(true)
                .accessibilityHint("Open Chrome, Brave, or Edge once, then return to Bean")
        } else {
            Menu("Open Extensions Page") {
                ForEach(targets) { target in
                    Button(target.displayName) { openBrowserExtensions(in: target) }
                }
            }
            .accessibilityHint("Choose which detected browser to open")
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
        case .installed: return "Mac connection installed"
        case .readyToInstall: return "Extension found — ready to install"
        case .needsRepair: return "Mac connection needs a quick repair"
        case .extensionNotFound: return "Add the Bean extension"
        case .unavailable: return "Open a supported browser first"
        }
    }

    private var statusDetail: String {
        if bridge.status.state == .installed {
            return "The Mac connection file is in place. Live browser status is checked inside the extension."
        }
        return bridge.message ?? bridge.status.detail
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

    private func openBrowserExtensions(in target: BrowserExtensionsPageTarget) {
        browserOpenError = nil
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: target.bundleIdentifier
              ) else {
            browserOpenError = "Bean found a \(target.displayName) profile but couldn't locate the browser app. Open \(target.displayName), then open its Extensions page."
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [target.extensionsPageURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            DispatchQueue.main.async {
                browserOpenError = error == nil
                    ? nil
                    : "Bean couldn't open \(target.displayName)'s Extensions page. Open the browser and try again."
            }
        }
    }
}
