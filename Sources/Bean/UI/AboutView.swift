import SwiftUI

// A small, premium About window: app mark, name, tagline, version, copyright.
struct AboutView: View {
    var body: some View {
        VStack(spacing: BeanDesign.Spacing.md) {
            BeanMark(size: 88)
                .padding(.top, BeanDesign.Spacing.sm)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

            Text(AppInfo.name)
                .font(BeanDesign.Typography.largeTitle())

            Text("Bean proofreads and rewrites text in most Mac apps.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            StatusPill(text: AppInfo.versionDisplay, kind: .neutral, showsIcon: false)

            Text(AppInfo.copyright)
                .font(BeanDesign.Typography.caption())
                .foregroundColor(.secondary)
                .padding(.bottom, BeanDesign.Spacing.sm)
        }
        .padding(BeanDesign.Spacing.xl)
        .frame(width: 340)
        .tint(BeanDesign.accent)
    }
}
