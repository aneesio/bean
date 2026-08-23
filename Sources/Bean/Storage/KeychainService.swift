import Foundation
import Security

/// Distinguishes a genuinely missing Keychain item from an interrupted or
/// unavailable read. Callers must not turn a recoverable read failure into
/// persistent "no key" metadata.
enum KeychainReadResult: Equatable {
    case value(String)
    case notFound
    case failure(OSStatus)
}

// Stores secrets (API keys) in the macOS Keychain.
//
// API keys are NEVER written to UserDefaults or any plist. Each provider's key
// is stored under a distinct account so switching providers does not clobber
// the other key.
enum KeychainService {
    private static let service = "com.bean.apikeys"

    /// Saves (or updates) the secret for the given account. Passing an empty
    /// string deletes the entry.
    @discardableResult
    static func set(_ value: String, account: String) -> OSStatus {
        guard !value.isEmpty else {
            return delete(account: account)
        }

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Try to update an existing item first; if none exists, add a new one.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status
    }

    /// Reads the stored secret while preserving the Keychain status. In
    /// particular, cancellation and a locked/unavailable Keychain are not the
    /// same as a confirmed missing item.
    static func get(account: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess else {
            return .failure(status)
        }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty else {
            return .failure(errSecDecode)
        }
        return .value(string)
    }

    @discardableResult
    static func delete(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    static func errorMessage(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }

    /// Content-free, actionable copy for a failed read. Raw status details are
    /// deliberately reserved for diagnostics rather than exposed in setup UI.
    static func readErrorMessage(for status: OSStatus) -> String {
        switch status {
        case errSecUserCanceled:
            return "Keychain access was canceled. Try again when you're ready."
        case errSecInteractionNotAllowed:
            return "Keychain access isn't available right now. Unlock your Mac and try again."
        default:
            return "Bean couldn't read the saved API key. Try again."
        }
    }
}
