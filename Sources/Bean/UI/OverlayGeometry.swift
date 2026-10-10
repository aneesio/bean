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

/// A fresh, content-free view of the exact editor and known editor-local controls.
/// A missing field/window snapshot cannot establish an in-field pointer target.
struct FieldOverlayGeometry: Equatable {
    let fieldRect: CGRect
    let windowRect: CGRect
    let exclusionRects: [CGRect]
    var validatedNeighborhood: CGRect { fieldRect }
}

enum OverlayGeometry {
    /// Standard desktop pointer/keyboard target. Very short editors use the
    /// explicit compactFieldControlSize exception so their launcher can remain
    /// inside the field; other overlay controls retain this normal target.
    static let minimumMotorTarget: CGFloat = 28
    static let beanLauncherSize: CGFloat = minimumMotorTarget
    static let statusDotDiameter: CGFloat = 8
    static let compactFieldControlSize: CGFloat = 20

    /// Compact single-line fields retain a useful in-field target instead of
    /// forcing the normal target outside their bounds.
    static func fieldControlSize(for fieldRect: CGRect) -> CGSize? {
        guard isFiniteRect(fieldRect) else { return nil }
        let shortest = min(fieldRect.width, fieldRect.height)
        guard shortest >= compactFieldControlSize else { return nil }
        let side = shortest < minimumMotorTarget + 4 ? compactFieldControlSize : minimumMotorTarget
        return CGSize(width: side, height: side)
    }
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

    /// Validate the complete intercepting target, including transparent edges.
    /// The automatic launcher belongs to the editor; it never floats over an
    /// outside send button, toolbar or adjacent application's window.
    static func isSafeFieldControlFrame(_ frame: CGRect, geometry: FieldOverlayGeometry,
                                        in visibleFrame: CGRect, clearance: CGFloat = 2) -> Bool {
        guard isFiniteRect(frame), isFiniteRect(geometry.fieldRect),
              isFiniteRect(geometry.windowRect), isFiniteRect(visibleFrame),
              geometry.fieldRect.contains(frame), geometry.windowRect.contains(frame),
              visibleFrame.contains(frame),
              geometry.exclusionRects.allSatisfy({ isFiniteRect($0) && !$0.insetBy(dx: -clearance, dy: -clearance).intersects(frame) }) else { return false }
        return true
    }

    /// Prefer the visible editor's top-right corner, then slide along its
    /// inside edges to avoid local controls and protected text/caret rectangles.
    /// Fullscreen editors and fields touching a window edge use this same path.
    static func issueTrayOrigin(geometry: FieldOverlayGeometry?, panelSize: CGSize,
                                in visibleFrame: CGRect, gap: CGFloat = 4) -> CGPoint? {
        issueTrayCandidateFrames(geometry: geometry, panelSize: panelSize,
                                 in: visibleFrame, gap: gap).first?.origin
    }

    /// Ordered, finite candidates allow the presentation layer to perform an
    /// optional point hit-test of the actual target before showing a window.
    static func issueTrayCandidateFrames(geometry: FieldOverlayGeometry?, panelSize: CGSize,
                                        in visibleFrame: CGRect, gap: CGFloat = 4) -> [CGRect] {
        guard let geometry, panelSize.width.isFinite, panelSize.height.isFinite,
              panelSize.width >= compactFieldControlSize, panelSize.height >= compactFieldControlSize,
              gap.isFinite, gap >= 0,
              isFiniteRect(geometry.fieldRect), isFiniteRect(geometry.windowRect), isFiniteRect(visibleFrame),
              geometry.exclusionRects.allSatisfy(isFiniteRect) else { return [] }
        let allowed = geometry.fieldRect.intersection(geometry.windowRect).intersection(visibleFrame)
        guard isFiniteRect(allowed), allowed.width >= panelSize.width, allowed.height >= panelSize.height else { return [] }
        // A single-line editor can have exactly one target-height of space.
        // Reduce cosmetic padding, never shrink or move the target outside it.
        let padding = min(panelSize.width, panelSize.height) < minimumMotorTarget ? min(gap, 2) : gap
        let insetX = min(padding, max(0, (allowed.width - panelSize.width) / 2))
        let insetY = min(padding, max(0, (allowed.height - panelSize.height) / 2))
        let minX = allowed.minX + insetX, maxX = allowed.maxX - panelSize.width - insetX
        let minY = allowed.minY + insetY, maxY = allowed.maxY - panelSize.height - insetY
        let sides: [(vertical: Bool, normal: CGFloat, ideal: CGFloat)] = [
            (false, maxY, maxX), // top, starting at the right
            (true, maxX, maxY),  // right, starting at the top
            (false, minY, maxX),
            (true, minX, maxY)
        ]
        var result: [CGRect] = []
        for side in sides {
            let normalSize = side.vertical ? panelSize.width : panelSize.height
            let tangentSize = side.vertical ? panelSize.height : panelSize.width
            let lower = side.vertical ? minY : minX
            let upper = side.vertical ? maxY : maxX
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
            let tangents = free.flatMap { interval -> [CGFloat] in
                let nearest = min(max(side.ideal, interval.lowerBound), interval.upperBound)
                return [nearest, min(max(nearest + 0.5, interval.lowerBound), interval.upperBound),
                        min(max(nearest - 0.5, interval.lowerBound), interval.upperBound), interval.lowerBound]
            }.sorted { abs($0 - side.ideal) < abs($1 - side.ideal) }
            for tangent in tangents {
                let origin = side.vertical ? CGPoint(x: side.normal, y: tangent) : CGPoint(x: tangent, y: side.normal)
                let frame = CGRect(origin: origin, size: panelSize)
                if !result.contains(frame), isSafeFieldControlFrame(frame, geometry: geometry, in: visibleFrame) {
                    result.append(frame)
                    if result.count == 96 { return result }
                }
            }
        }
        return result
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
