import AppKit
import Foundation

/// A metadata-only view of what Bean can do in the field that was focused when
/// the user chose Check Current Field. No AX value, selected text, title,
/// placeholder, or window title is stored.
struct FieldInspectionReport: Codable, Equatable {
    let checkedAt: Date
    let appName: String
    let bundleIdentifier: String?
    let appCategory: String
    let referenceSurface: String?
    let role: String?
    let subrole: String?
    let fallbackEvidence: String?
    let selectedTextAction: CapabilityAssessment
    let focusedFieldReplacement: CapabilityAssessment
    let beanBubble: CapabilityAssessment
    let inlineChecking: CapabilityAssessment

    var headline: String {
        if fallbackEvidence == "slackRecentTyping" {
            return "Bean detected a Slack composer (best effort)"
        }
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
            "fieldCheckReferenceSurface: \(referenceSurface ?? "generic")",
            "fieldCheckRole: \(role ?? "unknown")",
            "fieldCheckSubrole: \(subrole ?? "unknown")",
            "fieldCheckEvidence: \(fallbackEvidence ?? "none")",
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
        let usesSlackTypingEvidence = app.map {
            ElectronTextFocusEvidence.hasValidTypingEvidence(for: $0)
        } ?? false
        let hasBubbleBounds = field.map {
            TextRangeLocator.fieldRect(for: $0.element) != nil
                || TextRangeLocator.selectionRect(for: $0.element) != nil
        }
        let traits: FieldTraits?
        if let field, field.isSemanticTextSurface {
            traits = FieldTraits(field: field, hasBubbleBounds: hasBubbleBounds)
        } else if usesSlackTypingEvidence {
            // No AX value/role is invented. This says only that the guarded,
            // content-free Slack click+typing fallback is currently available.
            traits = FieldTraits(
                role: nil, subrole: nil, isSecure: false, isEnabled: true,
                isSemanticTextSurface: true, acceptsTextInput: false,
                isValueSettable: false, isSearchLike: false,
                hasBubbleBounds: true, nativeRangeBoundsReliable: false
            )
        } else {
            traits = field.map { FieldTraits(field: $0, hasBubbleBounds: hasBubbleBounds) }
        }
        let capabilities = FieldCapabilityPolicy.evaluate(
            bundleIdentifier: bundle, category: category,
            traits: traits,
            preferences: settings.capabilityPreferences
        )
        let report = Self.makeReport(
            appName: appName,
            bundleIdentifier: bundle,
            category: category,
            field: field,
            fallbackEvidence: usesSlackTypingEvidence ? "slackRecentTyping" : nil,
            capabilities: capabilities
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
        fallbackEvidence: String?,
        capabilities: FieldCapabilities
    ) -> FieldInspectionReport {
        return FieldInspectionReport(
            checkedAt: Date(), appName: appName, bundleIdentifier: bundleIdentifier,
            appCategory: category.rawValue,
            referenceSurface: capabilities.referenceSurface.rawValue,
            role: field?.role, subrole: field?.subrole,
            fallbackEvidence: fallbackEvidence,
            selectedTextAction: capabilities.selectedTextAction,
            focusedFieldReplacement: capabilities.focusedFieldReplacement,
            beanBubble: capabilities.beanBubble,
            inlineChecking: capabilities.inlineChecking
        )
    }
}
