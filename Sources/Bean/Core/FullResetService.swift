import AppKit
import Foundation
import Security

enum FullResetArea: String, CaseIterable, Equatable {
    case providerKeys = "Provider keys"
    case userContent = "Writing personalization"
    case loginItem = "Launch at login"
    case browserBridge = "Browser connection"
    case accounting = "Usage and operation history"
    case preferences = "Preferences and onboarding"
}

struct FullResetFailure: Equatable {
    let area: FullResetArea
    let message: String
}

struct FullResetResult: Equatable {
    let completedAreas: [FullResetArea]
    let failures: [FullResetFailure]
    let skippedAreas: [FullResetArea]
    let terminationRequested: Bool

    var succeeded: Bool {
        failures.isEmpty && skippedAreas.isEmpty && terminationRequested
    }
}

struct FullResetEffects {
    let deleteProviderKey: @MainActor (ProviderKind) throws -> Void
    let forgetProviderCredentialCache: @MainActor () -> Void
    let resetUserContent: @MainActor () throws -> Void
    let disableLoginItem: @MainActor () throws -> Void
    let removeBrowserBridge: @MainActor () -> BrowserBridgeRemovalResult
    let resetAccounting: @MainActor () throws -> AutomaticCallBudgetStore.ResetResult
    let clearPreferences: @MainActor () throws -> Void
    let terminateApplication: @MainActor () -> Void
}

private struct FullResetEffectError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BeanPreferencesResetter {
    let defaults: UserDefaults
    let domainName: String

    func clear() throws {
        defaults.removePersistentDomain(forName: domainName)
        defaults.synchronize()
        let remaining = defaults.persistentDomain(forName: domainName) ?? [:]
        guard remaining.isEmpty else {
            throw FullResetEffectError(message: "Preferences are still present.")
        }
    }
}

/// Coordinates Bean's explicit, user-confirmed full reset. External stores are
/// cleared first. Accounting and preferences are intentionally deferred until
/// every earlier cleanup succeeds, so a retryable Keychain/browser/login failure
/// cannot strand the running app with its preferences already removed.
@MainActor
struct FullResetService {
    let effects: FullResetEffects

    static let accessibilityRemovalInstructions =
        "macOS does not let Bean remove its own Accessibility permission. To remove it too, open System Settings → Privacy & Security → Accessibility and remove or turn off Bean."

    func perform() -> FullResetResult {
        var completed: [FullResetArea] = []
        var failures: [FullResetFailure] = []

        var removedProviders: [String] = []
        var failedProviders: [String] = []
        for provider in ProviderKind.allCases {
            do {
                try effects.deleteProviderKey(provider)
                removedProviders.append(provider.displayName)
            } catch {
                failedProviders.append(provider.displayName)
            }
        }
        effects.forgetProviderCredentialCache()
        if failedProviders.isEmpty {
            completed.append(.providerKeys)
        } else {
            var details: [String] = []
            if !removedProviders.isEmpty {
                details.append("Already cleared Bean's saved-key entry for \(removedProviders.joined(separator: ", ")).")
            }
            details.append("Couldn't remove the saved key for \(failedProviders.joined(separator: ", ")). macOS Keychain may ask for permission when you retry.")
            failures.append(FullResetFailure(
                area: .providerKeys,
                message: details.joined(separator: " ")
            ))
        }

        run(.userContent, completed: &completed, failures: &failures) {
            try effects.resetUserContent()
        }
        run(.loginItem, completed: &completed, failures: &failures) {
            try effects.disableLoginItem()
        }

        let bridgeResult = effects.removeBrowserBridge()
        if bridgeResult.succeeded {
            completed.append(.browserBridge)
        } else {
            var details: [String] = []
            if !bridgeResult.removedBrowserNames.isEmpty {
                details.append("Already removed Bean's connection for \(bridgeResult.removedBrowserNames.joined(separator: ", ")).")
            }
            if !bridgeResult.failedBrowserNames.isEmpty {
                details.append("Couldn't remove the Bean connection for \(bridgeResult.failedBrowserNames.joined(separator: ", ")).")
            }
            if bridgeResult.manualApprovalCleared {
                details.append("Bean's saved manual extension approval is now clear.")
            } else {
                details.append("Couldn't clear Bean's saved manual extension approval.")
            }
            failures.append(FullResetFailure(
                area: .browserBridge,
                message: details.joined(separator: " ")
            ))
        }

        // Keep the app's durable configuration intact when an earlier external
        // cleanup needs attention. This makes retry behavior understandable and
        // avoids ever reporting a complete reset after only a partial teardown.
        guard failures.isEmpty else {
            return FullResetResult(
                completedAreas: completed,
                failures: failures,
                skippedAreas: [.accounting, .preferences],
                terminationRequested: false
            )
        }

        do {
            let accountingResult = try effects.resetAccounting()
            if accountingResult.succeeded {
                completed.append(.accounting)
            } else {
                failures.append(FullResetFailure(
                    area: .accounting,
                    message: accountingFailureMessage(accountingResult)
                ))
            }
        } catch {
            failures.append(FullResetFailure(
                area: .accounting,
                message: "Couldn't clear Bean's usage, operation history, or private automatic-call state."
            ))
        }
        if !failures.isEmpty {
            return FullResetResult(
                completedAreas: completed,
                failures: failures,
                skippedAreas: [.preferences],
                terminationRequested: false
            )
        }

        do {
            try effects.clearPreferences()
            completed.append(.preferences)
        } catch {
            failures.append(FullResetFailure(
                area: .preferences,
                message: "Couldn't verify that Bean's preferences and onboarding state were removed."
            ))
            return FullResetResult(
                completedAreas: completed,
                failures: failures,
                skippedAreas: [],
                terminationRequested: false
            )
        }

        effects.terminateApplication()
        return FullResetResult(
            completedAreas: completed,
            failures: [],
            skippedAreas: [],
            terminationRequested: true
        )
    }

    private func run(
        _ area: FullResetArea,
        completed: inout [FullResetArea],
        failures: inout [FullResetFailure],
        operation: () throws -> Void
    ) {
        do {
            try operation()
            completed.append(area)
        } catch {
            let message: String
            if area == .userContent,
               let storeError = error as? UserContentStoreError,
               storeError == .unableToErase {
                message = "Bean couldn't remove all personalization files. Some Bean-owned personalization files may already have been removed; no files outside Bean's data area were touched."
            } else {
                message = error.localizedDescription
            }
            failures.append(FullResetFailure(
                area: area,
                message: message
            ))
        }
    }

    private func accountingFailureMessage(
        _ result: AutomaticCallBudgetStore.ResetResult
    ) -> String {
        var details: [String] = []
        if result.privateStateRemoved {
            details.append("Already removed Bean's private automatic-call state.")
        } else {
            details.append("Couldn't remove Bean's private automatic-call state.")
        }
        if result.visibleUsageRemoved {
            details.append("Already removed visible usage totals.")
        } else {
            details.append("Couldn't remove visible usage totals.")
        }
        if result.visibleHistoryRemoved {
            details.append("Already removed visible operation history.")
        } else {
            details.append("Couldn't remove visible operation history.")
        }
        return details.joined(separator: " ")
    }

    static func live(
        settings: AppSettings,
        userContent: UserContentStore,
        automaticCallBudget: AutomaticCallBudgetStore,
        defaults: UserDefaults = .standard,
        preferencesDomainName: String = Bundle.main.bundleIdentifier ?? "com.bean.app",
        browserInstaller: BrowserBridgeInstaller = BrowserBridgeInstaller(),
        terminateApplication: @escaping @MainActor () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) -> FullResetService {
        FullResetService(effects: FullResetEffects(
            deleteProviderKey: { provider in
                let status = KeychainService.delete(account: provider.keychainAccount)
                guard status == errSecSuccess else {
                    throw FullResetEffectError(
                        message: KeychainService.errorMessage(for: status)
                    )
                }
            },
            forgetProviderCredentialCache: {
                settings.forgetProviderCredentialsAfterResetAttempt()
            },
            resetUserContent: {
                _ = try userContent.eraseAllUserContentArtifacts()
            },
            disableLoginItem: {
                try LoginItemService.resetRegistration()
            },
            removeBrowserBridge: {
                browserInstaller.removeBeanConnectionAndApprovals()
            },
            resetAccounting: {
                automaticCallBudget.resetAllAccounting()
            },
            clearPreferences: {
                try BeanPreferencesResetter(
                    defaults: defaults, domainName: preferencesDomainName
                ).clear()
            },
            terminateApplication: terminateApplication
        ))
    }
}
