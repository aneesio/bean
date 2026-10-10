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

    func testLiveDotPrefersTopRightWithWholeTargetInsideEditor() throws {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let size = try XCTUnwrap(OverlayGeometry.fieldControlSize(for: field))
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [])
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: geometry, panelSize: size, in: main.visibleFrame))
        XCTAssertEqual(size, CGSize(width: 28, height: 28))
        XCTAssertEqual(origin, CGPoint(x: field.maxX - 32, y: field.maxY - 32))
        XCTAssertTrue(field.contains(CGRect(origin: origin, size: size)))
        XCTAssertEqual(OverlayGeometry.statusDotDiameter, 8)
    }

    func testTopRightControlSlidesDotLeftAlongInsideTopEdge() throws {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let button = CGRect(x: 764, y: 508, width: 36, height: 32)
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [button])
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: geometry, panelSize: CGSize(width: 28, height: 28), in: main.visibleFrame))
        let target = CGRect(origin: origin, size: CGSize(width: 28, height: 28))
        XCTAssertEqual(origin.y, field.maxY - 32)
        XCTAssertLessThanOrEqual(target.maxX, button.minX - 2)
        XCTAssertTrue(field.contains(target))
        XCTAssertFalse(button.intersects(target))
    }

    func testBottomSendButtonAndOutsideToolbarCannotCoverInsideTopDot() throws {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let send = CGRect(x: 764, y: 300, width: 36, height: 36)
        let outside = CGRect(x: 800, y: 508, width: 40, height: 40)
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry:
            FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [send, outside]),
            panelSize: CGSize(width: 28, height: 28), in: main.visibleFrame))
        XCTAssertEqual(origin, CGPoint(x: 768, y: 508))
    }

    func testInsideFullEdgeSearchFindsClearGapMoreThanNinetySixPointsFromCorner() throws {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let left = CGRect(x: 300, y: 506, width: 175, height: 34)
        let right = CGRect(x: 520, y: 506, width: 280, height: 34)
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry:
            FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [left, right]),
            panelSize: CGSize(width: 28, height: 28), in: main.visibleFrame))
        XCTAssertEqual(origin.y, field.maxY - 32)
        XCTAssertGreaterThan(field.maxX - 32 - origin.x, 96)
        XCTAssertGreaterThanOrEqual(origin.x, left.maxX + 2)
        XCTAssertLessThanOrEqual(origin.x + 28, right.minX - 2)
    }

    func testFullscreenEditorStillShowsDotInsideTopRight() throws {
        let field = main.visibleFrame
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry:
            FieldOverlayGeometry(fieldRect: field, windowRect: field, exclusionRects: []),
            panelSize: CGSize(width: 28, height: 28), in: main.visibleFrame))
        XCTAssertEqual(origin, CGPoint(x: field.maxX - 32, y: field.maxY - 32))
        XCTAssertTrue(field.contains(CGRect(origin: origin, size: CGSize(width: 28, height: 28))))
    }

    func testPartlyClippedEditorUsesVisibleWindowAndNegativeOriginDisplay() throws {
        let field = CGRect(x: -1700, y: 0, width: 400, height: 700)
        let window = CGRect(x: -1800, y: -50, width: 800, height: 500)
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: window, exclusionRects: [])
        let size = CGSize(width: 28, height: 28)
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: geometry, panelSize: size, in: left.visibleFrame))
        let target = CGRect(origin: origin, size: size)
        XCTAssertEqual(origin, CGPoint(x: field.maxX - 32, y: window.maxY - 32))
        XCTAssertTrue(field.contains(target))
        XCTAssertTrue(window.contains(target))
        XCTAssertTrue(left.visibleFrame.contains(target))
    }

    func testKnownGlyphAndCaretRectsProtectTheCompleteInsideTarget() throws {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let glyph = CGRect(x: 600, y: 514, width: 190, height: 20)
        let caret = CGRect(x: 795, y: 514, width: 1, height: 20)
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [glyph, caret])
        let size = CGSize(width: 28, height: 28)
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: geometry, panelSize: size, in: main.visibleFrame))
        let target = CGRect(origin: origin, size: size)
        XCTAssertFalse(glyph.insetBy(dx: -2, dy: -2).intersects(target))
        XCTAssertFalse(caret.insetBy(dx: -2, dy: -2).intersects(target))
        XCTAssertTrue(field.contains(target))
    }

    func testTransparentTargetCornerCannotHideAnInternalButton() {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let target = CGRect(x: 768, y: 508, width: 28, height: 28)
        let button = CGRect(x: target.minX, y: target.minY, width: 3, height: 3)
        XCTAssertFalse(OverlayGeometry.isSafeFieldControlFrame(target,
            geometry: FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [button]),
            in: main.visibleFrame))
    }

    func testCompactSingleLineFieldsUseTwentyPointTargetAndAdaptivePadding() throws {
        let field = CGRect(x: 300, y: 300, width: 500, height: 22)
        let size = try XCTUnwrap(OverlayGeometry.fieldControlSize(for: field))
        XCTAssertEqual(size, CGSize(width: 20, height: 20))
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry:
            FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: []),
            panelSize: size, in: main.visibleFrame))
        XCTAssertEqual(origin, CGPoint(x: field.maxX - 22, y: field.minY + 1))
        XCTAssertTrue(field.contains(CGRect(origin: origin, size: size)))
        XCTAssertEqual(OverlayGeometry.fieldControlSize(for: CGRect(x: 0, y: 0, width: 300, height: 32)), CGSize(width: 28, height: 28))
        XCTAssertNil(OverlayGeometry.fieldControlSize(for: CGRect(x: 0, y: 0, width: 300, height: 19)))
    }

    func testUnknownBoundsAndFullyOccupiedEditorHaveNoOutsideFallback() {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let size = CGSize(width: 28, height: 28)
        XCTAssertNil(OverlayGeometry.issueTrayOrigin(geometry: nil, panelSize: size, in: main.visibleFrame))
        XCTAssertNil(OverlayGeometry.issueTrayOrigin(geometry:
            FieldOverlayGeometry(fieldRect: .null, windowRect: main.visibleFrame, exclusionRects: []), panelSize: size, in: main.visibleFrame))
        XCTAssertNil(OverlayGeometry.issueTrayOrigin(geometry:
            FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: [field]), panelSize: size, in: main.visibleFrame))
        XCTAssertNil(OverlayGeometry.issueTrayOrigin(geometry:
            FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: []),
            panelSize: CGSize(width: 10, height: 10), in: main.visibleFrame))
        XCTAssertFalse(OverlayGeometry.isSafeFieldControlFrame(CGRect(x: 804, y: 300, width: 28, height: 28),
            geometry: FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: []), in: main.visibleFrame))
    }

    func testCandidateSearchIsBoundedAndEveryTargetRemainsWithinEditor() {
        let field = CGRect(x: 300, y: 300, width: 500, height: 240)
        let obstacles = (0..<80).map { index in CGRect(x: 305 + CGFloat(index) * 6, y: 512, width: 2, height: 20) }
        let geometry = FieldOverlayGeometry(fieldRect: field, windowRect: main.visibleFrame, exclusionRects: obstacles)
        let candidates = OverlayGeometry.issueTrayCandidateFrames(geometry: geometry, panelSize: CGSize(width: 28, height: 28), in: main.visibleFrame)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertLessThanOrEqual(candidates.count, 96)
        XCTAssertEqual(Set(candidates.map { "\($0.origin.x):\($0.origin.y)" }).count, candidates.count)
        for target in candidates {
            XCTAssertTrue(OverlayGeometry.isSafeFieldControlFrame(target, geometry: geometry, in: main.visibleFrame))
        }
    }

    func testInlineCardMakesInvisibleSpacingAndDeletionUnderstandable() {
        XCTAssertEqual(InlineSuggestionDisplay.text("  "), "2 spaces")
        XCTAssertEqual(InlineSuggestionDisplay.text(" "), "1 space")
        XCTAssertEqual(InlineSuggestionDisplay.text(". "), ".␣")
        XCTAssertEqual(InlineSuggestionDisplay.text(""), "Remove")
        XCTAssertEqual(InlineSuggestionDisplay.text("the message"), "the message")
    }
}
