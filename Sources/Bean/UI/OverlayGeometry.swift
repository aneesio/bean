import AppKit
import ApplicationServices

enum OverlayActivationIntent: Equatable {
    case passiveHover
    case pointer
    case explicit

    var allowsKeyboardInteraction: Bool { self == .explicit }
}

/// Content-free geometry used by Bean's transient UI. Keeping screen selection
/// and clamping pure makes arrangements with negative origins testable without
/// creating real windows or depending on whichever display macOS calls “main.”
struct OverlayScreenArea: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect

    @MainActor
    static var current: [OverlayScreenArea] {
        NSScreen.screens.map { OverlayScreenArea(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
}

/// A fresh, content-free view of the exact editor and its surrounding controls.
/// A missing/incomplete snapshot cannot establish a safe pointer target.
struct FieldOverlayGeometry: Equatable {
    let fieldRect: CGRect
    let windowRect: CGRect
    let exclusionRects: [CGRect]
    var validatedNeighborhood: CGRect { fieldRect.insetBy(dx: -36, dy: -36) }
}

enum OverlayGeometry {
    /// Bean's smallest pointer/keyboard target. The visible launcher and all
    /// compact overlay controls use this same value so their hit geometry never
    /// silently shrinks below the product's desktop accessibility floor.
    static let minimumMotorTarget: CGFloat = 28
    static let beanLauncherSize: CGFloat = minimumMotorTarget
    static let statusDotDiameter: CGFloat = 10
    static let highlightInteractionHeight: CGFloat = 6

    /// Chooses the display containing the anchor. If the point lies in a gap or
    /// just beyond an edge, use the physically nearest display.
    static func screen(containing point: CGPoint, from screens: [OverlayScreenArea]) -> OverlayScreenArea? {
        if let containing = screens.first(where: { $0.frame.contains(point) }) {
            return containing
        }
        return screens.min {
            squaredDistance(from: point, to: $0.frame)
                < squaredDistance(from: point, to: $1.frame)
        }
    }

    /// A caret/range can straddle a display boundary. Pick the display containing
    /// the largest portion of the source rect, then fall back to its center.
    static func screen(containing sourceRect: CGRect, from screens: [OverlayScreenArea]) -> OverlayScreenArea? {
        guard !screens.isEmpty else { return nil }
        let rect = sourceRect.standardized
        let intersections = screens.map { screen -> (OverlayScreenArea, CGFloat) in
            let intersection = screen.frame.intersection(rect)
            let area = intersection.isNull ? 0 : max(intersection.width, 0) * max(intersection.height, 0)
            return (screen, area)
        }
        if let best = intersections.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }
        return screen(containing: CGPoint(x: rect.midX, y: rect.midY), from: screens)
    }

    /// Keeps a panel inside one display's visible frame. The calculation uses
    /// the frame's real origin, so left/below displays work without special cases.
    static func clampedOrigin(
        _ proposed: CGPoint,
        panelSize: CGSize,
        in visibleFrame: CGRect,
        inset: CGFloat
    ) -> CGPoint {
        let visible = visibleFrame.standardized
        let lowerX = visible.minX + inset
        let lowerY = visible.minY + inset
        let upperX = max(lowerX, visible.maxX - inset - panelSize.width)
        let upperY = max(lowerY, visible.maxY - inset - panelSize.height)
        return CGPoint(
            x: min(max(proposed.x, lowerX), upperX),
            y: min(max(proposed.y, lowerY), upperY)
        )
    }

    /// Places an interactive card above its source when possible, otherwise
    /// below it, and then clamps the result to that source display.
    static func cardOrigin(
        anchoredTo sourceRect: CGRect,
        panelSize: CGSize,
        in visibleFrame: CGRect,
        gap: CGFloat = 8,
        inset: CGFloat = 8
    ) -> CGPoint {
        let visible = visibleFrame.standardized
        var proposed = CGPoint(
            x: sourceRect.midX - panelSize.width / 2,
            y: sourceRect.maxY + gap
        )
        if proposed.y + panelSize.height > visible.maxY - inset {
            proposed.y = sourceRect.minY - panelSize.height - gap
        }
        return clampedOrigin(proposed, panelSize: panelSize, in: visible, inset: inset)
    }

    /// Places the Bean menu below its accessory, flipping above when needed.
    static func menuOrigin(
        below anchor: CGPoint,
        panelSize: CGSize,
        in visibleFrame: CGRect,
        accessoryHeight: CGFloat,
        gap: CGFloat = 4,
        inset: CGFloat = 8
    ) -> CGPoint {
        let visible = visibleFrame.standardized
        var proposed = CGPoint(x: anchor.x, y: anchor.y - panelSize.height - gap)
        if proposed.y < visible.minY + inset {
            proposed.y = anchor.y + accessoryHeight + gap
        }
        return clampedOrigin(proposed, panelSize: panelSize, in: visible, inset: inset)
    }

    static func topRightOrigin(
        panelSize: CGSize,
        in visibleFrame: CGRect,
        horizontalInset: CGFloat = 16,
        verticalInset: CGFloat = 12
    ) -> CGPoint {
        let proposed = CGPoint(
            x: visibleFrame.maxX - panelSize.width - horizontalInset,
            y: visibleFrame.maxY - panelSize.height - verticalInset
        )
        return clampedOrigin(
            proposed,
            panelSize: panelSize,
            in: visibleFrame,
            inset: min(horizontalInset, verticalInset)
        )
    }

    /// Validate the entire intercepting panel, including its transparent edges.
    /// Never move an automatic control into an editor to keep it visible.
    static func isSafeFieldControlFrame(_ frame: CGRect, geometry: FieldOverlayGeometry,
                                        in visibleFrame: CGRect, clearance: CGFloat = 2) -> Bool {
        guard isFiniteRect(frame), isFiniteRect(geometry.fieldRect),
              isFiniteRect(geometry.windowRect), isFiniteRect(visibleFrame),
              geometry.windowRect.contains(frame), visibleFrame.contains(frame),
              geometry.validatedNeighborhood.contains(frame),
              !geometry.fieldRect.insetBy(dx: -clearance, dy: -clearance).intersects(frame),
              geometry.exclusionRects.allSatisfy({ isFiniteRect($0) && !$0.insetBy(dx: -clearance, dy: -clearance).intersects(frame) }) else { return false }
        return true
    }

    /// Search the verified free intervals along each editor edge. Obstacles
    /// cannot force an inside-field fallback or a fixed-distance search cutoff.
    static func issueTrayOrigin(geometry: FieldOverlayGeometry?, panelSize: CGSize,
                                in visibleFrame: CGRect, gap: CGFloat = 4) -> CGPoint? {
        guard let geometry, panelSize.width.isFinite, panelSize.height.isFinite,
              panelSize.width >= minimumMotorTarget, panelSize.height >= minimumMotorTarget,
              isFiniteRect(geometry.fieldRect), isFiniteRect(geometry.windowRect), isFiniteRect(visibleFrame),
              geometry.exclusionRects.allSatisfy(isFiniteRect) else { return nil }
        let field = geometry.fieldRect
        let allowed = geometry.windowRect.intersection(visibleFrame).intersection(geometry.validatedNeighborhood)
        guard isFiniteRect(allowed), allowed.width >= panelSize.width, allowed.height >= panelSize.height else { return nil }
        let sides: [(vertical: Bool, normal: CGFloat, ideal: CGFloat)] = [
            (true, field.maxX + gap, field.minY),
            (false, field.minY - panelSize.height - gap, field.maxX - panelSize.width),
            (true, field.minX - panelSize.width - gap, field.minY),
            (false, field.maxY + gap, field.maxX - panelSize.width)
        ]
        for side in sides {
            let normalSize = side.vertical ? panelSize.width : panelSize.height
            let tangentSize = side.vertical ? panelSize.height : panelSize.width
            let normalMin = side.vertical ? allowed.minX : allowed.minY
            let normalMax = side.vertical ? allowed.maxX : allowed.maxY
            guard side.normal >= normalMin, side.normal + normalSize <= normalMax else { continue }
            let fieldMin = side.vertical ? field.minY : field.minX
            let fieldMax = (side.vertical ? field.maxY : field.maxX) - tangentSize
            let lower = max(min(fieldMin, fieldMax), side.vertical ? allowed.minY : allowed.minX)
            let upper = min(max(fieldMin, fieldMax), (side.vertical ? allowed.maxY : allowed.maxX) - tangentSize)
            guard lower <= upper else { continue }
            var free: [ClosedRange<CGFloat>] = [lower...upper]
            for obstacle in geometry.exclusionRects {
                let expanded = obstacle.insetBy(dx: -2, dy: -2)
                let obstacleNormalMin = side.vertical ? expanded.minX : expanded.minY
                let obstacleNormalMax = side.vertical ? expanded.maxX : expanded.maxY
                guard obstacleNormalMin < side.normal + normalSize, obstacleNormalMax > side.normal else { continue }
                let blockedLower = (side.vertical ? expanded.minY : expanded.minX) - tangentSize
                let blockedUpper = side.vertical ? expanded.maxY : expanded.maxX
                free = free.flatMap { interval -> [ClosedRange<CGFloat>] in
                    if blockedUpper <= interval.lowerBound || blockedLower >= interval.upperBound { return [interval] }
                    var remaining: [ClosedRange<CGFloat>] = []
                    if blockedLower >= interval.lowerBound { remaining.append(interval.lowerBound...blockedLower) }
                    if blockedUpper <= interval.upperBound { remaining.append(blockedUpper...interval.upperBound) }
                    return remaining
                }
            }
            let candidates = free.flatMap { interval -> [CGFloat] in
                let nearest = min(max(side.ideal, interval.lowerBound), interval.upperBound)
                // Geometry APIs can treat touching bounds differently. Validate
                // an interior point too, without crossing any blocked interval.
                return [nearest, min(max(nearest + 0.5, interval.lowerBound), interval.upperBound),
                        min(max(nearest - 0.5, interval.lowerBound), interval.upperBound)]
            }.sorted { abs($0 - side.ideal) < abs($1 - side.ideal) }
            for tangent in candidates {
                let origin = side.vertical ? CGPoint(x: side.normal, y: tangent) : CGPoint(x: tangent, y: side.normal)
                if isSafeFieldControlFrame(CGRect(origin: origin, size: panelSize), geometry: geometry, in: visibleFrame) { return origin }
            }
        }
        return nil
    }

    static func isFiniteRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    /// Only the underline and a two-point overlap with the glyph box receive
    /// mouse events. The rest of the text rect remains available for caret and
    /// selection interaction in the source application.
    static func highlightInteractionFrame(for sourceRect: CGRect) -> CGRect {
        CGRect(
            x: sourceRect.minX - 2,
            y: sourceRect.minY - 4,
            width: max(sourceRect.width + 4, 4),
            height: highlightInteractionHeight
        )
    }

    /// Hover discovery can be forgiving without placing a window over the text.
    /// This region is observed through global mouse location only, so it never
    /// consumes a click or blocks caret placement. The actual intercepting panel
    /// deliberately remains the six-point underline strip above.
    static func highlightHoverFrame(for sourceRect: CGRect) -> CGRect {
        let sourceAndUnderline = sourceRect.standardized.union(
            highlightInteractionFrame(for: sourceRect)
        )
        let width = max(sourceAndUnderline.width, minimumMotorTarget)
        let height = max(sourceAndUnderline.height, minimumMotorTarget)
        return CGRect(
            x: sourceAndUnderline.midX - width / 2,
            y: sourceAndUnderline.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let standardized = rect.standardized
        let dx = max(max(standardized.minX - point.x, 0), point.x - standardized.maxX)
        let dy = max(max(standardized.minY - point.y, 0), point.y - standardized.maxY)
        return dx * dx + dy * dy
    }
}

/// Captures the source application and focused AX element immediately before an
/// explicitly opened overlay becomes key. Restoration is best-effort and only
/// occurs while either Bean or that original app remains frontmost; Bean never
/// steals the user back from a third app they deliberately switched to.
@MainActor
final class OverlaySourceFocusSession {
    private let sourceApplication: NSRunningApplication?
    private let focusedElement: AXUIElement?
    private let sourceValue: String?
    private let selectedRange: NSRange?

    private init(sourceApplication: NSRunningApplication?, focusedElement: AXUIElement?) {
        self.sourceApplication = sourceApplication
        self.focusedElement = focusedElement
        self.sourceValue = focusedElement.flatMap { AccessibilityService.value(of: $0) }
        self.selectedRange = focusedElement.flatMap { AccessibilityService.selectedRange(of: $0) }
    }

    static func capture() -> OverlaySourceFocusSession {
        let application = NSWorkspace.shared.frontmostApplication
        let beanPID = ProcessInfo.processInfo.processIdentifier
        guard application?.processIdentifier != beanPID else {
            return OverlaySourceFocusSession(sourceApplication: nil, focusedElement: nil)
        }
        return OverlaySourceFocusSession(
            sourceApplication: application,
            focusedElement: AccessibilityService.focusedElement()
        )
    }

    func restoreIfAppropriate() {
        guard let sourceApplication, !sourceApplication.isTerminated else { return }
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let beanPID = ProcessInfo.processInfo.processIdentifier
        guard currentPID == sourceApplication.processIdentifier || currentPID == beanPID else {
            return
        }

        if currentPID == beanPID {
            if #available(macOS 14.0, *) {
                sourceApplication.activate()
            } else {
                sourceApplication.activate(options: [])
            }
        }
        if let focusedElement {
            // A source-field click can dismiss an overlay after focus has
            // already moved. Never pull that click back to the previous field.
            if currentPID == sourceApplication.processIdentifier,
               let current = AccessibilityService.focusedElement(),
               !AccessibilityService.isSameElement(current, focusedElement) { return }
            AXUIElementSetAttributeValue(
                focusedElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            if let sourceValue, AccessibilityService.value(of: focusedElement) == sourceValue,
               let selectedRange {
                AccessibilityService.setSelectedRange(selectedRange, on: focusedElement)
            }
        }
    }
}
