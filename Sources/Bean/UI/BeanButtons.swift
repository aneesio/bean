import AppKit
import SwiftUI

enum BeanButtonProminence {
    case primary, secondary
}

extension View {
    /// The default for action controls. More specific link, toolbar and list
    /// styles remain free to override it inside the view hierarchy.
    func beanActionButtons() -> some View {
        modifier(BeanActionButtonsModifier())
    }

    func beanButton(_ prominence: BeanButtonProminence = .secondary) -> some View {
        modifier(BeanButtonModifier(prominence: prominence))
    }
}

private struct BeanActionButtonsModifier: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(BeanDesign.actionButtonBorderShape)
                .tint(BeanDesign.accent)
        } else {
            content
                .buttonStyle(BeanCapsuleButtonStyle())
                .tint(BeanDesign.accent)
        }
    }
}

private struct BeanButtonModifier: ViewModifier {
    let prominence: BeanButtonProminence

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            switch prominence {
            case .primary:
                content.buttonStyle(.borderedProminent)
                    .buttonBorderShape(BeanDesign.actionButtonBorderShape).tint(BeanDesign.accent)
            case .secondary:
                content.buttonStyle(.bordered)
                    .buttonBorderShape(BeanDesign.actionButtonBorderShape).tint(BeanDesign.accent)
            }
        } else {
            content.buttonStyle(BeanCapsuleButtonStyle(prominence: prominence))
                .tint(BeanDesign.accent)
        }
    }
}

/// macOS 13 supports bordered buttons but not ButtonBorderShape.capsule.
/// Keep the actual SwiftUI Button so roles, shortcuts and accessibility actions
/// still work while supplying the same capsule geometry on that OS.
struct BeanCapsuleButtonStyle: ButtonStyle {
    var prominence: BeanButtonProminence = .secondary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false
    @State private var increaseContrast = BeanDesign.increaseContrast

    func makeBody(configuration: Configuration) -> some View {
        let primary = prominence == .primary
        let destructive = configuration.role == .destructive
        let tint = destructive ? BeanDesign.danger : BeanDesign.accent
        let foreground: Color = primary
            ? (colorScheme == .dark ? Color(nsColor: .black) : .white)
            : (destructive ? BeanDesign.danger : BeanDesign.accent)

        configuration.label
            .padding(.horizontal, BeanDesign.Spacing.md)
            .frame(minHeight: controlSize == .large
                   ? BeanDesign.comfortableTargetSize : BeanDesign.minimumTargetSize)
            .foregroundColor(foreground)
            .background(Capsule().fill(primary ? tint : BeanDesign.cardBackground))
            .overlay(Capsule().strokeBorder(
                primary ? Color.clear : BeanDesign.border(increasedContrast: increaseContrast),
                lineWidth: increaseContrast ? 1.5 : 1
            ))
            .overlay(Capsule().fill(Color.primary.opacity(
                configuration.isPressed ? 0.12 : (hovering && isEnabled ? 0.05 : 0)
            )))
            .clipShape(Capsule())
            .overlay {
                if isFocused {
                    Capsule().stroke(BeanDesign.accent, lineWidth: 2).padding(-3)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )) { _ in increaseContrast = BeanDesign.increaseContrast }
    }
}
