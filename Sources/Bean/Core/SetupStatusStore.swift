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

    private enum CodingKeys: String, CodingKey {
        case checkedAt, appName, bundleIdentifier, appCategory, referenceSurface
        case role, subrole, fallbackEvidence, selectedTextAction
        case focusedFieldReplacement, beanBubble, inlineChecking
    }

    init(checkedAt: Date, appName: String, bundleIdentifier: String?,
         appCategory: String, referenceSurface: String?, role: String?,
         subrole: String?, fallbackEvidence: String?,
         selectedTextAction: CapabilityAssessment,
         focusedFieldReplacement: CapabilityAssessment,
         beanBubble: CapabilityAssessment,
         inlineChecking: CapabilityAssessment) {
        self.checkedAt = checkedAt
        self.appName = OperationalMetadataSanitizer.required(
            appName, fallback: "Unknown app",
            maximumScalars: OperationalMetadataSanitizer.appNameMaximumScalars
        )
        self.bundleIdentifier = OperationalMetadataSanitizer.optional(
            bundleIdentifier,
            maximumScalars: OperationalMetadataSanitizer.bundleIdentifierMaximumScalars
        )
        self.appCategory = OperationalMetadataSanitizer.required(
            appCategory,
            maximumScalars: OperationalMetadataSanitizer.categoryMaximumScalars
        )
        self.referenceSurface = OperationalMetadataSanitizer.optional(
            referenceSurface,
            maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars
        )
        self.role = OperationalMetadataSanitizer.optional(
            role,
            maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars
        )
        self.subrole = OperationalMetadataSanitizer.optional(
            subrole,
            maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars
        )
        self.fallbackEvidence = OperationalMetadataSanitizer.optional(
            fallbackEvidence,
            maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars
        )
        self.selectedTextAction = Self.sanitized(selectedTextAction)
        self.focusedFieldReplacement = Self.sanitized(focusedFieldReplacement)
        self.beanBubble = Self.sanitized(beanBubble)
        self.inlineChecking = Self.sanitized(inlineChecking)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            checkedAt: try container.decode(Date.self, forKey: .checkedAt),
            appName: try container.decode(String.self, forKey: .appName),
            bundleIdentifier: try container.decodeIfPresent(
                String.self, forKey: .bundleIdentifier
            ),
            appCategory: try container.decode(String.self, forKey: .appCategory),
            referenceSurface: try container.decodeIfPresent(
                String.self, forKey: .referenceSurface
            ),
            role: try container.decodeIfPresent(String.self, forKey: .role),
            subrole: try container.decodeIfPresent(String.self, forKey: .subrole),
            fallbackEvidence: try container.decodeIfPresent(
                String.self, forKey: .fallbackEvidence
            ),
            selectedTextAction: try container.decode(
                CapabilityAssessment.self, forKey: .selectedTextAction
            ),
            focusedFieldReplacement: try container.decode(
                CapabilityAssessment.self, forKey: .focusedFieldReplacement
            ),
            beanBubble: try container.decode(CapabilityAssessment.self, forKey: .beanBubble),
            inlineChecking: try container.decode(
                CapabilityAssessment.self, forKey: .inlineChecking
            )
        )
    }

    private static func sanitized(_ assessment: CapabilityAssessment) -> CapabilityAssessment {
        CapabilityAssessment(
            level: assessment.level,
            reason: OperationalMetadataSanitizer.required(
                assessment.reason,
                maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars
            )
        )
    }

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
        let safeAppName = OperationalMetadataSanitizer.required(
            appName, fallback: "Unknown app",
            maximumScalars: OperationalMetadataSanitizer.appNameMaximumScalars
        )
        let safeBundle = OperationalMetadataSanitizer.optional(
            bundleIdentifier,
            maximumScalars: OperationalMetadataSanitizer.bundleIdentifierMaximumScalars
        ) ?? "unknown"
        let safeCategory = OperationalMetadataSanitizer.required(
            appCategory,
            maximumScalars: OperationalMetadataSanitizer.categoryMaximumScalars
        )
        let safeReference = OperationalMetadataSanitizer.optional(
            referenceSurface,
            maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars
        ) ?? "generic"
        let safeRole = OperationalMetadataSanitizer.optional(
            role,
            maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars
        ) ?? "unknown"
        let safeSubrole = OperationalMetadataSanitizer.optional(
            subrole,
            maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars
        ) ?? "unknown"
        let safeEvidence = OperationalMetadataSanitizer.optional(
            fallbackEvidence,
            maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars
        ) ?? "none"
        let selection = Self.sanitized(selectedTextAction)
        let replacement = Self.sanitized(focusedFieldReplacement)
        let bubble = Self.sanitized(beanBubble)
        let inline = Self.sanitized(inlineChecking)
        return [
            "fieldCheckAt: \(ISO8601DateFormatter().string(from: checkedAt))",
            "fieldCheckApp: \(safeAppName)",
            "fieldCheckBundle: \(safeBundle)",
            "fieldCheckCategory: \(safeCategory)",
            "fieldCheckReferenceSurface: \(safeReference)",
            "fieldCheckRole: \(safeRole)",
            "fieldCheckSubrole: \(safeSubrole)",
            "fieldCheckEvidence: \(safeEvidence)",
            "fieldCheckSelection: \(selection.level.rawValue)(\(selection.reason))",
            "fieldCheckFocusedReplacement: \(replacement.level.rawValue)(\(replacement.reason))",
            "fieldCheckBubble: \(bubble.level.rawValue)(\(bubble.reason))",
            "fieldCheckInline: \(inline.level.rawValue)(\(inline.reason))"
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
            // Rewrite legacy metadata immediately so hostile line separators or
            // oversized labels do not remain in the persisted inspection.
            if let sanitized = try? JSONEncoder().encode(report) {
                defaults.set(sanitized, forKey: storageKey)
                defaults.synchronize()
            }
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
