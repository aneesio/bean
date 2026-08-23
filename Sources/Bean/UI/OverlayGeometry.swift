import AppKit
import ApplicationServices

enum OverlayActivationIntent: Equatable {
    case passiveHover
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

enum OverlayGeometry {
    /// Bean's smallest pointer/keyboard target. The visible launcher and all
    /// compact overlay controls use this same value so their hit geometry never
    /// silently shrinks below the product's desktop accessibility floor.
    static let minimumMotorTarget: CGFloat = 28
    static let beanLauncherSize: CGFloat = minimumMotorTarget
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

    private init(sourceApplication: NSRunningApplication?, focusedElement: AXUIElement?) {
        self.sourceApplication = sourceApplication
        self.focusedElement = focusedElement
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
            AXUIElementSetAttributeValue(
                focusedElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
    }
}
