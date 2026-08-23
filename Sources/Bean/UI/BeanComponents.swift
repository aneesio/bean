import AppKit
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
            case .neutral: return BeanDesign.secondaryText
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
    @State private var increaseContrast = BeanDesign.increaseContrast

    var body: some View {
        HStack(spacing: 4) {
            if showsIcon { Image(systemName: kind.symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(kind.color)
        .background(
            Capsule().fill(kind.color.opacity(increaseContrast ? 0.24 : 0.14))
        )
        .overlay {
            if increaseContrast {
                Capsule().stroke(kind.color, lineWidth: 1)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            increaseContrast = BeanDesign.increaseContrast
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - Icon badge

struct IconBadge: View {
    let symbol: String
    var tint: Color = BeanDesign.decorativeAccent
    var size: CGFloat = 28
    @State private var increaseContrast = BeanDesign.increaseContrast

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundColor(tint)
            )
            .overlay {
                if increaseContrast {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(tint, lineWidth: 1)
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                increaseContrast = BeanDesign.increaseContrast
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Card container

struct BeanCard<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var increaseContrast = BeanDesign.increaseContrast

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
                    .stroke(
                        BeanDesign.border(increasedContrast: increaseContrast),
                        lineWidth: increaseContrast ? 1.5 : 1
                    )
            )
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                increaseContrast = BeanDesign.increaseContrast
            }
    }
}

// MARK: - Benefit card (onboarding)

struct BenefitCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    @State private var increaseContrast = BeanDesign.increaseContrast

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.sm) {
            IconBadge(symbol: symbol, size: 30)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(BeanDesign.Typography.caption())
                .foregroundColor(BeanDesign.secondaryText)
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
                    .stroke(
                        BeanDesign.border(increasedContrast: increaseContrast),
                        lineWidth: increaseContrast ? 1.5 : 1
                    )
            )
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            increaseContrast = BeanDesign.increaseContrast
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
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
        .accessibilityHidden(true)
    }
}

// MARK: - Step indicator (onboarding)

struct StepDots: View {
    let count: Int
    let current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var increaseContrast = BeanDesign.increaseContrast

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(
                        i == current
                            ? BeanDesign.accent
                            : BeanDesign.secondaryText.opacity(increaseContrast ? 0.55 : 0.28)
                    )
                    .frame(width: i == current ? 18 : 6, height: 6)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: current)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            increaseContrast = BeanDesign.increaseContrast
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
