import AppKit
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

/// A metadata-only view of what Bean can do in the field that was focused when
/// the user chose Check Current Field. No AX value, selected text, title,
/// placeholder, or window title is stored.
struct FieldInspectionReport: Codable, Equatable {
    let checkedAt: Date
    let appName: String
    let bundleIdentifier: String?
    let appCategory: String
    let role: String?
    let subrole: String?
    let selectedTextAction: CapabilityAssessment
    let focusedFieldReplacement: CapabilityAssessment
    let beanBubble: CapabilityAssessment
    let inlineChecking: CapabilityAssessment

    var headline: String {
        let key = [selectedTextAction, focusedFieldReplacement, beanBubble]
        if key.contains(where: { $0.level == .supported }) { return "Bean found a usable text surface" }
        if key.contains(where: { $0.level == .degraded }) { return "Bean found a best-effort text surface" }
        return "Bean could not confirm an editable text surface"
    }

    var diagnosticsLines: [String] {
        [
            "fieldCheckAt: \(ISO8601DateFormatter().string(from: checkedAt))",
            "fieldCheckApp: \(appName)",
            "fieldCheckBundle: \(bundleIdentifier ?? "unknown")",
            "fieldCheckCategory: \(appCategory)",
            "fieldCheckRole: \(role ?? "unknown")",
            "fieldCheckSubrole: \(subrole ?? "unknown")",
            "fieldCheckSelection: \(selectedTextAction.level.rawValue)(\(selectedTextAction.reason))",
            "fieldCheckFocusedReplacement: \(focusedFieldReplacement.level.rawValue)(\(focusedFieldReplacement.reason))",
            "fieldCheckBubble: \(beanBubble.level.rawValue)(\(beanBubble.reason))",
            "fieldCheckInline: \(inlineChecking.level.rawValue)(\(inlineChecking.reason))"
        ]
    }
}

@MainActor
final class SetupStatusStore: ObservableObject {
    @Published private(set) var latestFieldInspection: FieldInspectionReport?

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "lastFieldInspectionV1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let report = try? JSONDecoder().decode(FieldInspectionReport.self, from: data) {
            latestFieldInspection = report
        }
    }

    @discardableResult
    func inspectCurrentField(settings: AppSettings) -> FieldInspectionReport {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown app"
        let bundle = app?.bundleIdentifier
        let category = AppCategory.from(bundleIdentifier: bundle)
        let field = app.flatMap(AccessibilityService.focusedFieldMetadata(in:))
        let report = Self.makeReport(
            appName: appName,
            bundleIdentifier: bundle,
            category: category,
            field: field,
            settings: settings
        )
        latestFieldInspection = report
        if let data = try? JSONEncoder().encode(report) {
            defaults.set(data, forKey: storageKey)
        }
        return report
    }

    func clearInspection() {
        latestFieldInspection = nil
        defaults.removeObject(forKey: storageKey)
    }

    /// Opens a disposable, synthetic sentence in the default plain-text editor
    /// so onboarding can verify the real cross-app shortcut/replacement path.
    /// The file contains no user content and lives in the system temp folder.
    func openTextEditVerificationFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bean-Setup-Verification.txt")
        try "i has a apple".write(to: url, atomically: true, encoding: .utf8)
        guard NSWorkspace.shared.open(url) else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private static func makeReport(
        appName: String,
        bundleIdentifier: String?,
        category: AppCategory,
        field: AccessibilityService.FocusedField?,
        settings: AppSettings
    ) -> FieldInspectionReport {
        guard PermissionService.isAccessibilityGranted else {
            let unavailable = CapabilityAssessment(level: .unsupported, reason: "accessibilityPermissionRequired")
            return FieldInspectionReport(
                checkedAt: Date(), appName: appName, bundleIdentifier: bundleIdentifier,
                appCategory: category.rawValue, role: field?.role, subrole: field?.subrole,
                selectedTextAction: unavailable, focusedFieldReplacement: unavailable,
                beanBubble: unavailable, inlineChecking: unavailable
            )
        }

        guard let field else {
            let unavailable = CapabilityAssessment(level: .unsupported, reason: "noFocusedField")
            return FieldInspectionReport(
                checkedAt: Date(), appName: appName, bundleIdentifier: bundleIdentifier,
                appCategory: category.rawValue, role: nil, subrole: nil,
                selectedTextAction: unavailable, focusedFieldReplacement: unavailable,
                beanBubble: unavailable, inlineChecking: unavailable
            )
        }

        let secure = field.isSecure
        let selection: CapabilityAssessment
        let focused: CapabilityAssessment
        let bubble: CapabilityAssessment
        let inline: CapabilityAssessment

        if secure {
            let unavailable = CapabilityAssessment(level: .unsupported, reason: "secureField")
            selection = unavailable; focused = unavailable; bubble = unavailable; inline = unavailable
        } else if !field.isEnabled {
            let unavailable = CapabilityAssessment(level: .unsupported, reason: "disabledField")
            selection = unavailable; focused = unavailable; bubble = unavailable; inline = unavailable
        } else if !field.isSemanticTextSurface {
            let unavailable = CapabilityAssessment(level: .unsupported, reason: "notEditableText")
            selection = unavailable; focused = unavailable; bubble = unavailable; inline = unavailable
        } else {
            selection = CapabilityAssessment(level: .supported, reason: "semanticTextSurface")

            if !settings.fixFocusedFieldWhenNoSelection {
                focused = CapabilityAssessment(level: .unsupported, reason: "focusedFieldFallbackDisabled")
            } else if field.acceptsTextInput {
                focused = CapabilityAssessment(
                    level: field.isValueSettable ? .supported : .degraded,
                    reason: field.isValueSettable ? "directValueWriteAvailable" : "pasteFallbackRequired"
                )
            } else if AppCategory.isElectron(bundleIdentifier) {
                focused = CapabilityAssessment(level: .degraded, reason: "electronPasteBestEffort")
            } else {
                focused = CapabilityAssessment(level: .unsupported, reason: "readOnlyField")
            }

            let categoryAllowed: Bool
            switch category {
            case .chat: categoryAllowed = settings.bubbleInChat
            case .codeEditor: categoryAllowed = settings.bubbleInCode
            case .mail, .docs, .unknown: categoryAllowed = settings.bubbleInMailBrowser
            }
            if field.isSearchLike && !settings.bubbleInSearch {
                bubble = CapabilityAssessment(level: .unsupported, reason: "searchFieldDisabled")
            } else if !categoryAllowed {
                bubble = CapabilityAssessment(level: .unsupported, reason: "categoryDisabled")
            } else if field.acceptsTextInput || AppCategory.isElectron(bundleIdentifier) {
                bubble = CapabilityAssessment(
                    level: settings.bubbleEnabled ? .supported : .degraded,
                    reason: settings.bubbleEnabled ? "enabled" : "supportedButDisabled"
                )
            } else {
                bubble = CapabilityAssessment(level: .unsupported, reason: "noEditableBounds")
            }

            if field.isSearchLike {
                inline = CapabilityAssessment(level: .unsupported, reason: "searchFieldDisabled")
            } else if category == .codeEditor {
                inline = CapabilityAssessment(level: .unsupported, reason: "codeEditorDisabled")
            } else if AppCategory.isBrowser(bundleIdentifier) {
                inline = CapabilityAssessment(level: .degraded, reason: "browserExtensionRequired")
            } else if AppCategory.isElectron(bundleIdentifier) {
                inline = CapabilityAssessment(level: .unsupported, reason: "electronInlineUnavailable")
            } else if field.acceptsTextInput {
                inline = CapabilityAssessment(level: .degraded, reason: "nativeRangeCheckRequired")
            } else {
                inline = CapabilityAssessment(level: .unsupported, reason: "richTextUnsupported")
            }
        }

        return FieldInspectionReport(
            checkedAt: Date(), appName: appName, bundleIdentifier: bundleIdentifier,
            appCategory: category.rawValue, role: field.role, subrole: field.subrole,
            selectedTextAction: selection, focusedFieldReplacement: focused,
            beanBubble: bubble, inlineChecking: inline
        )
    }
}
