import AppKit
import ApplicationServices

// Thin wrapper over the Accessibility (AX) API.
//
// Used for:
//   1. Reporting / prompting for the Accessibility permission.
//   2. Inspecting the focused element (role, subrole, editability) so Bean can
//      decide whether it's safe to read/replace the whole field.
//   3. Reading a field's text value before/after a change, so replacement can
//      be VERIFIED rather than assumed.
//   4. Writing a field's value directly when the element clearly supports it.
//
// IMPORTANT: AX reads/writes and synthetic keystrokes all require the app to be
// trusted for Accessibility in System Settings. Without it the reads return nil
// and the synthetic Cmd+C/Cmd+V/Cmd+A are dropped.
enum AccessibilityService {

    // Known AX role / subrole strings we treat as "text-like" (safe to operate
    // on the whole field). Kept as raw strings because the Carbon constants are
    // CFStrings that are awkward to compare directly.
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox"
    ]
    private static let searchSubrole = "AXSearchField"

    // MARK: - Permission

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func promptForTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Focused element

    /// The focused UI element across the whole system (inside whatever app is
    /// frontmost), or nil if it can't be resolved.
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    static var hasFocusedElement: Bool {
        focusedElement() != nil
    }

    /// True if two AX element references point at the same underlying element.
    /// Used to confirm focus hasn't moved before we replace a field.
    static func isSameElement(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        CFEqual(a, b)
    }

    // MARK: - Reading

    /// Reads a string attribute from an element, or nil.
    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    /// Reads the full text value (`kAXValueAttribute`) of a specific element.
    static func value(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXValueAttribute as String)
    }

    /// Reads the full text value of the currently focused element.
    static func readFocusedValue() -> String? {
        guard let element = focusedElement() else { return nil }
        return value(of: element)
    }

    /// Reads the current selection range of an element (kAXSelectedTextRange).
    static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Reads the substring for a range via AXStringForRange, or nil.
    static func string(in element: AXUIElement, range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result)
        guard err == .success else { return nil }
        return result as? String
    }

    /// Replaces a single range by selecting it then setting the selected text.
    /// Returns true only on success. Used for single-issue inline apply.
    @discardableResult
    static func replaceRange(_ range: NSRange, with text: String, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Whether an element's value attribute can be written directly.
    static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable
        )
        return result == .success && settable.boolValue
    }

    // MARK: - Writing

    /// Writes `text` to an element's value attribute. Returns true only on a
    /// successful AX write. Callers MUST still verify by re-reading, because a
    /// few apps report success without changing anything.
    @discardableResult
    static func setValue(_ text: String, on element: AXUIElement) -> Bool {
        let result = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, text as CFString
        )
        return result == .success
    }

    // MARK: - Focused field snapshot

    /// A snapshot of the focused element's relevant AX attributes.
    ///
    /// `title` / `placeholder` are read ONLY for local search-field detection
    /// and are never sent to the LLM (they're field labels like "Search", not
    /// user content, but we keep them local to be safe).
    struct FocusedField {
        let element: AXUIElement
        let role: String?
        let subrole: String?
        let value: String?
        let title: String?
        let placeholder: String?
        let isValueSettable: Bool

        /// True when the focused element looks like an editable text control we
        /// can safely operate on as a whole (text field, text area, combo box,
        /// or anything that advertises a settable value).
        var isTextLike: Bool {
            if let role, AccessibilityService.textRoles.contains(role) { return true }
            if let subrole, subrole == AccessibilityService.searchSubrole { return true }
            return isValueSettable
        }

        /// True when this is a small, conservative field (search box / address
        /// bar / URL field) where Bean should avoid turning a query into a
        /// sentence. Detected via subrole first, then field label/placeholder.
        var isSearchLike: Bool {
            if subrole == AccessibilityService.searchSubrole { return true }
            let hints = [title, placeholder].compactMap { $0?.lowercased() }
            return hints.contains { hint in
                hint.contains("search") || hint.contains("address")
                    || hint.contains("url") || hint.contains("website")
            }
        }

        /// True for password / secure text fields — Bean must never read these.
        var isSecure: Bool {
            (role?.contains("Secure") ?? false) || (subrole?.contains("Secure") ?? false)
        }
    }

    /// Captures the current focused element with its role/subrole/value, or nil
    /// if nothing is focused.
    static func focusedField() -> FocusedField? {
        guard let element = focusedElement() else { return nil }
        return FocusedField(
            element: element,
            role: stringAttribute(element, kAXRoleAttribute as String),
            subrole: stringAttribute(element, kAXSubroleAttribute as String),
            value: value(of: element),
            title: stringAttribute(element, kAXTitleAttribute as String),
            placeholder: stringAttribute(element, kAXPlaceholderValueAttribute as String),
            isValueSettable: isValueSettable(element)
        )
    }
}
