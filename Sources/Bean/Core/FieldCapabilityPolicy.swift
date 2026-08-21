import Foundation

enum CapabilityLevel: String, Codable {
    case supported
    case degraded
    case unsupported

    var displayName: String {
        switch self {
        case .supported: return "Supported"
        case .degraded: return "Best effort"
        case .unsupported: return "Unavailable"
        }
    }
}

struct CapabilityAssessment: Codable, Equatable {
    let level: CapabilityLevel
    let reason: String
}

enum ReferenceSurface: String, Codable, CaseIterable {
    case textEdit
    case appleNotes
    case appleMail
    case slackDesktop
    case chromiumWeb
    case generic

    static func classify(bundleIdentifier: String?) -> ReferenceSurface {
        switch bundleIdentifier {
        case "com.apple.TextEdit": return .textEdit
        case "com.apple.Notes": return .appleNotes
        case "com.apple.mail": return .appleMail
        case "com.tinyspeck.slackmacgap": return .slackDesktop
        case let bundle where AppCategory.isBrowser(bundle): return .chromiumWeb
        default: return .generic
        }
    }
}

/// Value-free traits used for deterministic policy decisions. Runtime adapters
/// can derive these from Accessibility; tests construct them directly.
struct FieldTraits: Equatable {
    let role: String?
    let subrole: String?
    let isSecure: Bool
    let isEnabled: Bool
    let isSemanticTextSurface: Bool
    let acceptsTextInput: Bool
    let isValueSettable: Bool
    let isSearchLike: Bool
    let hasBubbleBounds: Bool?
    let nativeRangeBoundsReliable: Bool?

    init(field: AccessibilityService.FocusedField,
         hasBubbleBounds: Bool? = nil,
         nativeRangeBoundsReliable: Bool? = nil) {
        self.role = field.role
        self.subrole = field.subrole
        self.isSecure = field.isSecure
        self.isEnabled = field.isEnabled
        self.isSemanticTextSurface = field.isSemanticTextSurface
        self.acceptsTextInput = field.acceptsTextInput
        self.isValueSettable = field.isValueSettable
        self.isSearchLike = field.isSearchLike
        self.hasBubbleBounds = hasBubbleBounds
        self.nativeRangeBoundsReliable = nativeRangeBoundsReliable
    }

    init(role: String? = "AXTextArea", subrole: String? = nil,
         isSecure: Bool = false, isEnabled: Bool = true,
         isSemanticTextSurface: Bool = true, acceptsTextInput: Bool = true,
         isValueSettable: Bool = true, isSearchLike: Bool = false,
         hasBubbleBounds: Bool? = true, nativeRangeBoundsReliable: Bool? = true) {
        self.role = role
        self.subrole = subrole
        self.isSecure = isSecure
        self.isEnabled = isEnabled
        self.isSemanticTextSurface = isSemanticTextSurface
        self.acceptsTextInput = acceptsTextInput
        self.isValueSettable = isValueSettable
        self.isSearchLike = isSearchLike
        self.hasBubbleBounds = hasBubbleBounds
        self.nativeRangeBoundsReliable = nativeRangeBoundsReliable
    }
}

struct CapabilityPreferences: Equatable {
    let accessibilityGranted: Bool
    let focusedFieldFallbackEnabled: Bool
    let bubbleEnabled: Bool
    let bubbleInChat: Bool
    let bubbleInMailBrowser: Bool
    let bubbleInCode: Bool
    let bubbleInSearch: Bool
    let inlineEnabled: Bool
    let webInlineEnabled: Bool

    static func manual(focusedFieldFallbackEnabled: Bool) -> CapabilityPreferences {
        CapabilityPreferences(
            accessibilityGranted: true,
            focusedFieldFallbackEnabled: focusedFieldFallbackEnabled,
            bubbleEnabled: false, bubbleInChat: false, bubbleInMailBrowser: false,
            bubbleInCode: false, bubbleInSearch: false,
            inlineEnabled: false, webInlineEnabled: false
        )
    }
}

struct FieldCapabilities: Equatable {
    let referenceSurface: ReferenceSurface
    let selectedTextAction: CapabilityAssessment
    let focusedFieldReplacement: CapabilityAssessment
    let beanBubble: CapabilityAssessment
    let inlineChecking: CapabilityAssessment
}

/// One policy shared by diagnostics and runtime entry points. It makes no AX
/// calls and never sees field text.
enum FieldCapabilityPolicy {
    static func evaluate(bundleIdentifier: String?, category: AppCategory,
                         traits: FieldTraits?, preferences: CapabilityPreferences) -> FieldCapabilities {
        let surface = ReferenceSurface.classify(bundleIdentifier: bundleIdentifier)
        guard preferences.accessibilityGranted else {
            return all(.unsupported, "accessibilityPermissionRequired", surface: surface)
        }
        guard let traits else { return all(.unsupported, "noFocusedField", surface: surface) }
        if traits.isSecure { return all(.unsupported, "secureField", surface: surface) }
        if !traits.isEnabled { return all(.unsupported, "disabledField", surface: surface) }

        let selection: CapabilityAssessment
        if traits.isSemanticTextSurface {
            selection = .init(level: .supported, reason: "semanticTextSurface")
        } else {
            selection = .init(level: .unsupported, reason: "notEditableText")
        }

        let focused = focusedAssessment(bundleIdentifier: bundleIdentifier,
                                        category: category, traits: traits,
                                        preferences: preferences)
        let bubble = bubbleAssessment(bundleIdentifier: bundleIdentifier,
                                      category: category, traits: traits,
                                      preferences: preferences)
        let inline = inlineAssessment(bundleIdentifier: bundleIdentifier,
                                      category: category, traits: traits,
                                      preferences: preferences)
        return FieldCapabilities(referenceSurface: surface, selectedTextAction: selection,
                                 focusedFieldReplacement: focused, beanBubble: bubble,
                                 inlineChecking: inline)
    }

    private static func focusedAssessment(bundleIdentifier: String?, category: AppCategory,
                                          traits: FieldTraits,
                                          preferences: CapabilityPreferences) -> CapabilityAssessment {
        guard preferences.focusedFieldFallbackEnabled else {
            return .init(level: .unsupported, reason: "focusedFieldFallbackDisabled")
        }
        if traits.isSearchLike { return .init(level: .unsupported, reason: "searchFieldDisabled") }
        if category == .codeEditor { return .init(level: .unsupported, reason: "codeEditorDisabled") }
        if traits.acceptsTextInput {
            return .init(level: traits.isValueSettable ? .supported : .degraded,
                         reason: traits.isValueSettable
                            ? "directValueWriteAvailable" : "verifiedPasteFallback")
        }
        if AppCategory.isElectron(bundleIdentifier), traits.isSemanticTextSurface {
            return .init(level: .degraded, reason: "electronPasteBestEffort")
        }
        return .init(level: .unsupported,
                     reason: traits.isSemanticTextSurface ? "readOnlyField" : "notEditableText")
    }

    private static func bubbleAssessment(bundleIdentifier: String?, category: AppCategory,
                                         traits: FieldTraits,
                                         preferences: CapabilityPreferences) -> CapabilityAssessment {
        guard traits.isSemanticTextSurface else {
            return .init(level: .unsupported, reason: "notEditableText")
        }
        if traits.isSearchLike && !preferences.bubbleInSearch {
            return .init(level: .unsupported, reason: "searchFieldDisabled")
        }
        let categoryAllowed: Bool
        switch category {
        case .chat: categoryAllowed = preferences.bubbleInChat
        case .codeEditor: categoryAllowed = preferences.bubbleInCode
        case .mail, .docs, .unknown: categoryAllowed = preferences.bubbleInMailBrowser
        }
        guard categoryAllowed else { return .init(level: .unsupported, reason: "categoryDisabled") }
        guard traits.acceptsTextInput || AppCategory.isElectron(bundleIdentifier) else {
            return .init(level: .unsupported, reason: "readOnlyField")
        }
        guard preferences.bubbleEnabled else {
            return .init(level: .degraded, reason: "supportedButDisabled")
        }
        if traits.hasBubbleBounds == true {
            return .init(level: .supported, reason: "editableBoundsAvailable")
        }
        if AppCategory.isElectron(bundleIdentifier) {
            return .init(level: .degraded, reason: "electronTypingEvidenceFallback")
        }
        if traits.hasBubbleBounds == nil {
            return .init(level: .degraded, reason: "boundsCheckRequired")
        }
        return .init(level: .unsupported, reason: "noEditableBounds")
    }

    private static func inlineAssessment(bundleIdentifier: String?, category: AppCategory,
                                         traits: FieldTraits,
                                         preferences: CapabilityPreferences) -> CapabilityAssessment {
        if traits.isSearchLike { return .init(level: .unsupported, reason: "searchFieldDisabled") }
        if category == .codeEditor { return .init(level: .unsupported, reason: "codeEditorDisabled") }
        if AppCategory.isBrowser(bundleIdentifier) {
            return .init(level: .degraded,
                         reason: preferences.webInlineEnabled
                            ? "browserExtensionEnabled" : "browserExtensionRequired")
        }
        if AppCategory.isElectron(bundleIdentifier) {
            return .init(level: .degraded, reason: "electronEditorRequiresAdapter")
        }
        guard traits.acceptsTextInput else {
            return .init(level: .unsupported, reason: "richTextUnsupported")
        }
        guard preferences.inlineEnabled else {
            return .init(level: .degraded, reason: "supportedButDisabled")
        }
        switch traits.nativeRangeBoundsReliable {
        case .some(true): return .init(level: .supported, reason: "nativeRangeBoundsAvailable")
        case .some(false): return .init(level: .degraded, reason: "nativeRangeBoundsMissing")
        case .none: return .init(level: .degraded, reason: "nativeRangeCheckRequired")
        }
    }

    private static func all(_ level: CapabilityLevel, _ reason: String,
                            surface: ReferenceSurface) -> FieldCapabilities {
        let assessment = CapabilityAssessment(level: level, reason: reason)
        return FieldCapabilities(referenceSurface: surface,
                                 selectedTextAction: assessment,
                                 focusedFieldReplacement: assessment,
                                 beanBubble: assessment,
                                 inlineChecking: assessment)
    }
}
