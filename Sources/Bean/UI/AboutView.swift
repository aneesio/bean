import SwiftUI

// A compact, truthful product identity and public-project window. Links point
// only at Bean's canonical repository; update checking remains the explicit,
// user-triggered control in Settings.
struct AboutView: View {
    let onOpenUpdateCheck: () -> Void

    init(onOpenUpdateCheck: @escaping () -> Void = {}) {
        self.onOpenUpdateCheck = onOpenUpdateCheck
    }

    var body: some View {
        ScrollView {
            VStack(spacing: BeanDesign.Spacing.md) {
                BeanMark(size: 88)
                    .padding(.top, BeanDesign.Spacing.sm)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

                Text(AppInfo.name)
                    .font(BeanDesign.Typography.largeTitle())

                Text("A small, open-source writing helper for your Mac.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                StatusPill(text: AppInfo.versionDisplay, kind: .neutral, showsIcon: false)

                Text("Local Quick Fix works offline. Optional AI actions use your own provider key. Bean has no hosted writing service, account, analytics, or automatic updater.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BeanDesign.Spacing.sm) {
                        projectLink("GitHub", BeanPublicLinks.repository)
                        projectLink("Support", BeanPublicLinks.support)
                        projectLink("Privacy", BeanPublicLinks.privacy)
                        projectLink("License", BeanPublicLinks.license)
                        projectLink("Changelog", BeanPublicLinks.changelog)
                    }
                    VStack(spacing: BeanDesign.Spacing.sm) {
                        HStack(spacing: BeanDesign.Spacing.md) {
                            projectLink("GitHub", BeanPublicLinks.repository)
                            projectLink("Support", BeanPublicLinks.support)
                            projectLink("Privacy", BeanPublicLinks.privacy)
                        }
                        HStack(spacing: BeanDesign.Spacing.md) {
                            projectLink("License", BeanPublicLinks.license)
                            projectLink("Changelog", BeanPublicLinks.changelog)
                        }
                    }
                    VStack(spacing: BeanDesign.Spacing.xs) {
                        projectLink("GitHub", BeanPublicLinks.repository)
                        projectLink("Support", BeanPublicLinks.support)
                        projectLink("Privacy", BeanPublicLinks.privacy)
                        projectLink("License", BeanPublicLinks.license)
                        projectLink("Changelog", BeanPublicLinks.changelog)
                    }
                }
                .font(.callout)

                Button("Open Update Check…") { onOpenUpdateCheck() }
                    .accessibilityHint("Opens General settings where you can start a GitHub Releases check")

                Text("Bean is a community-supported public beta. Support and bug reports use the public GitHub project; review diagnostics before sharing.")
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppInfo.copyright)
                    .font(BeanDesign.Typography.caption())
                    .foregroundColor(.secondary)
                    .padding(.bottom, BeanDesign.Spacing.sm)
            }
            .frame(maxWidth: 560)
            .padding(BeanDesign.Spacing.xl)
        }
        .frame(minWidth: 420, idealWidth: 520, minHeight: 460, idealHeight: 590)
        .tint(BeanDesign.accent)
    }

    private func projectLink(_ title: String, _ destination: URL) -> some View {
        Link(title, destination: destination)
            .frame(minHeight: BeanDesign.comfortableTargetSize)
    }
}
