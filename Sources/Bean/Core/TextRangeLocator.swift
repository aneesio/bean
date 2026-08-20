import AppKit
import ApplicationServices

// Maps an NSRange in a focused Accessibility element to on-screen rectangles,
// using AXBoundsForRange. Conservative: returns [] when bounds aren't available
// or look unreliable, which the caller treats as "not supported → fall back".
//
// It NEVER mutates the user's selection — it only reads parameterized bounds.
enum TextRangeLocator {

    /// Screen rect(s) (Cocoa, bottom-left origin) for `range` in `element`, or
    /// [] if unavailable/unreliable.
    static func screenRects(for range: NSRange, in element: AXUIElement) -> [CGRect] {
        guard range.length > 0, let axRect = boundsForRange(range, in: element) else { return [] }
        // Reject empty/degenerate rects.
        guard axRect.width > 0.5, axRect.height > 0.5 else { return [] }
        return [flipToCocoa(axRect)]
    }

    /// Probes whether bounds are reliable for this element (used by support
    /// detection). Tries the first character's bounds.
    static func boundsAreReliable(for element: AXUIElement, valueLength: Int) -> Bool {
        guard valueLength > 0 else { return false }
        guard let rect = boundsForRange(NSRange(location: 0, length: 1), in: element) else { return false }
        guard rect.width > 0.5, rect.height > 0.5 else { return false }
        // The probe rect should sit inside the element's own frame, if exposed.
        if let frame = elementFrame(element) {
            return frame.intersects(rect)
        }
        return true
    }

    /// Cocoa screen rect of the current selection in `element`, or nil.
    static func selectionRect(for element: AXUIElement) -> CGRect? {
        guard let sel = AccessibilityService.selectedRange(of: element), sel.length > 0 else { return nil }
        guard let rect = boundsForRange(sel, in: element), rect.width > 0.5, rect.height > 0.5 else { return nil }
        return flipToCocoa(rect)
    }

    /// Cocoa screen rect of the focused element's frame, or nil.
    static func fieldRect(for element: AXUIElement) -> CGRect? {
        elementFrame(element)
    }

    // MARK: - AX plumbing

    private static func boundsForRange(_ range: NSRange, in element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var result: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard err == .success, let value = result, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let pos = posValue, let size = sizeValue,
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dims = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &dims)
        return flipToCocoa(CGRect(origin: origin, size: dims))
    }

    /// AX coordinates are top-left origin on the primary display; convert to
    /// Cocoa global coordinates (bottom-left origin).
    private static func flipToCocoa(_ axRect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return axRect }
        let h = primary.frame.height
        return CGRect(x: axRect.origin.x,
                      y: h - axRect.origin.y - axRect.height,
                      width: axRect.width, height: axRect.height)
    }
}
