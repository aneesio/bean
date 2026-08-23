import AppKit
import XCTest
@testable import Bean

final class OverlayGeometryTests: XCTestCase {
    private let main = OverlayScreenArea(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 852)
    )
    private let left = OverlayScreenArea(
        frame: CGRect(x: -1920, y: -120, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: -90, width: 1900, height: 1050)
    )

    func testPointChoosesNegativeOriginDisplay() {
        let result = OverlayGeometry.screen(
            containing: CGPoint(x: -400, y: 300),
            from: [main, left]
        )
        XCTAssertEqual(result, left)
    }

    func testSourceRectChoosesDisplayWithLargestIntersection() {
        let crossing = CGRect(x: -100, y: 200, width: 250, height: 40)
        XCTAssertEqual(
            OverlayGeometry.screen(containing: crossing, from: [left, main]),
            main
        )
    }

    func testOffscreenAnchorFallsBackToNearestDisplay() {
        let point = CGPoint(x: -2_100, y: 300)
        XCTAssertEqual(
            OverlayGeometry.screen(containing: point, from: [main, left]),
            left
        )
    }

    func testClampingUsesNegativeVisibleFrameOrigin() {
        let origin = OverlayGeometry.clampedOrigin(
            CGPoint(x: -2_500, y: 1_200),
            panelSize: CGSize(width: 300, height: 200),
            in: left.visibleFrame,
            inset: 8
        )
        XCTAssertEqual(origin.x, -1_912, accuracy: 0.001)
        XCTAssertEqual(origin.y, 752, accuracy: 0.001)
    }

    func testCardFlipsBelowAndStaysInsideSourceDisplay() {
        let source = CGRect(x: -1_900, y: 900, width: 100, height: 30)
        let origin = OverlayGeometry.cardOrigin(
            anchoredTo: source,
            panelSize: CGSize(width: 300, height: 180),
            in: left.visibleFrame
        )
        XCTAssertEqual(origin.x, -1_912, accuracy: 0.001)
        XCTAssertEqual(origin.y, 712, accuracy: 0.001)
    }

    func testMenuFlipsAboveAccessoryAtBottomOfDisplay() {
        let origin = OverlayGeometry.menuOrigin(
            below: CGPoint(x: -500, y: -80),
            panelSize: CGSize(width: 220, height: 200),
            in: left.visibleFrame,
            accessoryHeight: OverlayGeometry.beanLauncherSize
        )
        XCTAssertEqual(origin.x, -500, accuracy: 0.001)
        XCTAssertEqual(origin.y, -48, accuracy: 0.001)
    }

    func testTopRightPlacementUsesNegativeDisplayCoordinates() {
        let origin = OverlayGeometry.topRightOrigin(
            panelSize: CGSize(width: 320, height: 140),
            in: left.visibleFrame
        )
        XCTAssertEqual(origin.x, -356, accuracy: 0.001)
        XCTAssertEqual(origin.y, 808, accuracy: 0.001)
    }

    func testHighlightInteractionIsOnlyAnUnderlineStrip() {
        let textRect = CGRect(x: 120, y: 200, width: 80, height: 22)
        let hitFrame = OverlayGeometry.highlightInteractionFrame(for: textRect)
        XCTAssertEqual(hitFrame.height, 6, accuracy: 0.001)
        XCTAssertLessThan(hitFrame.height, textRect.height)
        XCTAssertEqual(hitFrame.maxY, textRect.minY + 2, accuracy: 0.001)
        XCTAssertEqual(hitFrame.width, textRect.width + 4, accuracy: 0.001)
    }

    func testExpandedHighlightHoverTargetDoesNotExpandInterceptStrip() {
        let shortTextRect = CGRect(x: 120, y: 200, width: 4, height: 12)
        let intercept = OverlayGeometry.highlightInteractionFrame(for: shortTextRect)
        let hover = OverlayGeometry.highlightHoverFrame(for: shortTextRect)

        XCTAssertEqual(intercept.height, OverlayGeometry.highlightInteractionHeight, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(hover.width, OverlayGeometry.minimumMotorTarget)
        XCTAssertGreaterThanOrEqual(hover.height, OverlayGeometry.minimumMotorTarget)
        XCTAssertTrue(hover.contains(intercept))
    }

    func testBeanLauncherUsesMinimumMotorTarget() {
        XCTAssertGreaterThanOrEqual(OverlayGeometry.minimumMotorTarget, 28)
        XCTAssertEqual(
            OverlayGeometry.beanLauncherSize,
            OverlayGeometry.minimumMotorTarget,
            accuracy: 0.001
        )
    }

    func testOnlyExplicitActivationRequestsKeyboardInteraction() {
        XCTAssertFalse(OverlayActivationIntent.passiveHover.allowsKeyboardInteraction)
        XCTAssertTrue(OverlayActivationIntent.explicit.allowsKeyboardInteraction)
    }
}
