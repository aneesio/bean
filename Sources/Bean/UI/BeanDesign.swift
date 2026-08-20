import SwiftUI
import AppKit

// Bean's small, centralized design system. Semantic tokens only — no ad-hoc
// colors scattered across views. Everything adapts to light/dark.
enum BeanDesign {

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner radii
    enum Radius {
        static let sm: CGFloat = 6
        static let card: CGFloat = 12
        static let lg: CGFloat = 16
    }

    // MARK: - Semantic colors
    /// Warm, restrained coffee accent (amber/caramel, not brown).
    static let accent = Color.beanDynamic(
        light: NSColor(srgbRed: 0.76, green: 0.51, blue: 0.27, alpha: 1),
        dark:  NSColor(srgbRed: 0.85, green: 0.65, blue: 0.41, alpha: 1)
    )
    /// Subtle warm background for hero/onboarding surfaces.
    static let warmBackground = Color.beanDynamic(
        light: NSColor(srgbRed: 0.98, green: 0.972, blue: 0.957, alpha: 1),
        dark:  NSColor(srgbRed: 0.11, green: 0.105, blue: 0.10, alpha: 1)
    )
    static let cardBackground = Color.beanDynamic(
        light: NSColor.white,
        dark:  NSColor(white: 0.165, alpha: 1)
    )
    static let subtleBorder = Color.primary.opacity(0.08)

    static let success = Color.green
    static let warning = Color.orange
    static let danger  = Color.red
    static let info    = Color.blue

    // MARK: - Typography
    enum Typography {
        static func largeTitle() -> Font { .system(size: 28, weight: .bold) }
        static func title() -> Font { .system(size: 20, weight: .semibold) }
        static func sectionTitle() -> Font { .system(size: 13, weight: .semibold) }
        static func body() -> Font { .system(size: 13) }
        static func caption() -> Font { .system(size: 11) }
    }
}

extension Color {
    /// A color that resolves differently in light vs dark appearance.
    static func beanDynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
