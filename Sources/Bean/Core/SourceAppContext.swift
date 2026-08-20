import AppKit

// Where the text Bean is about to fix came from.
enum TextInputMode {
    case selectedText        // the user had an explicit selection
    case focusedFieldFullText // no selection; we took the whole focused field

    var contextLabel: String {
        switch self {
        case .selectedText: return "selection"
        case .focusedFieldFullText: return "fullField"
        }
    }

    /// Explicit label used in the `<context>` block of the correction request.
    var rawLabel: String {
        switch self {
        case .selectedText: return "selectedText"
        case .focusedFieldFullText: return "focusedFieldFullText"
        }
    }
}

// Minimal, non-sensitive context about the source app and focused field.
//
// PRIVACY: this deliberately excludes window titles and any surrounding app
// content — only app identity and the focused field's structural role, which
// don't contain user text.
struct SourceAppContext {
    var appName: String?
    var bundleIdentifier: String?
    var processIdentifier: pid_t?
    var focusedRole: String?
    var focusedSubrole: String?
    var acquisitionMode: TextInputMode
    /// Derived locally from the focused field (subrole/label/placeholder); used
    /// only to select conservative guidance, never sent verbatim.
    var isSearchLikeField: Bool

    /// Builds a context from the frontmost app and an optional focused field.
    static func current(
        app: NSRunningApplication?,
        field: AccessibilityService.FocusedField?,
        mode: TextInputMode
    ) -> SourceAppContext {
        SourceAppContext(
            appName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier,
            focusedRole: field?.role,
            focusedSubrole: field?.subrole,
            acquisitionMode: mode,
            isSearchLikeField: field?.isSearchLike ?? false
        )
    }

    /// Short, human-readable description for OPERATIONAL logs only (no text).
    var logDescription: String {
        let name = appName ?? "unknown app"
        switch acquisitionMode {
        case .selectedText: return "selected text from \(name)"
        case .focusedFieldFullText: return "focused field full text from \(name)"
        }
    }

    /// A compact descriptor for a short field type, e.g. "textArea".
    var fieldTypeDescriptor: String? {
        guard let role = focusedRole else { return nil }
        switch role {
        case "AXTextArea": return "textArea"
        case "AXTextField":
            return focusedSubrole == "AXSearchField" ? "searchField" : "textField"
        case "AXComboBox": return "comboBox"
        case "AXWebArea": return "webArea"
        default: return nil
        }
    }
}

// Result of trying to acquire text to fix.
enum TextAcquisitionResult {
    case acquired(text: String, mode: TextInputMode, context: SourceAppContext)
    case noSelectionOrFocusedField
    case tooLong
    case failed(reason: String)
}
