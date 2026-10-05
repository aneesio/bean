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
    private static let webAreaRole = "AXWebArea"
    // `kAXEditableAncestorAttribute` is missing from older macOS SDK headers
    // even though Chromium/Electron expose the stable AX attribute at runtime.
    // Keep the raw accessibility name so Bean still builds with the macOS 15
    // SDK used by GitHub-hosted runners.
    private static let editableAncestorAttribute = "AXEditableAncestor"
    private static let interactiveNonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXSwitch",
        "AXLink", "AXMenuItem", "AXPopUpButton", "AXTabGroup"
    ]
    private static let maximumFallbackTextLength = 200_000
    private static let messagingTimeout: Float = 0.1
    private static var preparedApplications = Set<pid_t>()
    private static let preparedApplicationsLock = NSLock()

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
        let app = NSWorkspace.shared.frontmostApplication
        if let app { prepareForAccessibility(in: app) }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        if let element = focusedElement(from: systemWide) { return element }

        // Chromium/Electron apps occasionally fail the system-wide focused-UI
        // query while still answering it on their application AX object.
        guard let app else { return nil }
        return focusedElement(in: app)
    }

    /// Reads focus from a specific application AX object. Callers must still
    /// confirm that the app is frontmost before sending synthetic keystrokes.
    static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        prepareForAccessibility(in: app)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, messagingTimeout)
        return focusedElement(from: root)
    }

    /// Electron and Chromium often leave their complete accessibility tree off
    /// until an assistive client asks for it. These application-local flags do
    /// not grant permission or change the user's system settings.
    static func prepareForAccessibility(in app: NSRunningApplication) {
        guard isTrusted else { return }
        preparedApplicationsLock.lock()
        if preparedApplications.count > 128 {
            preparedApplications.formIntersection(Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)))
        }
        let shouldPrepare = preparedApplications.insert(app.processIdentifier).inserted
        preparedApplicationsLock.unlock()
        guard shouldPrepare else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, messagingTimeout)
        // Ask by capability rather than a bundle allowlist: unrecognized
        // attributes are harmless no-ops in ordinary native applications.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private static func focusedElement(from root: AXUIElement) -> AXUIElement? {
        var focused: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let element = focused,
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
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

    /// Read only geometry/roles around the captured editor. No document text,
    /// labels or value attributes are requested. Opaque or excessively large
    /// nearby branches fail closed rather than covering an unknown control.
    @MainActor
    static func fieldOverlayGeometry(for element: AXUIElement,
                                     onDiagnostics: ((FieldOverlayGeometryCapture.Diagnostics) -> Void)? = nil) -> FieldOverlayGeometry? {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 0.030
        let names = [kAXRoleAttribute as String, kAXPositionAttribute as String, kAXSizeAttribute as String]

        func withinBudget() -> Bool { ProcessInfo.processInfo.systemUptime < deadline }
        func prepare(_ node: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(node, Float(min(remaining, 0.005)))
            return true
        }
        func attribute(_ node: AXUIElement, _ name: String) -> AXUIElement? {
            guard prepare(node) else { return nil }
            defer { AXUIElementSetMessagingTimeout(node, messagingTimeout) }
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success,
                  withinBudget(), let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func geometry(_ node: AXUIElement) -> FieldOverlayGeometryCapture.NodeGeometry? {
            guard prepare(node) else { return nil }
            defer { AXUIElementSetMessagingTimeout(node, messagingTimeout) }
            var copied: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(node, names as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0), &copied)
            guard withinBudget() else { return nil }
            guard result == .success, let values = copied as? [Any], values.count == names.count,
                  let role = values[0] as? String else {
                // Some neutral wrappers expose a role but do not implement a
                // geometry batch at all. Their complete child path can still
                // prove the editor/control rectangles without inventing bounds.
                guard prepare(node), let role = stringAttribute(node, kAXRoleAttribute as String), withinBudget() else { return nil }
                return .init(role: role, rect: nil)
            }
            guard CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID(),
                  CFGetTypeID(values[2] as CFTypeRef) == AXValueGetTypeID() else { return .init(role: role, rect: nil) }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(values[1] as! AXValue, .cgPoint, &point),
                  AXValueGetValue(values[2] as! AXValue, .cgSize, &size),
                  let primary = NSScreen.screens.first else { return .init(role: role, rect: nil) }
            let rect = CGRect(x: point.x, y: primary.frame.height - point.y - size.height,
                              width: size.width, height: size.height)
            return .init(role: role, rect: OverlayGeometry.isFiniteRect(rect) ? rect : nil)
        }
        func children(_ node: AXUIElement, limit: Int) -> [AXUIElement]? {
            guard prepare(node) else { return nil }
            defer { AXUIElementSetMessagingTimeout(node, messagingTimeout) }
            var count: CFIndex = 0
            let error = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count)
            // Unsupported is not proof of an empty subtree. Known semantic
            // leaves need no child read; unresolved containers fail closed.
            if error == .attributeUnsupported { return nil }
            guard error == .success, count >= 0, count <= limit, withinBudget() else { return nil }
            if count == 0 { return [] }
            var copied: CFArray?
            guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &copied) == .success,
                  withinBudget(), let values = copied as? [Any], values.count == count,
                  values.allSatisfy({ CFGetTypeID($0 as CFTypeRef) == AXUIElementGetTypeID() }) else { return nil }
            return values.map { $0 as! AXUIElement }
        }
        return FieldOverlayGeometryCapture.capture(element: element,
            window: { attribute($0, kAXWindowAttribute as String) }, geometry: geometry,
            parent: { attribute($0, kAXParentAttribute as String) }, children: children,
            isSame: isSameElement, now: { ProcessInfo.processInfo.systemUptime }, deadline: deadline,
            onDiagnostics: onDiagnostics)
    }

    // MARK: - Reading

    /// Reads a string attribute from an element, or nil.
    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? Bool
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func metadataAttributes(of element: AXUIElement, includeLabels: Bool) -> [String: Any]? {
        var names = [kAXRoleAttribute as String, kAXSubroleAttribute as String,
                     kAXEnabledAttribute as String, "AXEditable", "AXIsEditable", "AXReadOnly"]
        if includeLabels {
            names += [kAXTitleAttribute as String, kAXPlaceholderValueAttribute as String]
        }
        var copied: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &copied
        ) == .success, let values = copied as? [Any], values.count == names.count else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(names, values))
    }

    /// Reads the full text value (`kAXValueAttribute`) of a specific element.
    static func value(of element: AXUIElement) -> String? {
        guard !isSecureElement(element) else { return nil }
        // WebKit document editors expose a WebArea, whose AXValue can be an
        // empty placeholder even when its document contains text. Ask for the
        // complete element range, never its selection or visible descendants.
        let isWebArea = stringAttribute(element, kAXRoleAttribute as String) == webAreaRole
        if isWebArea,
           let text = fullTextMarkerText(of: element) { return text }
        if let text = stringAttribute(element, kAXValueAttribute as String),
           !isWebArea || !text.isEmpty { return text }
        // Rich editors such as Word may expose range text but no AXValue.
        // Never return a truncated document: replacement verifies the exact
        // complete snapshot and must not mistake an excerpt for the full field.
        var countValue: AnyObject?
        if AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &countValue
        ) == .success, let count = boundedTextLength(countValue) {
            if count == 0 { return "" }
            if let text = string(in: element, range: NSRange(location: 0, length: count)),
               (text as NSString).length == count { return text }
        }
        return fullTextMarkerText(of: element)
    }

    static func canReadFallbackText(characterCount: Int) -> Bool {
        characterCount >= 0 && characterCount <= maximumFallbackTextLength
    }

    static func selectedText(of element: AXUIElement) -> String? {
        guard !isSecureElement(element) else { return nil }
        let ordinaryText = stringAttribute(element, kAXSelectedTextAttribute as String)
        if let ordinaryText, !ordinaryText.isEmpty { return ordinaryText }
        if let range = selectedRange(of: element), range.length > 0,
           let text = string(in: element, range: range) { return text }
        guard let marker = copiedAttribute("AXSelectedTextMarkerRange", of: element) else { return ordinaryText }
        return text(forMarkerRange: marker, in: element) ?? ordinaryText
    }

    /// Opaque WebKit selections preserve the actual position of repeated text.
    /// They are kept only in memory and are never treated as numeric offsets.
    struct TextSelectionSnapshot {
        let text: String
        let range: NSRange?
        fileprivate let markerRange: CFTypeRef?
    }

    static func selectionSnapshot(of element: AXUIElement) -> TextSelectionSnapshot? {
        guard !isSecureElement(element) else { return nil }
        if let range = selectedRange(of: element), range.location >= 0, range.length > 0,
           let text = selectedText(of: element), (text as NSString).length == range.length {
            return TextSelectionSnapshot(text: text, range: range, markerRange: nil)
        }
        guard let marker = copiedAttribute("AXSelectedTextMarkerRange", of: element),
              let text = text(forMarkerRange: marker, in: element), !text.isEmpty else { return nil }
        return TextSelectionSnapshot(text: text, range: nil, markerRange: marker)
    }

    /// Text equality alone cannot prove which repeated occurrence is selected.
    static func selectionMatches(_ snapshot: TextSelectionSnapshot, on element: AXUIElement) -> Bool {
        guard let current = selectionSnapshot(of: element),
              current.text.utf16.elementsEqual(snapshot.text.utf16) else { return false }
        if let marker = snapshot.markerRange {
            guard let currentMarker = current.markerRange else { return false }
            return CFEqual(marker, currentMarker)
        }
        guard let range = snapshot.range else { return false }
        return current.range == range
    }

    private static func copiedAttribute(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func parameterizedAttribute(_ attribute: String, parameter: CFTypeRef,
                                               of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, attribute as CFString, parameter, &result
        ) == .success else { return nil }
        return result
    }

    private static func boundedTextLength(_ value: CFTypeRef?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let length = number.doubleValue
        guard length.isFinite, length >= 0, length <= Double(maximumFallbackTextLength),
              length.rounded(.down) == length else { return nil }
        return Int(length)
    }

    private static func text(forMarkerRange marker: CFTypeRef, in element: AXUIElement) -> String? {
        guard let count = boundedTextLength(parameterizedAttribute(
            "AXLengthForTextMarkerRange", parameter: marker, of: element
        )) else { return nil }
        if count == 0 { return "" }
        guard let text = parameterizedAttribute(
            "AXStringForTextMarkerRange", parameter: marker, of: element
        ) as? String, (text as NSString).length == count else { return nil }
        return text
    }

    private static func fullTextMarkerText(of element: AXUIElement) -> String? {
        guard let marker = parameterizedAttribute(
            "AXTextMarkerRangeForUIElement", parameter: element, of: element
        ) else { return nil }
        return text(forMarkerRange: marker, in: element)
    }

    /// Distinguishes a DOM editor from browser-owned controls such as the
    /// omnibox. Extension ownership must never hide native help in browser UI.
    /// Callers cache this value for the focused AX element; the scan is shallow
    /// and time bounded so a slow browser cannot stall every monitor tick.
    static func isBrowserWebContentField(_ field: FocusedField) -> Bool {
        guard field.acceptsTextInput, !field.isSecure else { return false }
        var element = field.element
        let deadline = Date().addingTimeInterval(0.2)
        for _ in 0..<16 {
            guard Date() < deadline,
                  let role = stringAttribute(element, kAXRoleAttribute as String) else { return false }
            switch role {
            case "AXWebArea": return true
            // Web pages can contain ARIA toolbars and dialogs (Gmail's compose
            // surface is one). Only the window boundary proves we have left
            // the web document; a toolbar role alone is not browser chrome.
            case "AXWindow", "AXApplication": return false
            default: break
            }
            guard Date() < deadline,
                  let parent = elementAttribute(element, kAXParentAttribute as String),
                  !isSameElement(element, parent) else { return false }
            AXUIElementSetMessagingTimeout(parent, messagingTimeout)
            element = parent
        }
        return false
    }

    /// Reads the full text value of the currently focused element.
    static func readFocusedValue() -> String? {
        focusedField()?.value
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

    @discardableResult
    static func setSelectedRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        guard range.location >= 0, range.length >= 0 else { return false }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, rangeValue
        ) == .success
    }

    /// A supported selected-text setter edits the editor's current span in its
    /// own model. Callers must prove the live range/source before this call;
    /// unlike a queued Paste, it cannot be routed to a later keyboard target.
    @discardableResult
    static func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        guard !isSecureElement(element), isSelectedTextSettable(element) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                           text as CFString) == .success
    }

    static func isSelectedTextSettable(_ element: AXUIElement) -> Bool {
        !isSecureElement(element) && isAttributeSettable(kAXSelectedTextAttribute as String, on: element)
    }

    /// Reads the substring for a range via AXStringForRange, or nil.
    static func string(in element: AXUIElement, range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0, !isSecureElement(element) else { return nil }
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
        guard isAttributeSettable(kAXSelectedTextRangeAttribute as String, on: element),
              isAttributeSettable(kAXSelectedTextAttribute as String, on: element) else { return false }
        let priorSelection = selectedRange(of: element)
        guard setSelectedRange(range, on: element) else { return false }
        let wrote = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success
        if !wrote, let priorSelection { setSelectedRange(priorSelection, on: element) }
        return wrote
    }

    /// Whether an element's value attribute can be written directly.
    static func isValueSettable(_ element: AXUIElement) -> Bool {
        isAttributeSettable(kAXValueAttribute as String, on: element)
    }

    static func isSelectedRangeSettable(_ element: AXUIElement) -> Bool {
        isAttributeSettable(kAXSelectedTextRangeAttribute as String, on: element)
    }

    private static func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            element, attribute as CFString, &settable
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
        let isSelectedTextSettable: Bool
        let isEnabled: Bool
        let hasEditableAncestor: Bool
        let isExplicitlyEditable: Bool?
        let isSelectedRangeSettable: Bool

        init(element: AXUIElement, role: String?, subrole: String?, value: String?,
             title: String?, placeholder: String?, isValueSettable: Bool,
             isSelectedTextSettable: Bool, isEnabled: Bool, hasEditableAncestor: Bool,
             isExplicitlyEditable: Bool? = nil, isSelectedRangeSettable: Bool = false) {
            self.element = element
            self.role = role
            self.subrole = subrole
            self.value = value
            self.title = title
            self.placeholder = placeholder
            self.isValueSettable = isValueSettable
            self.isSelectedTextSettable = isSelectedTextSettable
            self.isEnabled = isEnabled
            self.hasEditableAncestor = hasEditableAncestor
            self.isExplicitlyEditable = isExplicitlyEditable
            self.isSelectedRangeSettable = isSelectedRangeSettable
        }

        /// True when the focused element looks like an editable text control we
        /// can safely consider for text operations. A settable value by itself is
        /// not enough: sliders and other controls also expose writable AXValue.
        var isTextLike: Bool {
            AccessibilityService.isTextLike(
                role: role, subrole: subrole, hasEditableAncestor: hasEditableAncestor,
                isExplicitlyEditable: isExplicitlyEditable,
                isValueSettable: isValueSettable, isSelectedTextSettable: isSelectedTextSettable
            )
        }

        /// The focused item has an actual text-input semantic role (or a web
        /// editable ancestor), and is neither disabled nor secure. Electron can
        /// expose this correctly while denying direct AX writes.
        var isSemanticTextSurface: Bool {
            isEnabled && !isSecure && isTextLike
        }

        /// Conservative editability gate shared by the bubble, passive checks,
        /// inline checks, and whole-field replacement. Read-only/disabled text
        /// and non-text controls must never qualify.
        var acceptsTextInput: Bool {
            AccessibilityService.acceptsTextInput(
                isSemanticTextSurface: isSemanticTextSurface,
                isExplicitlyEditable: isExplicitlyEditable,
                hasEditableAncestor: hasEditableAncestor,
                isValueSettable: isValueSettable,
                isSelectedTextSettable: isSelectedTextSettable,
                isSelectedRangeSettable: isSelectedRangeSettable
            )
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
        guard let rawElement = focusedElement() else { return nil }
        return focusedField(from: rawElement, includeValue: true)
    }

    /// App-specific variant used after reactivating an Electron/browser source.
    static func focusedField(in app: NSRunningApplication) -> FocusedField? {
        guard let rawElement = focusedElement(in: app) else { return nil }
        return focusedField(from: rawElement, includeValue: true)
    }

    /// Metadata-only focused-field snapshot used by Setup & Status. It does not
    /// read AXValue, selected text, labels, or placeholders.
    static func focusedFieldMetadata(in app: NSRunningApplication) -> FocusedField? {
        guard let rawElement = focusedElement(in: app) else { return nil }
        return focusedField(from: rawElement, includeValue: false)
    }

    /// Direct AX writes and ordinary keyboard editing are separate capabilities.
    /// A focused editable text area can deny AXValue/AXSelectedText writes while
    /// allowing range selection followed by a normal paste.
    static func acceptsTextInput(isSemanticTextSurface: Bool,
                                 isExplicitlyEditable: Bool?,
                                 hasEditableAncestor: Bool,
                                 isValueSettable: Bool,
                                 isSelectedTextSettable: Bool,
                                 isSelectedRangeSettable: Bool) -> Bool {
        guard isSemanticTextSurface, isExplicitlyEditable != false else { return false }
        return isExplicitlyEditable == true || hasEditableAncestor || isValueSettable
            || isSelectedTextSettable || isSelectedRangeSettable
    }

    static func isTextLike(role: String?, subrole: String?, hasEditableAncestor: Bool,
                           isExplicitlyEditable: Bool?, isValueSettable: Bool,
                           isSelectedTextSettable: Bool) -> Bool {
        if let role, textRoles.contains(role) { return true }
        if subrole == searchSubrole || hasEditableAncestor { return true }
        // A WebArea can be a complete document editor or a read-only page.
        // Writable selection ranges alone are available on both, so require
        // actual text-editing evidence before inspecting document contents.
        return role == webAreaRole && isExplicitlyEditable != false
            && (isExplicitlyEditable == true || isValueSettable || isSelectedTextSettable)
    }

    private static func isSecureElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as String)
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        return (role?.contains("Secure") ?? false) || (subrole?.contains("Secure") ?? false)
    }

    private static func explicitEditability(of element: AXUIElement) -> Bool? {
        explicitEditability(readOnly: boolAttribute(element, "AXReadOnly"),
                            editable: boolAttribute(element, "AXEditable"),
                            isEditable: boolAttribute(element, "AXIsEditable"))
    }

    static func explicitEditability(readOnly: Bool?, editable: Bool?, isEditable: Bool?) -> Bool? {
        if readOnly == true || editable == false || isEditable == false { return false }
        if editable == true || isEditable == true { return true }
        return nil
    }

    private static func textElement(from rawElement: AXUIElement) -> (AXUIElement, Bool) {
        // Some web/custom editors report their focused leaf (static text) or a
        // grouping element rather than the editable container. Resolve only a
        // focus-related path; never search arbitrary document contents.
        let rawRole = stringAttribute(rawElement, kAXRoleAttribute as String)
        if let rawRole, textRoles.contains(rawRole) {
            if !isSecureElement(rawElement),
               let ancestor = elementAttribute(rawElement, editableAncestorAttribute),
               !isSecureElement(ancestor) {
                AXUIElementSetMessagingTimeout(ancestor, messagingTimeout)
                return (ancestor, true)
            }
            return (rawElement, false)
        }
        guard rawRole != nil else { return (rawElement, false) }
        var focused = rawElement
        for _ in 0..<4 {
            guard !isSecureElement(focused),
                  let next = elementAttribute(focused, kAXFocusedUIElementAttribute as String)
                    ?? elementAttribute(focused, "AXActiveDescendant"),
                  !isSameElement(next, focused) else { break }
            AXUIElementSetMessagingTimeout(next, messagingTimeout)
            focused = next
        }
        guard !isSecureElement(focused) else { return (focused, false) }
        let role = stringAttribute(focused, kAXRoleAttribute as String)
        if let role, interactiveNonTextRoles.contains(role) { return (focused, false) }
        if let ancestor = elementAttribute(focused, editableAncestorAttribute),
           !isSecureElement(ancestor) {
            AXUIElementSetMessagingTimeout(ancestor, messagingTimeout)
            return (ancestor, true)
        }
        if let role, textRoles.contains(role) { return (focused, false) }

        // A static-text leaf inside a native rich text control sometimes omits
        // AXEditableAncestor. Walk its enclosing chain, bounded at the window.
        guard role == "AXStaticText" || role == "AXGroup" || role == "AXUnknown" else {
            return (focused, false)
        }
        var candidate = focused
        for _ in 0..<3 {
            guard let parent = elementAttribute(candidate, kAXParentAttribute as String),
                  !isSameElement(candidate, parent) else { break }
            AXUIElementSetMessagingTimeout(parent, messagingTimeout)
            candidate = parent
            let parentRole = stringAttribute(parent, kAXRoleAttribute as String)
            if isSecureElement(parent) { return (parent, false) }
            if parentRole == "AXWindow" || parentRole == "AXApplication" { break }
            if let parentRole, interactiveNonTextRoles.contains(parentRole) { break }
            let editable = explicitEditability(of: parent)
            if let parentRole, (textRoles.contains(parentRole) || parentRole == webAreaRole),
               editable != false,
               editable == true || isValueSettable(parent)
                    || isAttributeSettable(kAXSelectedTextAttribute as String, on: parent)
                    || (textRoles.contains(parentRole) && isSelectedRangeSettable(parent)) {
                return (parent, true)
            }
        }
        return (focused, false)
    }

    static func focusedField(from rawElement: AXUIElement, includeValue: Bool = true) -> FocusedField? {
        AXUIElementSetMessagingTimeout(rawElement, messagingTimeout)
        let (element, hasEditableAncestor) = textElement(from: rawElement)
        guard let metadata = metadataAttributes(of: element, includeLabels: includeValue),
              let role = metadata[kAXRoleAttribute as String] as? String else { return nil }
        let subrole = metadata[kAXSubroleAttribute as String] as? String
        let secure = role.contains("Secure") || (subrole?.contains("Secure") ?? false)
        let enabled = metadata[kAXEnabledAttribute as String] as? Bool ?? true
        let editable = explicitEditability(readOnly: metadata["AXReadOnly"] as? Bool,
                                           editable: metadata["AXEditable"] as? Bool,
                                           isEditable: metadata["AXIsEditable"] as? Bool)
        let canProbeTextCapabilities = !secure && enabled && editable != false
            && (textRoles.contains(role) || role == webAreaRole
                || subrole == searchSubrole || hasEditableAncestor)
        let valueSettable = canProbeTextCapabilities && isValueSettable(element)
        let selectedTextSettable = canProbeTextCapabilities
            && isAttributeSettable(kAXSelectedTextAttribute as String, on: element)
        let semantic = isTextLike(role: role, subrole: subrole, hasEditableAncestor: hasEditableAncestor,
                                  isExplicitlyEditable: editable, isValueSettable: valueSettable,
                                  isSelectedTextSettable: selectedTextSettable)
        let canInspectText = !secure && semantic && enabled && editable != false
        return FocusedField(
            element: element,
            role: role,
            subrole: subrole,
            value: includeValue && canInspectText ? value(of: element) : nil,
            title: includeValue ? metadata[kAXTitleAttribute as String] as? String : nil,
            placeholder: includeValue ? metadata[kAXPlaceholderValueAttribute as String] as? String : nil,
            isValueSettable: canInspectText && valueSettable,
            isSelectedTextSettable: canInspectText && selectedTextSettable,
            isEnabled: enabled,
            hasEditableAncestor: hasEditableAncestor,
            isExplicitlyEditable: editable,
            isSelectedRangeSettable: canInspectText && isSelectedRangeSettable(element)
        )
    }
}
