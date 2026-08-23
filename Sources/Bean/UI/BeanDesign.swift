import SwiftUI
import AppKit

// Bean's small, centralized design system. Semantic tokens only — no ad-hoc
// colors scattered across views. Everything adapts to light/dark.
enum BeanDesign {

    /// Testable sRGB values keep accessibility decisions explicit instead of
    /// burying contrast-critical colors inside opaque SwiftUI values.
    struct SRGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        init(_ red: Int, _ green: Int, _ blue: Int) {
            self.red = Double(red) / 255
            self.green = Double(green) / 255
            self.blue = Double(blue) / 255
        }

        var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }

        var relativeLuminance: Double {
            func linear(_ component: Double) -> Double {
                component <= 0.04045
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrastRatio(against other: SRGB) -> Double {
            let brighter = max(relativeLuminance, other.relativeLuminance)
            let darker = min(relativeLuminance, other.relativeLuminance)
            return (brighter + 0.05) / (darker + 0.05)
        }
    }

    enum Palette {
        static let lightSurface = SRGB(255, 255, 255)
        static let darkSurface = SRGB(30, 30, 30)

        // Caramel remains part of the brand, but the lighter value is reserved
        // for illustration and non-text decoration.
        static let decorativeAccentLight = SRGB(194, 130, 69)
        static let decorativeAccentDark = SRGB(224, 161, 94)

        // Interactive/text accents meet WCAG AA against their intended surface.
        static let interactiveAccentLight = SRGB(138, 76, 23)
        static let interactiveAccentDark = SRGB(224, 161, 94)
        static let secondaryTextLight = SRGB(70, 70, 70)
        static let secondaryTextDark = SRGB(199, 199, 199)

        static let successLight = SRGB(30, 107, 58)
        static let successDark = SRGB(109, 213, 140)
        static let warningLight = SRGB(138, 79, 0)
        static let warningDark = SRGB(241, 179, 91)
        static let dangerLight = SRGB(161, 38, 34)
        static let dangerDark = SRGB(255, 138, 128)
        static let infoLight = SRGB(26, 95, 158)
        static let infoDark = SRGB(117, 183, 242)
    }

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

    // MARK: - Interaction
    static let minimumTargetSize: CGFloat = 28
    static let comfortableTargetSize: CGFloat = 32

    // MARK: - Semantic colors
    /// Contrast-safe brand color for controls, links, selection, and text.
    static let accent = Color.beanDynamic(
        light: Palette.interactiveAccentLight.nsColor,
        dark: Palette.interactiveAccentDark.nsColor
    )
    /// Lighter caramel for artwork and backgrounds; never use for small text.
    static let decorativeAccent = Color.beanDynamic(
        light: Palette.decorativeAccentLight.nsColor,
        dark: Palette.decorativeAccentDark.nsColor
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
    static let secondaryText = Color.beanDynamic(
        light: Palette.secondaryTextLight.nsColor,
        dark: Palette.secondaryTextDark.nsColor
    )
    static let subtleBorder = Color.beanDynamic(
        light: NSColor(srgbRed: 0.80, green: 0.77, blue: 0.73, alpha: 1),
        dark: NSColor(srgbRed: 0.33, green: 0.31, blue: 0.29, alpha: 1)
    )
    static let strongBorder = Color.beanDynamic(
        light: NSColor(srgbRed: 0.55, green: 0.50, blue: 0.45, alpha: 1),
        dark: NSColor(srgbRed: 0.55, green: 0.52, blue: 0.48, alpha: 1)
    )

    static let success = Color.beanDynamic(
        light: Palette.successLight.nsColor,
        dark: Palette.successDark.nsColor
    )
    static let warning = Color.beanDynamic(
        light: Palette.warningLight.nsColor,
        dark: Palette.warningDark.nsColor
    )
    static let danger = Color.beanDynamic(
        light: Palette.dangerLight.nsColor,
        dark: Palette.dangerDark.nsColor
    )
    static let info = Color.beanDynamic(
        light: Palette.infoLight.nsColor,
        dark: Palette.infoDark.nsColor
    )

    /// AppKit's display option is available before macOS 14, unlike SwiftUI's
    /// `accessibilityContrast` environment value. Components observe the
    /// matching workspace notification so this remains live on macOS 13.
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static func border(increasedContrast: Bool) -> Color {
        increasedContrast ? strongBorder : subtleBorder
    }

    // MARK: - Typography
    enum Typography {
        static func largeTitle() -> Font { .system(size: 28, weight: .bold) }
        static func title() -> Font { .system(size: 20, weight: .semibold) }
        static func sectionTitle() -> Font { .system(size: 13, weight: .semibold) }
        static func body() -> Font { .system(size: 13) }
        static func caption() -> Font { .system(size: 12) }
        static func smallCaption() -> Font { .system(size: 11) }
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
