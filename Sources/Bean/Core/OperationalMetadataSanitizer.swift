import Foundation

/// Normalizes untrusted, content-free labels before they reach durable stores,
/// diagnostics, or crash-recovery files. App and model metadata can originate
/// outside Bean, so it must never be able to add lines, preserve bidi/format
/// controls, or grow a bounded operational record without limit.
enum OperationalMetadataSanitizer {
    static let appNameMaximumScalars = 96
    static let bundleIdentifierMaximumScalars = 160
    static let categoryMaximumScalars = 48
    static let operationLabelMaximumScalars = 64
    static let providerMaximumScalars = 64
    static let modelMaximumScalars = 128
    static let fieldMetadataMaximumScalars = 96

    static func sanitize(_ value: String, maximumScalars: Int) -> String {
        guard maximumScalars > 0 else { return "" }

        var result = String.UnicodeScalarView()
        var needsSeparator = false

        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !result.isEmpty { needsSeparator = true }
                continue
            }

            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                // Treat a removed control as a word boundary. This preserves a
                // readable separation without preserving the control itself.
                if !result.isEmpty { needsSeparator = true }
                continue
            default:
                break
            }
            if CharacterSet.illegalCharacters.contains(scalar) { continue }

            // Do not spend the final scalar on a separator; retaining the next
            // visible scalar is more useful and never creates trailing space.
            if needsSeparator && result.count + 1 < maximumScalars {
                result.append(" ")
            }
            needsSeparator = false
            guard result.count < maximumScalars else { break }
            result.append(scalar)
        }

        return String(result)
    }

    static func optional(_ value: String?, maximumScalars: Int) -> String? {
        guard let value else { return nil }
        let sanitized = sanitize(value, maximumScalars: maximumScalars)
        return sanitized.isEmpty ? nil : sanitized
    }

    static func required(_ value: String, fallback: String = "unknown",
                         maximumScalars: Int) -> String {
        let sanitized = sanitize(value, maximumScalars: maximumScalars)
        if !sanitized.isEmpty { return sanitized }
        return sanitize(fallback, maximumScalars: maximumScalars)
    }
}
