/// Shared bounds for storage, native messages and pure output validation.
/// Keeping these independent of the store lets deterministic checks compile
/// without AppKit, observable storage or persistence dependencies.
enum UserContentFileLimits {
    static let maximumEncodedBytes = 2_000_000
    static let maximumNativeDictionaryTerms = 5_000
}
