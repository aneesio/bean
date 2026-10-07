import XCTest
@testable import Bean

final class BeanDesignAccessibilityTests: XCTestCase {
    func testInteractiveAndSecondaryTextMeetNormalTextContrast() {
        XCTAssertGreaterThanOrEqual(
            BeanDesign.Palette.interactiveAccentLight.contrastRatio(
                against: BeanDesign.Palette.lightSurface
            ),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            BeanDesign.Palette.interactiveAccentDark.contrastRatio(
                against: BeanDesign.Palette.darkSurface
            ),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            BeanDesign.Palette.secondaryTextLight.contrastRatio(
                against: BeanDesign.Palette.lightSurface
            ),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            BeanDesign.Palette.secondaryTextDark.contrastRatio(
                against: BeanDesign.Palette.darkSurface
            ),
            4.5
        )
    }

    func testEverySemanticStatusColorMeetsNormalTextContrast() {
        let lightTokens = [
            BeanDesign.Palette.successLight,
            BeanDesign.Palette.warningLight,
            BeanDesign.Palette.dangerLight,
            BeanDesign.Palette.infoLight
        ]
        let darkTokens = [
            BeanDesign.Palette.successDark,
            BeanDesign.Palette.warningDark,
            BeanDesign.Palette.dangerDark,
            BeanDesign.Palette.infoDark
        ]

        for token in lightTokens {
            XCTAssertGreaterThanOrEqual(
                token.contrastRatio(against: BeanDesign.Palette.lightSurface),
                4.5
            )
        }
        for token in darkTokens {
            XCTAssertGreaterThanOrEqual(
                token.contrastRatio(against: BeanDesign.Palette.darkSurface),
                4.5
            )
        }
    }

    func testIssueDotMarkAndPaintRemainClearlyVisibleInBothAppearances() {
        let light = BeanDesign.Palette.issueDotLight
        let dark = BeanDesign.Palette.issueDotDark
        XCTAssertGreaterThanOrEqual(light.contrastRatio(against: BeanDesign.Palette.lightSurface), 4.5)
        XCTAssertGreaterThanOrEqual(dark.contrastRatio(against: BeanDesign.Palette.darkSurface), 4.5)
        XCTAssertGreaterThanOrEqual(BeanDesign.Palette.lightSurface.contrastRatio(against: light), 4.5)
        XCTAssertGreaterThanOrEqual(BeanDesign.Palette.issueDotMarkDark.contrastRatio(against: dark), 4.5)
        XCTAssertLessThan(light.green, light.red * 0.3, "The issue hue must remain red rather than drift back toward amber")
        XCTAssertLessThan(dark.green, dark.red * 0.5)
    }

    func testDecorativeCaramelIsNotTheInteractiveLightToken() {
        XCTAssertNotEqual(
            BeanDesign.Palette.decorativeAccentLight,
            BeanDesign.Palette.interactiveAccentLight
        )
    }

    func testDesktopControlsHaveComfortableMinimumTargets() {
        XCTAssertGreaterThanOrEqual(BeanDesign.minimumTargetSize, 28)
        XCTAssertGreaterThanOrEqual(BeanDesign.comfortableTargetSize, 32)
    }
}
