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
        let rect = flipToCocoa(axRect)
        // AX can return geometry for text scrolled outside its editor. Never
        // draw an underline over another control or another app's window.
        if let frame = elementFrame(element), !frame.contains(rect) { return [] }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return [] }
        return [rect]
    }

    /// Probes whether bounds are reliable for this element (used by support
    /// detection). Probe a composed character near the caret before trying the
    /// start, which may be scrolled offscreen or begin with a multi-unit emoji.
    static func boundsAreReliable(for element: AXUIElement, value: String) -> Bool {
        let text = value as NSString
        guard text.length > 0 else { return false }
        let location = min(max(AccessibilityService.selectedRange(of: element)?.location ?? 0, 0), text.length - 1)
        let ranges = [text.rangeOfComposedCharacterSequence(at: location),
                      text.rangeOfComposedCharacterSequence(at: 0)]
        for range in ranges {
            guard let rect = boundsForRange(range, in: element),
                  rect.width > 0.5, rect.height > 0.5 else { continue }
            if let frame = elementFrame(element), !frame.intersects(flipToCocoa(rect)) { continue }
            return true
        }
        return false
    }

    /// Cocoa screen rect of the current selection in `element`, or nil.
    static func selectionRect(for element: AXUIElement) -> CGRect? {
        guard let sel = AccessibilityService.selectedRange(of: element), sel.length > 0 else { return nil }
        guard let rect = boundsForRange(sel, in: element), rect.width > 0.5, rect.height > 0.5 else { return nil }
        return flipToCocoa(rect)
    }

    /// A zero-length range locates the insertion point without selecting text.
    static func caretRect(for element: AXUIElement) -> CGRect? {
        guard let selection = AccessibilityService.selectedRange(of: element),
              selection.length == 0,
              let bounds = boundsForRange(selection, in: element), bounds.height > 0.5 else { return nil }
        let rect = flipToCocoa(CGRect(x: bounds.minX, y: bounds.minY,
                                      width: max(bounds.width, 1), height: bounds.height))
        if let frame = elementFrame(element), !frame.intersects(rect) { return nil }
        return rect
    }

    /// Cocoa screen rect of the focused element's frame, or nil.
    static func fieldRect(for element: AXUIElement) -> CGRect? {
        elementFrame(element)
    }

    /// Protect exposed visible glyphs without changing selection or requiring
    /// every editor to implement range geometry. Missing range APIs retain a
    /// best-effort corner; exact field/control/caret checks still apply.
    static func fieldControlTextRects(in element: AXUIElement, value: String, fieldRect: CGRect) -> [CGRect] {
        guard !value.isEmpty, OverlayGeometry.isFiniteRect(fieldRect) else { return [] }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.012
        AXUIElementSetMessagingTimeout(element, 0.002)
        defer { AXUIElementSetMessagingTimeout(element, 0.1) }
        var visibleRange: NSRange?
        var copied: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &copied) == .success,
           let copied, CFGetTypeID(copied) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(copied as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 {
                visibleRange = NSRange(location: range.location, length: range.length)
            }
        }
        var rectangles: [CGRect] = []
        for range in fieldControlTextRanges(value: value, visibleRange: visibleRange) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard let bounds = boundsForRange(range, in: element) else { continue }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            let clipped = flipToCocoa(bounds).intersection(fieldRect)
            if OverlayGeometry.isFiniteRect(clipped) { rectangles.append(clipped) }
        }
        return rectangles
    }

    /// A bounded UTF-16 plan for the visible beginning/end of a draft. Keeping
    /// separate line/chunk boxes avoids a whole-document union covering blank
    /// corners between paragraphs. No unbounded per-character AX loop occurs.
    static func fieldControlTextRanges(value: String, visibleRange: NSRange?) -> [NSRange] {
        let text = value as NSString
        guard text.length > 0 else { return [] }
        let start = min(max(visibleRange?.location ?? 0, 0), text.length - 1)
        let length = visibleRange.map { min(max($0.length, 0), text.length - start) } ?? (text.length - start)
        let end = min(text.length, start + max(length, 1))
        var locations = [start]
        if end - start > 512 { locations.append(max(start, end - 512)) }
        var result: [NSRange] = []
        for initial in locations {
            var cursor = initial
            var inspectedLines = 0
            var added = 0
            let limit = locations.count > 1 ? 3 : 6
            while cursor < end, inspectedLines < 8, added < limit {
                inspectedLines += 1
                let line = text.lineRange(for: NSRange(location: cursor, length: 0))
                let upper = min(min(NSMaxRange(line), end), cursor + 512)
                guard upper > cursor else { break }
                let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: cursor, length: upper - cursor))
                if !result.contains(range), !text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(range); added += 1
                }
                // Each logical line is sampled once; long paragraphs get the
                // visible-end sample rather than thousands of AX requests.
                cursor = max(NSMaxRange(line), upper)
            }
        }
        return result
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
