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
        XCTAssertFalse(OverlayActivationIntent.pointer.allowsKeyboardInteraction,
                       "Accept must not activate Bean or move focus away from the writing field")
        XCTAssertTrue(OverlayActivationIntent.explicit.allowsKeyboardInteraction)
    }

    func testLiveDotUsesRightLowerEdgeAndWholeTargetStaysOutsideEditor() throws {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let size = CGSize(width: 28, height: 28)
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [])
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: geometry, panelSize: size, in: main.visibleFrame))
        let target = CGRect(origin: origin, size: size)
        XCTAssertFalse(field.intersects(target))
        XCTAssertTrue(main.visibleFrame.contains(target))
        XCTAssertEqual(origin, CGPoint(x: field.maxX + 4, y: field.minY))
        XCTAssertEqual(OverlayGeometry.statusDotDiameter, 10)
    }

    func testCrowdedSendButtonSlidesTargetAwayWithoutCoveringTextOrControls() throws {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let send = CGRect(x: field.maxX + 4, y: field.minY, width: 28, height: 28)
        let otherEdges = [CGRect(x: 300, y: 264, width: 500, height: 32),
                          CGRect(x: 264, y: 300, width: 32, height: 240),
                          CGRect(x: 300, y: 544, width: 500, height: 32)]
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [send] + otherEdges)
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: geometry, panelSize: CGSize(width: 28, height: 28), in: main.visibleFrame))
        XCTAssertEqual(origin.x, field.maxX + 4)
        XCTAssertGreaterThanOrEqual(origin.y, send.maxY + 2)
        XCTAssertLessThanOrEqual(origin.y, send.maxY + 3)
        XCTAssertFalse(send.intersects(CGRect(origin: origin, size: CGSize(width: 28, height: 28))))
    }

    func testFreeIntervalFindsNarrowClearSpaceBeyondOldNinetySixPointLimit() throws {
        let field = CGRect(x: 300, y: 300, width: 500, height: 500)
        let lowerButton = CGRect(x: 804, y: 300, width: 28, height: 113)
        let upperButton = CGRect(x: 804, y: 450, width: 28, height: 350)
        let result = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry:
            FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame,
                exclusionRects: [lowerButton, upperButton]), panelSize: CGSize(width: 28, height: 28), in: main.visibleFrame))
        XCTAssertEqual(result.x, 804)
        XCTAssertGreaterThan(result.y - field.minY, 96)
        XCTAssertGreaterThanOrEqual(result.y, lowerButton.maxY + 2)
        XCTAssertLessThanOrEqual(result.y + 28, upperButton.minY - 2)
    }

    func testFullEdgeSearchKeepsWindowViewportAndNegativeOriginConstraints() throws {
        let field = CGRect(x: -1700, y: 0, width: 400, height: 700)
        let window = CGRect(x: -1800, y: -50, width: 800, height: 500)
        let obstacle = CGRect(x: -1296, y: 0, width: 28, height: 200)
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: window, exclusionRects: [obstacle])
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: geometry,
            panelSize: CGSize(width: 28, height: 28), in: left.visibleFrame))
        let frame = CGRect(origin: origin, size: CGSize(width: 28, height: 28))
        XCTAssertGreaterThanOrEqual(origin.y, obstacle.maxY + 2)
        XCTAssertTrue(window.contains(frame))
        XCTAssertTrue(left.visibleFrame.contains(frame))
        XCTAssertTrue(geometry.validatedNeighborhood.contains(frame))
        XCTAssertFalse(obstacle.intersects(frame))
    }

    func testTransparentHitEdgesCannotCoverButtonEvenWhenVisibleDotDoesNot() {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let target = CGRect(x: field.maxX + 4, y: field.minY, width: 28, height: 28)
        let cornerButton = CGRect(x: target.minX, y: target.minY, width: 3, height: 3)
        XCTAssertFalse(OverlayGeometry.isSafeFieldControlFrame(target,
            geometry: FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [cornerButton]),
            in: main.visibleFrame))
    }

    func testDotHidesForUnknownBoundsFullscreenEditorAndAllCrowdedEdges() {
        let size = CGSize(width: 28, height: 28)
        XCTAssertNil(OverlayGeometry.issueTrayOrigin(geometry: nil, panelSize: size, in: left.visibleFrame))
        XCTAssertNil(OverlayGeometry.issueTrayOrigin(geometry: FieldOverlayGeometry(fieldRect: left.visibleFrame,
            windowRect: left.visibleFrame, exclusionRects: []), panelSize: size, in: left.visibleFrame))
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        XCTAssertNil(OverlayGeometry.issueTrayOrigin(geometry: FieldOverlayGeometry(fieldRect: field,
            windowRect: main.visibleFrame, exclusionRects: [field.insetBy(dx: -36, dy: -36)]), panelSize: size, in: main.visibleFrame))
    }

    func testDotUsesActualWindowAndNegativeOriginDisplayWithoutClamping() throws {
        let field = CGRect(x: -1700, y: 200, width: 400, height: 200)
        let window = CGRect(x: -1800, y: 150, width: 500, height: 400)
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: window, exclusionRects: [])
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: geometry,
            panelSize: CGSize(width: 28, height: 28), in: left.visibleFrame))
        XCTAssertEqual(origin, CGPoint(x: field.maxX - 28, y: field.minY - 32))
        XCTAssertTrue(window.contains(CGRect(origin: origin, size: CGSize(width: 28, height: 28))))
    }

    func testUnscannedDistantDragAndInvalidGeometryCannotCertifySafeTarget() {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [])
        let distant = CGRect(x: 1000, y: 300, width: 28, height: 28)
        XCTAssertTrue(main.visibleFrame.contains(distant))
        XCTAssertFalse(OverlayGeometry.isSafeFieldControlFrame(distant, geometry: geometry, in: main.visibleFrame),
            "Dragging beyond the scanned neighborhood must not authorize an unknown control")
        XCTAssertNil(OverlayGeometry.issueTrayOrigin(geometry: FieldOverlayGeometry(fieldRect: .null,
            windowRect: main.visibleFrame, exclusionRects: []), panelSize: CGSize(width: 28, height: 28), in: main.visibleFrame))
        XCTAssertNil(OverlayGeometry.issueTrayOrigin(geometry: geometry, panelSize: CGSize(width: 10, height: 10), in: main.visibleFrame))
    }

    func testInlineCardMakesInvisibleSpacingAndDeletionUnderstandable() {
        XCTAssertEqual(InlineSuggestionDisplay.text("  "), "2 spaces")
        XCTAssertEqual(InlineSuggestionDisplay.text(" "), "1 space")
        XCTAssertEqual(InlineSuggestionDisplay.text(". "), ".␣")
        XCTAssertEqual(InlineSuggestionDisplay.text(""), "Remove")
        XCTAssertEqual(InlineSuggestionDisplay.text("the message"), "the message")
    }
}
