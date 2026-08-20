import SwiftUI

// Reusable premium components built on BeanDesign tokens.

// MARK: - Status pill

struct StatusPill: View {
    enum Kind {
        case success, warning, danger, info, neutral, experimental
        var color: Color {
            switch self {
            case .success: return BeanDesign.success
            case .warning: return BeanDesign.warning
            case .danger: return BeanDesign.danger
            case .info: return BeanDesign.info
            case .neutral: return .secondary
            case .experimental: return BeanDesign.accent
            }
        }
        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.octagon.fill"
            case .info: return "info.circle.fill"
            case .neutral: return "circle.fill"
            case .experimental: return "flask.fill"
            }
        }
    }

    let text: String
    let kind: Kind
    var showsIcon: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            if showsIcon { Image(systemName: kind.symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(kind.color)
        .background(Capsule().fill(kind.color.opacity(0.14)))
    }
}

// MARK: - Icon badge

struct IconBadge: View {
    let symbol: String
    var tint: Color = BeanDesign.accent
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundColor(tint)
            )
    }
}

// MARK: - Card container

struct BeanCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.sm) { content }
            .padding(BeanDesign.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BeanDesign.Radius.card, style: .continuous)
                    .fill(BeanDesign.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BeanDesign.Radius.card, style: .continuous)
                    .stroke(BeanDesign.subtleBorder, lineWidth: 1)
            )
    }
}

// MARK: - Benefit card (onboarding)

struct BenefitCard: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.sm) {
            IconBadge(symbol: symbol, size: 30)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BeanDesign.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: BeanDesign.Radius.card, style: .continuous)
                .fill(BeanDesign.warmBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BeanDesign.Radius.card, style: .continuous)
                .stroke(BeanDesign.subtleBorder, lineWidth: 1)
        )
    }
}

// MARK: - The bean app mark (icon image, falls back to SF Symbol)

struct BeanMark: View {
    var size: CGFloat = 64
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(BeanDesign.warmBackground)
                    .overlay(Image(systemName: "text.badge.checkmark").font(.system(size: size * 0.42)).foregroundColor(BeanDesign.accent))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(BeanDesign.subtleBorder))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Step indicator (onboarding)

struct StepDots: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? BeanDesign.accent : Color.secondary.opacity(0.25))
                    .frame(width: i == current ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: current)
            }
        }
    }
}
