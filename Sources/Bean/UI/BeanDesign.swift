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

        // Fresh green for illustration and non-text decoration; the darker
        // interactive value carries controls and text in light appearance.
        static let decorativeAccentLight = SRGB(88, 174, 113)
        static let decorativeAccentDark = SRGB(164, 228, 188)

        // Interactive/text accents meet WCAG AA against their intended surface.
        static let interactiveAccentLight = SRGB(35, 122, 72)
        static let interactiveAccentDark = SRGB(129, 220, 165)
        static let brandBackgroundLight = SRGB(230, 243, 233)
        static let brandBackgroundDark = SRGB(25, 35, 29)
        static let cardBackgroundDark = SRGB(40, 45, 42)
        // Opaque fills keep accent text readable regardless of the surface
        // beneath selected or hovered rows.
        static let selectionBackgroundLight = brandBackgroundLight
        static let selectionBackgroundDark = SRGB(36, 61, 45)
        static let subtleBorderLight = SRGB(200, 216, 205)
        static let subtleBorderDark = SRGB(70, 89, 75)
        static let strongBorderLight = SRGB(101, 124, 109)
        static let strongBorderDark = SRGB(143, 166, 150)
        // A distinct issue hue and geometric cue distinguish the tiny field dot
        // from its idle green state in either appearance.
        static let issueDotLight = SRGB(217, 45, 32)
        static let issueDotDark = SRGB(255, 107, 107)
        static let issueDotMarkDark = SRGB(25, 25, 25)
        static let secondaryTextLight = SRGB(70, 70, 70)
        static let secondaryTextDark = SRGB(199, 199, 199)

        static let successLight = SRGB(30, 107, 58)
        static let successDark = SRGB(109, 213, 140)
        // Warning copy and its triangle retain meaning within the green brand.
        static let warningLight = interactiveAccentLight
        static let warningDark = interactiveAccentDark
        static let warningBackgroundLight = selectionBackgroundLight
        static let warningBackgroundDark = selectionBackgroundDark
        static let dangerLight = SRGB(180, 35, 53)
        static let dangerDark = SRGB(255, 138, 148)
        static let dangerBackgroundLight = SRGB(252, 236, 239)
        static let dangerBackgroundDark = SRGB(68, 36, 45)
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
    @available(macOS 14, *)
    static let actionButtonBorderShape = ButtonBorderShape.capsule

    // MARK: - Semantic colors
    /// Contrast-safe brand color for controls, links, selection, and text.
    static let accent = Color.beanDynamic(
        light: Palette.interactiveAccentLight.nsColor,
        dark: Palette.interactiveAccentDark.nsColor
    )
    static let issueDot = Color.beanDynamic(
        light: Palette.issueDotLight.nsColor, dark: Palette.issueDotDark.nsColor
    )
    static let issueDotMark = Color.beanDynamic(
        light: NSColor.white, dark: Palette.issueDotMarkDark.nsColor
    )
    /// Lighter green for artwork and backgrounds; never use for small text.
    static let decorativeAccent = Color.beanDynamic(
        light: Palette.decorativeAccentLight.nsColor,
        dark: Palette.decorativeAccentDark.nsColor
    )
    /// Pale green in light appearance and subdued forest in dark appearance.
    static let brandBackground = Color.beanDynamic(
        light: Palette.brandBackgroundLight.nsColor,
        dark: Palette.brandBackgroundDark.nsColor
    )
    /// Contrast-safe fill for selected rows, hover states, and brand pills.
    static let selectionBackground = Color.beanDynamic(
        light: Palette.selectionBackgroundLight.nsColor,
        dark: Palette.selectionBackgroundDark.nsColor
    )
    static let cardBackground = Color.beanDynamic(
        light: NSColor.white,
        dark: Palette.cardBackgroundDark.nsColor
    )
    static let secondaryText = Color.beanDynamic(
        light: Palette.secondaryTextLight.nsColor,
        dark: Palette.secondaryTextDark.nsColor
    )
    static let subtleBorder = Color.beanDynamic(
        light: Palette.subtleBorderLight.nsColor,
        dark: Palette.subtleBorderDark.nsColor
    )
    static let strongBorder = Color.beanDynamic(
        light: Palette.strongBorderLight.nsColor,
        dark: Palette.strongBorderDark.nsColor
    )

    static let success = Color.beanDynamic(
        light: Palette.successLight.nsColor,
        dark: Palette.successDark.nsColor
    )
    static let warning = Color.beanDynamic(
        light: Palette.warningLight.nsColor,
        dark: Palette.warningDark.nsColor
    )
    static let warningBackground = Color.beanDynamic(
        light: Palette.warningBackgroundLight.nsColor,
        dark: Palette.warningBackgroundDark.nsColor
    )
    static let danger = Color.beanDynamic(
        light: Palette.dangerLight.nsColor,
        dark: Palette.dangerDark.nsColor
    )
    static let dangerBackground = Color.beanDynamic(
        light: Palette.dangerBackgroundLight.nsColor,
        dark: Palette.dangerBackgroundDark.nsColor
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
