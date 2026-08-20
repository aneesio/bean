import Foundation

// The technically-honest model of HOW (and whether) Bean can provide inline
// coverage for a given focused field. Native Accessibility is used only where
// range bounds are reliable; browser/web editors are the browser extension's
// job; some Electron apps would need a future adapter; everything else falls
// back to Passive Suggestions / Bean Bubble / shortcuts.
enum InlineCoverageMode: String {
    case nativeAccessibility
    case browserExtension
    case appAdapter
    case passiveFallback
    case unsupported

    var displayName: String {
        switch self {
        case .nativeAccessibility: return "Native inline"
        case .browserExtension: return "Browser extension"
        case .appAdapter: return "App adapter"
        case .passiveFallback: return "Passive fallback"
        case .unsupported: return "Unsupported"
        }
    }
}

enum InlineSupportResult {
    case supported(mode: InlineCoverageMode, confidence: Double)
    case degraded(mode: InlineCoverageMode, reason: String)
    case unsupported(reason: String)

    var modeCode: String {
        switch self {
        case .supported(let m, _): return m.rawValue
        case .degraded(let m, _): return m.rawValue
        case .unsupported: return InlineCoverageMode.unsupported.rawValue
        }
    }

    var reasonCode: String {
        switch self {
        case .supported: return "nativeRangeBoundsAvailable"
        case .degraded(_, let r): return r
        case .unsupported(let r): return r
        }
    }

    /// True only for the native-inline path Bean can draw itself.
    var isNativeInline: Bool {
        if case .supported(.nativeAccessibility, _) = self { return true }
        return false
    }
}

// Reason codes (also used in diagnostics, never with text).
enum InlineCoverageReason {
    static let nativeRangeBoundsAvailable = "nativeRangeBoundsAvailable"
    static let nativeRangeBoundsMissing = "nativeRangeBoundsMissing"
    static let webEditorRequiresExtension = "webEditorRequiresExtension"
    static let electronEditorRequiresAdapter = "electronEditorRequiresAdapter"
    static let richTextUnsupported = "richTextUnsupported"
    static let secureField = "secureField"
    static let searchFieldDisabled = "searchFieldDisabled"
    static let codeEditorDisabled = "codeEditorDisabled"
    static let appDisabled = "appDisabled"
    static let noAccessibilityPermission = "noAccessibilityPermission"
    static let unknown = "unknown"
}
