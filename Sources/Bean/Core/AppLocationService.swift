import AppKit
import Foundation

/// A content-free description of where the running Bean bundle lives.
///
/// Bean deliberately treats only the canonical `/Applications/Bean.app` path
/// as stable. Permissions, login-item registration, and the browser bridge all
/// refer to the signed bundle at a concrete path, so running another copy is a
/// real configuration risk even when that copy also happens to be inside an
/// Applications folder.
struct AppLocationAssessment: Equatable {
    enum Kind: String, Equatable {
        case applications
        case downloads
        case buildFolder
        case derivedData
        case appTranslocation
        case other
    }

    static let canonicalApplicationURL = URL(fileURLWithPath: "/Applications/Bean.app", isDirectory: true)

    let appURL: URL
    let canonicalApplicationURL: URL
    let kind: Kind

    init(
        appURL: URL,
        canonicalApplicationURL: URL = AppLocationAssessment.canonicalApplicationURL
    ) {
        let appURL = appURL.standardizedFileURL
        let canonicalURL = canonicalApplicationURL.standardizedFileURL
        self.appURL = appURL
        self.canonicalApplicationURL = canonicalURL

        if appURL.path == canonicalURL.path {
            kind = .applications
            return
        }

        let components = appURL.pathComponents.map { $0.lowercased() }
        if components.contains("apptranslocation") {
            kind = .appTranslocation
        } else if components.contains("deriveddata") {
            kind = .derivedData
        } else if components.contains("downloads") {
            kind = .downloads
        } else if components.contains("build") || components.contains(".build") {
            kind = .buildFolder
        } else {
            kind = .other
        }
    }

    var isStable: Bool { kind == .applications }

    /// Short, user-facing explanation suitable for onboarding and diagnostics.
    var reason: String {
        switch kind {
        case .applications:
            return "Bean is installed in Applications, so macOS can keep its permissions and browser connection stable."
        case .downloads:
            return "Bean is running from Downloads, where macOS may quarantine or relocate it and lose its saved permissions."
        case .buildFolder:
            return "Bean is running from a build folder that can be replaced the next time the app is built."
        case .derivedData:
            return "Bean is running from Xcode DerivedData, whose bundle path changes as builds are replaced."
        case .appTranslocation:
            return "macOS has opened Bean from a temporary App Translocation path, so permissions and integrations may not persist."
        case .other:
            return "Bean is not running from /Applications/Bean.app, so permissions, login at launch, and browser integration may be unreliable."
        }
    }

    var warningMessage: String? {
        isStable ? nil : "\(reason) Install Bean in Applications for a stable setup."
    }
}

/// Typed failures let onboarding offer a specific recovery instead of a vague
/// “installation failed” message. In particular, a destination collision is
/// never resolved by deleting or overwriting the existing application.
enum AppLocationServiceError: LocalizedError, Equatable {
    case alreadyInstalled
    case sourceMissing(String)
    case destinationAlreadyExists(String)
    case installedCopyMissing(String)
    case temporaryDestinationAlreadyExists(String)
    case copyFailed(String)
    case installFailed(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled:
            return "Bean is already installed in Applications."
        case .sourceMissing:
            return "Bean could not find the app it is currently running from. Download it again and retry."
        case .destinationAlreadyExists:
            return "A copy of Bean already exists in Applications. Bean will not overwrite it."
        case .installedCopyMissing:
            return "Bean could not find an installed copy in Applications."
        case .temporaryDestinationAlreadyExists:
            return "Bean could not create a safe temporary install location. Quit Bean and try again."
        case .copyFailed(let detail):
            return "Bean could not copy itself to Applications. \(detail)"
        case .installFailed(let detail):
            return "Bean was copied, but could not finish the installation. \(detail)"
        case .launchFailed(let detail):
            return "Bean is installed, but macOS could not open the installed copy. \(detail)"
        }
    }

    /// The path associated with a location failure, useful for diagnostics.
    var path: String? {
        switch self {
        case .alreadyInstalled, .copyFailed, .installFailed, .launchFailed:
            return nil
        case .sourceMissing(let path),
             .destinationAlreadyExists(let path),
             .installedCopyMissing(let path),
             .temporaryDestinationAlreadyExists(let path):
            return path
        }
    }
}

/// Injectable filesystem, workspace, and process effects keep installation
/// behavior deterministic in tests and ensure the current app exits only after
/// Launch Services confirms that the installed copy opened successfully.
struct AppLocationEffects {
    let fileExists: (URL) -> Bool
    let copyItem: (URL, URL) throws -> Void
    let moveItem: (URL, URL) throws -> Void
    let removeItem: (URL) throws -> Void
    let launchApplication: (URL) async throws -> Void
    let terminateCurrentApplication: () -> Void
    let makeTemporaryIdentifier: () -> String

    static var live: AppLocationEffects {
        let fileManager = FileManager.default
        return AppLocationEffects(
            fileExists: { fileManager.fileExists(atPath: $0.path) },
            copyItem: { try fileManager.copyItem(at: $0, to: $1) },
            moveItem: { try fileManager.moveItem(at: $0, to: $1) },
            removeItem: { try fileManager.removeItem(at: $0) },
            launchApplication: { url in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if application != nil {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: NSError(
                                domain: "com.bean.app.location",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Launch Services returned no application."]
                            ))
                        }
                    }
                }
            },
            terminateCurrentApplication: { NSApplication.shared.terminate(nil) },
            makeTemporaryIdentifier: { UUID().uuidString }
        )
    }
}

/// Safely installs the running bundle into Applications and relaunches it.
///
/// Installation is a copy to a unique sibling followed by a same-volume move
/// into place. `moveItem` does not replace an existing destination, preserving
/// the no-overwrite guarantee even if another process wins the preflight race.
@MainActor
struct AppLocationService {
    let currentApplicationURL: URL
    let installedApplicationURL: URL
    private let effects: AppLocationEffects

    init(
        currentApplicationURL: URL = Bundle.main.bundleURL,
        installedApplicationURL: URL = AppLocationAssessment.canonicalApplicationURL,
        effects: AppLocationEffects = .live
    ) {
        self.currentApplicationURL = currentApplicationURL.standardizedFileURL
        self.installedApplicationURL = installedApplicationURL.standardizedFileURL
        self.effects = effects
    }

    var assessment: AppLocationAssessment {
        AppLocationAssessment(
            appURL: currentApplicationURL,
            canonicalApplicationURL: installedApplicationURL
        )
    }

    /// Returns the installed URL in tests; the live process terminates before a
    /// caller can normally observe the return value.
    @discardableResult
    func installAndRelaunch() async throws -> URL {
        guard currentApplicationURL.path != installedApplicationURL.path else {
            throw AppLocationServiceError.alreadyInstalled
        }
        guard effects.fileExists(currentApplicationURL) else {
            throw AppLocationServiceError.sourceMissing(currentApplicationURL.path)
        }
        guard !effects.fileExists(installedApplicationURL) else {
            throw AppLocationServiceError.destinationAlreadyExists(installedApplicationURL.path)
        }

        let temporaryURL = temporaryInstallURL()
        guard !effects.fileExists(temporaryURL) else {
            throw AppLocationServiceError.temporaryDestinationAlreadyExists(temporaryURL.path)
        }

        do {
            try effects.copyItem(currentApplicationURL, temporaryURL)
        } catch {
            cleanUpTemporaryItem(at: temporaryURL)
            throw AppLocationServiceError.copyFailed(error.localizedDescription)
        }

        do {
            // A sibling move is atomic on the Applications volume and never
            // overwrites a copy that appeared after the earlier preflight.
            try effects.moveItem(temporaryURL, installedApplicationURL)
        } catch {
            cleanUpTemporaryItem(at: temporaryURL)
            throw AppLocationServiceError.installFailed(error.localizedDescription)
        }

        try await launchAndTerminate(installedApplicationURL)
        return installedApplicationURL
    }

    /// Opens the existing Applications copy without modifying it. This is the
    /// safe recovery offered when installation finds a destination collision.
    @discardableResult
    func openInstalledCopy() async throws -> URL {
        guard effects.fileExists(installedApplicationURL) else {
            throw AppLocationServiceError.installedCopyMissing(installedApplicationURL.path)
        }
        try await launchAndTerminate(installedApplicationURL)
        return installedApplicationURL
    }

    private func temporaryInstallURL() -> URL {
        installedApplicationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".Bean-installing-\(effects.makeTemporaryIdentifier()).app",
                isDirectory: true
            )
    }

    private func cleanUpTemporaryItem(at url: URL) {
        guard effects.fileExists(url) else { return }
        try? effects.removeItem(url)
    }

    private func launchAndTerminate(_ url: URL) async throws {
        do {
            try await effects.launchApplication(url)
        } catch {
            throw AppLocationServiceError.launchFailed(error.localizedDescription)
        }
        effects.terminateCurrentApplication()
    }
}
