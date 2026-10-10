import XCTest
@testable import Bean

final class BeanDesignAccessibilityTests: XCTestCase {
    func testInteractiveAndSecondaryTextMeetNormalTextContrast() {
        let lightSurfaces = [
            BeanDesign.Palette.lightSurface,
            BeanDesign.Palette.brandBackgroundLight
        ]
        let darkSurfaces = [
            BeanDesign.Palette.darkSurface,
            BeanDesign.Palette.brandBackgroundDark,
            BeanDesign.Palette.cardBackgroundDark
        ]

        for surface in lightSurfaces {
            XCTAssertGreaterThanOrEqual(BeanDesign.Palette.interactiveAccentLight.contrastRatio(against: surface), 4.5)
            XCTAssertGreaterThanOrEqual(BeanDesign.Palette.secondaryTextLight.contrastRatio(against: surface), 4.5)
        }
        for surface in darkSurfaces {
            XCTAssertGreaterThanOrEqual(BeanDesign.Palette.interactiveAccentDark.contrastRatio(against: surface), 4.5)
            XCTAssertGreaterThanOrEqual(BeanDesign.Palette.secondaryTextDark.contrastRatio(against: surface), 4.5)
        }
    }

    func testAccentTextMeetsSelectedRowAndBrandPillContrast() {
        XCTAssertGreaterThanOrEqual(
            BeanDesign.Palette.interactiveAccentLight.contrastRatio(
                against: BeanDesign.Palette.selectionBackgroundLight
            ), 4.5
        )
        XCTAssertGreaterThanOrEqual(
            BeanDesign.Palette.interactiveAccentDark.contrastRatio(
                against: BeanDesign.Palette.selectionBackgroundDark
            ), 4.5
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
        let lightSurfaces = [BeanDesign.Palette.lightSurface, BeanDesign.Palette.brandBackgroundLight]
        let darkSurfaces = [BeanDesign.Palette.darkSurface, BeanDesign.Palette.brandBackgroundDark,
                            BeanDesign.Palette.cardBackgroundDark]

        for token in lightTokens {
            for surface in lightSurfaces {
                XCTAssertGreaterThanOrEqual(token.contrastRatio(against: surface), 4.5)
            }
        }
        for token in darkTokens {
            for surface in darkSurfaces {
                XCTAssertGreaterThanOrEqual(token.contrastRatio(against: surface), 4.5)
            }
        }
    }

    func testWarningAndDangerPillTextRemainsReadableInBothAppearances() {
        let pairs = [
            (BeanDesign.Palette.warningLight, BeanDesign.Palette.warningBackgroundLight),
            (BeanDesign.Palette.warningDark, BeanDesign.Palette.warningBackgroundDark),
            (BeanDesign.Palette.dangerLight, BeanDesign.Palette.dangerBackgroundLight),
            (BeanDesign.Palette.dangerDark, BeanDesign.Palette.dangerBackgroundDark)
        ]
        for (text, background) in pairs {
            XCTAssertGreaterThanOrEqual(text.contrastRatio(against: background), 4.5)
        }
    }

    func testWarningsRemainGreenAndDangerRemainsCleanRed() {
        for warning in [BeanDesign.Palette.warningLight, BeanDesign.Palette.warningDark] {
            XCTAssertGreaterThan(warning.green, warning.red)
            XCTAssertGreaterThan(warning.green, warning.blue)
        }
        for background in [BeanDesign.Palette.warningBackgroundLight,
                           BeanDesign.Palette.warningBackgroundDark] {
            XCTAssertGreaterThan(background.green, background.red)
            XCTAssertGreaterThan(background.green, background.blue)
        }
        for danger in [BeanDesign.Palette.dangerLight, BeanDesign.Palette.dangerDark] {
            XCTAssertGreaterThan(danger.red, danger.blue)
            XCTAssertGreaterThan(danger.blue, danger.green)
        }
    }

    func testIssueDotMarkAndPaintRemainClearlyVisibleInBothAppearances() {
        let light = BeanDesign.Palette.issueDotLight
        let dark = BeanDesign.Palette.issueDotDark
        XCTAssertGreaterThanOrEqual(light.contrastRatio(against: BeanDesign.Palette.lightSurface), 4.5)
        XCTAssertGreaterThanOrEqual(dark.contrastRatio(against: BeanDesign.Palette.darkSurface), 4.5)
        XCTAssertGreaterThanOrEqual(BeanDesign.Palette.lightSurface.contrastRatio(against: light), 4.5)
        XCTAssertGreaterThanOrEqual(BeanDesign.Palette.issueDotMarkDark.contrastRatio(against: dark), 4.5)
        XCTAssertEqual(BeanDesign.Palette.issueDotMarkDark.red, BeanDesign.Palette.issueDotMarkDark.green)
        XCTAssertEqual(BeanDesign.Palette.issueDotMarkDark.green, BeanDesign.Palette.issueDotMarkDark.blue)
        XCTAssertLessThan(light.green, light.red * 0.3, "The issue hue must remain red rather than drift back toward amber")
        XCTAssertLessThan(dark.green, dark.red * 0.5)
    }

    func testDecorativeGreenIsNotTheInteractiveLightToken() {
        XCTAssertNotEqual(
            BeanDesign.Palette.decorativeAccentLight,
            BeanDesign.Palette.interactiveAccentLight
        )
    }

    func testBrandAccentsRemainGreenInBothAppearances() {
        for token in [BeanDesign.Palette.interactiveAccentLight,
                      BeanDesign.Palette.interactiveAccentDark,
                      BeanDesign.Palette.decorativeAccentLight,
                      BeanDesign.Palette.decorativeAccentDark] {
            XCTAssertGreaterThan(token.green, token.red)
            XCTAssertGreaterThan(token.green, token.blue)
        }
    }

    func testIncreasedContrastBordersRemainVisibleOnBrandAndCardSurfaces() {
        for surface in [BeanDesign.Palette.lightSurface, BeanDesign.Palette.brandBackgroundLight] {
            XCTAssertGreaterThanOrEqual(BeanDesign.Palette.strongBorderLight.contrastRatio(against: surface), 3)
        }
        for surface in [BeanDesign.Palette.cardBackgroundDark, BeanDesign.Palette.brandBackgroundDark] {
            XCTAssertGreaterThanOrEqual(BeanDesign.Palette.strongBorderDark.contrastRatio(against: surface), 3)
        }
    }

    func testDesktopControlsHaveComfortableMinimumTargets() {
        XCTAssertGreaterThanOrEqual(BeanDesign.minimumTargetSize, 28)
        XCTAssertGreaterThanOrEqual(BeanDesign.comfortableTargetSize, 32)
    }
}
