import Foundation
import Darwin

enum AutomaticCallBudgetPolicy {
    static let defaultDailyLimit = 20
    static let maximumDailyLimit = 200

    /// Values read from preferences keep the established "unset means 20"
    /// behavior while refusing an oversized/corrupt value that would silently
    /// disable the cost guard.
    static func persistedDailyLimit(_ value: Int) -> Int {
        guard value > 0 else { return defaultDailyLimit }
        return min(value, maximumDailyLimit)
    }

    /// The store is the final paid-call boundary. Clamp every caller even if it
    /// bypasses AppSettings or mutates defaults outside Bean's UI.
    static func requestedDailyLimit(_ value: Int) -> Int {
        min(max(1, value), maximumDailyLimit)
    }
}

private enum BeanSecureStorePath {
    enum Entry: Equatable {
        case missing
        case regularFile
        case unsafe
    }

    /// macOS exposes `/var` and `/tmp` as root-level compatibility symlinks.
    /// Normalize only those trusted system aliases; never resolve a symlink in
    /// the caller-provided storage tail, which could redirect Bean to unrelated
    /// user data.
    static func canonicalizingSystemAliases(_ url: URL) -> URL {
        // Take one immutable snapshot. For a not-yet-created path beneath
        // `/private/var`, Foundation preserves `/private/var`; once another
        // thread creates that path, a later `standardizedFileURL` call can map
        // it back to `/var`. Reading the property twice would therefore create
        // a TOCTOU race that intermittently returned the unsafe symlink alias.
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        if path == "/var" || path.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private" + path, isDirectory: true)
        }
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            return URL(
                fileURLWithPath: "/private/tmp" + String(path.dropFirst(4)),
                isDirectory: true
            )
        }
        return standardizedURL
    }

    static func ensurePrivateDirectory(at url: URL) -> Bool {
        guard directoryChainIsReal(to: url.deletingLastPathComponent()) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            // Another Bean process/thread may have created the exact directory
            // after our parent-chain preflight. Accept only that benign race;
            // the no-symlink chain validation below still rejects redirects and
            // non-directory entries.
            guard directoryChainIsReal(to: url) else { return false }
        }
        guard directoryChainIsReal(to: url) else { return false }
        // Tighten permissions through a no-follow descriptor. A path-based
        // chmod could follow a directory symlink introduced between the lstat
        // above and the mode change.
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              fchmod(descriptor, S_IRWXU) == 0 else { return false }
        return directoryChainIsReal(to: url)
    }

    static func entry(at url: URL) -> Entry {
        var information = stat()
        let status = url.path.withCString { lstat($0, &information) }
        guard status == 0 else { return errno == ENOENT ? .missing : .unsafe }
        guard (information.st_mode & S_IFMT) == S_IFREG,
              information.st_nlink == 1 else { return .unsafe }
        return .regularFile
    }

    static func openRegularFile(_ url: URL, flags: Int32, mode: mode_t = 0) -> Int32? {
        guard entry(at: url) != .unsafe else { return nil }
        let descriptor = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { return nil }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_nlink == 1 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    static func readRegularFile(at url: URL, maximumBytes: Int) -> Data? {
        guard case .regularFile = entry(at: url),
              let descriptor = openRegularFile(url, flags: O_RDONLY) else { return nil }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_size >= 0,
              information.st_size <= maximumBytes else { return nil }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard result.count + count <= maximumBytes else { return nil }
            result.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }

    static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        guard ensurePrivateDirectory(at: url.deletingLastPathComponent()),
              entry(at: url) != .unsafe else { return false }

        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard let descriptor = openRegularFile(
            temporaryURL,
            flags: O_WRONLY | O_CREAT | O_EXCL,
            mode: S_IRUSR | S_IWUSR
        ) else { return false }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary { _ = Darwin.unlink(temporaryURL.path) }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { return false }

        let wroteAll = data.withUnsafeBytes { rawBuffer -> Bool in
            guard var pointer = rawBuffer.baseAddress else { return data.isEmpty }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0,
              entry(at: url) != .unsafe,
              Darwin.rename(temporaryURL.path, url.path) == 0 else { return false }
        shouldRemoveTemporary = false
        return entry(at: url) == .regularFile
    }

    private static func directoryChainIsReal(to url: URL) -> Bool {
        // `standardizedFileURL` maps macOS's canonical `/private/var` and
        // `/private/tmp` paths back through their public `/var` and `/tmp`
        // aliases. Re-standardizing here would therefore manufacture a
        // symlink after `canonicalizingSystemAliases` deliberately removed it.
        // Walk the already-canonical URL lexically so only symlinks supplied in
        // the caller-controlled storage tail are rejected.
        let components = url.pathComponents
        guard components.first == "/" else { return false }
        var currentPath = "/"
        for component in components.dropFirst() {
            currentPath = (currentPath as NSString).appendingPathComponent(component)
            var information = stat()
            let status = currentPath.withCString { lstat($0, &information) }
            if status == 0 {
                guard (information.st_mode & S_IFMT) == S_IFDIR else { return false }
            } else if errno != ENOENT {
                return false
            }
        }
        return true
    }
}

/// Stable, content-free outcomes shared by all automatic provider paths.
func automaticProviderFailureOutcome(_ error: Error) -> String {
    guard let llmError = error as? LLMError else { return "providerFailed" }
    switch llmError {
    case .timeout:
        return "requestTimedOut"
    case .missingAPIKey:
        // Automatic callers validate configuration before reserving. If a key
        // disappears in the tiny interval before the call, no network request
        // happened, but fail closed and retain the attempted-call audit trail.
        return "providerConfigurationChanged"
    case .inputTooLong:
        return "providerInputTooLong"
    case .invalidAPIKey:
        return "providerAuthenticationFailed"
    case .network:
        return "providerNetworkFailed"
    case .server:
        return "providerServerFailed"
    case .emptyResponse:
        return "providerEmptyResponse"
    case .decoding:
        return "providerResponseUnreadable"
    }
}

/// A single cross-process lock shared by the menu-bar app and every browser
/// native-host process. It protects the two content-free UserDefaults ledgers
/// and the automatic-call reservation file from read/modify/write races.
struct BeanCrossProcessStoreLock {
    /// `flock` coordinates separate processes, but its same-process semantics
    /// are not a substitute for a thread mutex when many store instances open
    /// the same lock file concurrently. Serialize locally first, then acquire
    /// the file lock for the app/native-host boundary.
    private static let inProcessLock = NSLock()

    let directoryURL: URL
    private let lockURL: URL

    init(directoryURL: URL = Self.defaultDirectoryURL) {
        let canonicalDirectory = BeanSecureStorePath.canonicalizingSystemAliases(directoryURL)
        self.directoryURL = canonicalDirectory
        // Keep the original filename so an older native-host process and a new
        // app binary still coordinate during an in-place upgrade.
        self.lockURL = canonicalDirectory.appendingPathComponent("automatic-call-reservations.lock")
    }

    func withExclusiveLock(_ body: () -> Bool) -> Bool {
        Self.inProcessLock.lock()
        defer { Self.inProcessLock.unlock() }
        guard let descriptor = acquire() else { return false }
        defer { release(descriptor) }
        return body()
    }

    private func acquire() -> Int32? {
        guard BeanSecureStorePath.ensurePrivateDirectory(at: directoryURL),
              let descriptor = BeanSecureStorePath.openRegularFile(
                lockURL,
                flags: O_CREAT | O_RDWR,
                mode: S_IRUSR | S_IWUSR
              ) else { return nil }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                Darwin.close(descriptor)
                return nil
            }
        }
        return descriptor
    }

    private func release(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    static var defaultDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Bean/NativeMessaging", isDirectory: true)
    }
}

/// Content-free metadata captured before a provider request. Automatic paths use
/// it for reservations; the native Passive Preview retry uses the same shape for
/// an uncapped manual reservation. Browser identity is deliberately redacted at
/// this boundary so neither the operation history nor a crash-recovery lease can
/// retain a hostname or field semantics.
struct AutomaticCallMetadata: Codable, Equatable {
    let source: OperationSource
    let appName: String?
    let appBundleIdentifier: String?
    let appCategory: String
    let action: String
    let inputMode: String
    let inputLength: Int
    let provider: String
    let model: String

    private enum CodingKeys: String, CodingKey {
        case source, appName, appBundleIdentifier, appCategory, action
        case inputMode, inputLength, provider, model
    }

    init(source: OperationSource, appName: String?, appBundleIdentifier: String?,
         appCategory: String, action: String, inputMode: String, inputLength: Int,
         provider: String, model: String) {
        self.source = source
        let isBrowserAccounting = source == .webInline
        self.appName = isBrowserAccounting ? nil : OperationalMetadataSanitizer.optional(
            appName,
            maximumScalars: OperationalMetadataSanitizer.appNameMaximumScalars
        )
        self.appBundleIdentifier = isBrowserAccounting ? nil
            : OperationalMetadataSanitizer.optional(
                appBundleIdentifier,
                maximumScalars: OperationalMetadataSanitizer.bundleIdentifierMaximumScalars
            )
        self.appCategory = isBrowserAccounting ? "browser"
            : OperationalMetadataSanitizer.required(
                appCategory,
                maximumScalars: OperationalMetadataSanitizer.categoryMaximumScalars
            )
        self.action = OperationalMetadataSanitizer.required(
            action,
            maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
        )
        self.inputMode = isBrowserAccounting ? "browser"
            : OperationalMetadataSanitizer.required(
                inputMode,
                maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
            )
        self.inputLength = max(0, inputLength)
        self.provider = OperationalMetadataSanitizer.required(
            provider,
            maximumScalars: OperationalMetadataSanitizer.providerMaximumScalars
        )
        self.model = OperationalMetadataSanitizer.required(
            model,
            maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars
        )
    }

    init(source: OperationSource, context: SourceAppContext, action: String,
         inputLength: Int, provider: String, model: String) {
        self.init(
            source: source,
            appName: context.appName,
            appBundleIdentifier: context.bundleIdentifier,
            appCategory: AppCategory.from(bundleIdentifier: context.bundleIdentifier).rawValue,
            action: action,
            inputMode: context.acquisitionMode.rawLabel,
            inputLength: inputLength,
            provider: provider,
            model: model
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try container.decode(OperationSource.self, forKey: .source),
            appName: try container.decodeIfPresent(String.self, forKey: .appName),
            appBundleIdentifier: try container.decodeIfPresent(
                String.self, forKey: .appBundleIdentifier
            ),
            appCategory: try container.decode(String.self, forKey: .appCategory),
            action: try container.decode(String.self, forKey: .action),
            inputMode: try container.decode(String.self, forKey: .inputMode),
            inputLength: try container.decode(Int.self, forKey: .inputLength),
            provider: try container.decode(String.self, forKey: .provider),
            model: try container.decode(String.self, forKey: .model)
        )
    }
}

/// Atomically reserves and settles automatic provider attempts across the app,
/// browser host, passive suggestions, and native inline highlights.
///
/// A reservation is deliberately two-phase. Calls may be cancelled without
/// consuming the cap until `beginProviderAttempt()` durably marks that text is
/// about to leave the device. Once begun, success, provider failure, timeout,
/// cancellation, or process death all consume one daily attempt. Failures add
/// no token counts because the provider did not report any.
struct AutomaticCallBudgetStore {
    private static let usageRetentionDays = 120
    private static let maximumHistoryRecords = 50

    enum ReservationResult {
        case reserved(Reservation)
        case limitReached
        case unavailable
    }

    final class Reservation: @unchecked Sendable {
        let startedAt: Date

        private enum Phase {
            case reserved
            case attemptStarted
            case resolved
        }

        private struct PendingSettlement {
            let usage: LLMUsage?
            let outputLength: Int?
            let safetyResult: String
            let outcome: String
        }

        private let id: UUID
        private let store: AutomaticCallBudgetStore
        private let metadata: AutomaticCallMetadata
        private let stateLock = NSLock()
        private var phase: Phase = .reserved
        private var pendingSettlement: PendingSettlement?

        fileprivate init(id: UUID, startedAt: Date, metadata: AutomaticCallMetadata,
                         store: AutomaticCallBudgetStore) {
            self.id = id
            self.startedAt = startedAt
            self.metadata = metadata
            self.store = store
        }

        /// Must succeed immediately before invoking the provider. If this
        /// marker cannot be persisted, callers fail closed and spend no tokens.
        @discardableResult
        func beginProviderAttempt() -> Bool {
            stateLock.lock()
            guard phase == .reserved else {
                stateLock.unlock()
                return false
            }
            let marked = store.markAttemptStarted(id: id)
            phase = marked ? .attemptStarted : .resolved
            stateLock.unlock()
            if !marked { store.releaseUnstarted(id: id) }
            return marked
        }

        /// Settles a successful request with the provider's real usage (or the
        /// provider parser's explicitly-labelled conservative estimate).
        @discardableResult
        func complete(usage: LLMUsage, outputLength: Int,
                      safetyResult: String, outcome: String) -> Bool {
            resolve(usage: usage, outputLength: outputLength,
                    safetyResult: safetyResult, outcome: outcome)
        }

        /// Settles a request that reached the provider but failed or timed out.
        /// The attempt consumes the cap; tokens remain absent, not estimated.
        @discardableResult
        func fail(outcome: String, safetyResult: String = "notRun") -> Bool {
            resolve(usage: nil, outputLength: nil,
                    safetyResult: safetyResult, outcome: outcome)
        }

        /// Releases a pre-provider reservation. Once the provider attempt has
        /// begun, cancellation is itself a failed attempt and must consume it.
        func cancel() {
            stateLock.lock()
            let current = phase
            if current == .reserved { phase = .resolved }
            stateLock.unlock()

            switch current {
            case .reserved:
                store.releaseUnstarted(id: id)
            case .attemptStarted:
                _ = fail(outcome: "providerAttemptCancelled")
            case .resolved:
                break
            }
        }

        deinit {
            stateLock.lock()
            let current = phase
            let pending = pendingSettlement
            phase = .resolved
            stateLock.unlock()

            switch current {
            case .reserved:
                store.releaseUnstarted(id: id)
            case .attemptStarted:
                _ = store.settle(
                    id: id,
                    metadata: metadata,
                    usage: pending?.usage,
                    outputLength: pending?.outputLength,
                    safetyResult: pending?.safetyResult ?? "notRun",
                    outcome: pending?.outcome ?? "providerAttemptAbandoned"
                )
            case .resolved:
                break
            }
        }

        private func resolve(usage: LLMUsage?, outputLength: Int?,
                             safetyResult: String, outcome: String) -> Bool {
            stateLock.lock()
            guard phase == .attemptStarted else {
                let alreadyResolved = phase == .resolved
                stateLock.unlock()
                return alreadyResolved
            }
            if pendingSettlement == nil {
                pendingSettlement = PendingSettlement(
                    usage: usage,
                    outputLength: outputLength,
                    safetyResult: safetyResult,
                    outcome: outcome
                )
            }
            let pending = pendingSettlement!
            let settled = store.settle(
                id: id,
                metadata: metadata,
                usage: pending.usage,
                outputLength: pending.outputLength,
                safetyResult: pending.safetyResult,
                outcome: pending.outcome
            )
            if settled {
                phase = .resolved
                pendingSettlement = nil
            }
            stateLock.unlock()
            return settled
        }
    }

    /// Minimal crash-recovery metadata. App names, bundle identifiers, website
    /// hostnames, field roles, and input modes never enter the reservation file.
    private struct PersistedCallMetadata: Codable, Equatable {
        let source: OperationSource
        let action: String
        let inputLength: Int
        let provider: String
        let model: String

        private enum CodingKeys: String, CodingKey {
            case source, action, inputLength, provider, model
        }

        init(_ metadata: AutomaticCallMetadata) {
            source = metadata.source
            action = OperationalMetadataSanitizer.required(
                metadata.action,
                maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
            )
            inputLength = max(0, metadata.inputLength)
            provider = OperationalMetadataSanitizer.required(
                metadata.provider,
                maximumScalars: OperationalMetadataSanitizer.providerMaximumScalars
            )
            model = OperationalMetadataSanitizer.required(
                metadata.model,
                maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decode(OperationSource.self, forKey: .source)
            action = OperationalMetadataSanitizer.required(
                try container.decode(String.self, forKey: .action),
                maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
            )
            inputLength = max(0, try container.decode(Int.self, forKey: .inputLength))
            provider = OperationalMetadataSanitizer.required(
                try container.decode(String.self, forKey: .provider),
                maximumScalars: OperationalMetadataSanitizer.providerMaximumScalars
            )
            model = OperationalMetadataSanitizer.required(
                try container.decode(String.self, forKey: .model),
                maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars
            )
        }

        var recovered: AutomaticCallMetadata {
            AutomaticCallMetadata(
                source: source,
                appName: nil,
                appBundleIdentifier: nil,
                appCategory: source == .webInline ? "browser" : "unknown",
                action: action,
                inputMode: source == .webInline ? "browser" : "unknown",
                inputLength: inputLength,
                provider: provider,
                model: model
            )
        }
    }

    private struct Lease: Codable {
        let id: UUID
        let startedAt: Date
        let expiresAt: Date
        let metadata: PersistedCallMetadata
        var attemptStartedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id, startedAt, expiresAt, metadata, attemptStartedAt
        }

        init(id: UUID, startedAt: Date, expiresAt: Date,
             metadata: PersistedCallMetadata, attemptStartedAt: Date?) {
            self.id = id
            self.startedAt = startedAt
            self.expiresAt = expiresAt
            self.metadata = metadata
            self.attemptStartedAt = attemptStartedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            startedAt = try container.decode(Date.self, forKey: .startedAt)
            expiresAt = try container.decode(Date.self, forKey: .expiresAt)
            metadata = try container.decodeIfPresent(PersistedCallMetadata.self,
                                                      forKey: .metadata)
                ?? PersistedCallMetadata(AutomaticCallMetadata(
                    source: .webInline,
                    appName: nil,
                    appBundleIdentifier: nil,
                    appCategory: "unknown",
                    action: "legacyReservation",
                    inputMode: "unknown",
                    inputLength: 0,
                    provider: "unknown",
                    model: "unknown"
                ))
            // Version-one leases predate the durable provider-start marker and
            // are therefore treated as safe-to-release preflight reservations.
            attemptStartedAt = try container.decodeIfPresent(Date.self,
                                                              forKey: .attemptStartedAt)
        }
    }

    private struct ResolutionMarker: Codable {
        let id: UUID
        let resolvedAt: Date
    }

    private struct SpentDay: Codable {
        let day: Date
        var count: Int
    }

    private struct State: Codable {
        var version: Int
        var leases: [Lease]
        var resolutions: [ResolutionMarker]
        var spentDays: [SpentDay]

        init(version: Int = 3, leases: [Lease] = [],
             resolutions: [ResolutionMarker] = [], spentDays: [SpentDay] = []) {
            self.version = version
            self.leases = leases
            self.resolutions = resolutions
            self.spentDays = spentDays
        }

        private enum CodingKeys: String, CodingKey {
            case version, leases, resolutions, spentDays
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            leases = try container.decode([Lease].self, forKey: .leases)
            resolutions = try container.decodeIfPresent([ResolutionMarker].self,
                                                         forKey: .resolutions) ?? []
            spentDays = try container.decodeIfPresent([SpentDay].self,
                                                       forKey: .spentDays) ?? []
        }
    }

    private let defaults: UserDefaults
    private let usageStorageKey: String
    private let historyStorageKey: String
    private let calendar: Calendar
    private let lock: BeanCrossProcessStoreLock
    private let stateURL: URL
    private let now: @Sendable () -> Date
    private let removeDefaultsValue: (String) -> Void

    init(defaults: UserDefaults = .standard,
         usageStorageKey: String = "usageLedgerV1",
         historyStorageKey: String = "operationHistoryV1",
         calendar: Calendar = .current,
         directoryURL: URL = BeanCrossProcessStoreLock.defaultDirectoryURL,
         now: @escaping @Sendable () -> Date = { Date() },
         removeDefaultsValue: ((String) -> Void)? = nil) {
        self.defaults = defaults
        self.usageStorageKey = usageStorageKey
        self.historyStorageKey = historyStorageKey
        self.calendar = calendar
        let canonicalDirectory = BeanSecureStorePath.canonicalizingSystemAliases(directoryURL)
        self.lock = BeanCrossProcessStoreLock(directoryURL: canonicalDirectory)
        self.stateURL = canonicalDirectory.appendingPathComponent("automatic-call-reservations.json")
        self.now = now
        self.removeDefaultsValue = removeDefaultsValue ?? { key in
            defaults.removeObject(forKey: key)
        }
    }

    func reserve(dailyLimit: Int, leaseDuration: TimeInterval,
                 metadata: AutomaticCallMetadata) -> ReservationResult {
        guard metadata.source.isAutomaticProviderPath else { return .unavailable }
        return createReservation(
            dailyLimit: AutomaticCallBudgetPolicy.requestedDailyLimit(dailyLimit),
            leaseDuration: leaseDuration,
            metadata: metadata
        )
    }

    /// Reserves an explicitly requested native-app provider call without
    /// consuming or consulting the automatic daily cap. It keeps the same
    /// crash-safe, content-free settlement guarantees as an automatic call.
    func reserveManual(leaseDuration: TimeInterval,
                       metadata: AutomaticCallMetadata) -> ReservationResult {
        guard metadata.source == .manual else { return .unavailable }
        return createReservation(
            dailyLimit: nil,
            leaseDuration: leaseDuration,
            metadata: metadata
        )
    }

    /// Repairs expired leases and reconciles the private spent counter. Called
    /// on app launch and by native-host status so crash metadata cannot linger
    /// indefinitely just because automatic suggestions were later disabled.
    @discardableResult
    func cleanupStaleReservations() -> Bool {
        let timestamp = now()
        return lock.withExclusiveLock {
            // Attempt both privacy migrations even if one store is corrupt, so
            // an unrelated bad history payload cannot leave identity-bearing
            // legacy lease metadata on disk.
            let historySanitized = sanitizeStoredOperationHistory()
            let usageSanitized = sanitizeStoredUsageLedger(at: timestamp)
            guard var state = readStateScrubbingLegacyMetadata(),
                  historySanitized, usageSanitized else { return false }
            guard repairStaleLeases(&state, at: timestamp),
                  reconcileSpentCounter(&state, at: timestamp) else { return false }
            state.version = 3
            pruneSpentDays(&state, at: timestamp)
            return writeState(state)
        }
    }

    /// The authoritative current-day automatic-attempt count. Unlike the
    /// visible usage dashboard, this value deliberately survives Clear Usage.
    func automaticCallsToday() -> Int? {
        let timestamp = now()
        var result: Int?
        let succeeded = lock.withExclusiveLock {
            let historySanitized = sanitizeStoredOperationHistory()
            let usageSanitized = sanitizeStoredUsageLedger(at: timestamp)
            guard var state = readStateScrubbingLegacyMetadata(),
                  historySanitized,
                  usageSanitized,
                  repairStaleLeases(&state, at: timestamp),
                  reconcileSpentCounter(&state, at: timestamp),
                  let count = spentCount(in: state, on: timestamp) else { return false }
            state.version = 3
            pruneSpentDays(&state, at: timestamp)
            guard writeState(state) else { return false }
            result = count
            return true
        }
        return succeeded ? result : nil
    }

    struct ClearResult: Equatable {
        let automaticCallsToday: Int
    }

    struct ResetResult: Equatable {
        let privateStateRemoved: Bool
        let visibleUsageRemoved: Bool
        let visibleHistoryRemoved: Bool

        var succeeded: Bool {
            privateStateRemoved && visibleUsageRemoved && visibleHistoryRemoved
        }

        static let complete = ResetResult(
            privateStateRemoved: true,
            visibleUsageRemoved: true,
            visibleHistoryRemoved: true
        )
    }

    /// Clears the two user-visible accounting ledgers as one coordinated
    /// operation. Existing leases are tombstoned first, preventing a late
    /// completion from silently recreating data the user just erased. The
    /// private current-day spent counter remains so clearing history cannot reset
    /// the user's cost guard.
    func clearVisibleAccounting() -> ClearResult? {
        let timestamp = now()
        var result: ClearResult?
        let succeeded = lock.withExclusiveLock {
            guard var state = readStateScrubbingLegacyMetadata() else { return false }

            // Version-three state is already authoritative, so corrupt visible
            // data can still be erased safely. Older state must first reconcile
            // with its visible ledger or clearing could restore paid capacity.
            if !reconcileSpentCounter(
                &state, at: timestamp,
                allowsUnavailableVisibleLedger: state.version >= 3
            ) {
                return false
            }

            for lease in state.leases {
                if !state.resolutions.contains(where: { $0.id == lease.id }) {
                    state.resolutions.append(ResolutionMarker(id: lease.id, resolvedAt: timestamp))
                }
            }
            state.leases.removeAll()
            pruneResolutionMarkers(&state, at: timestamp)
            pruneSpentDays(&state, at: timestamp)
            state.version = 3
            guard let count = spentCount(in: state, on: timestamp),
                  writeState(state) else { return false }

            defaults.removeObject(forKey: usageStorageKey)
            defaults.removeObject(forKey: historyStorageKey)
            defaults.synchronize()
            guard defaults.object(forKey: usageStorageKey) == nil,
                  defaults.object(forKey: historyStorageKey) == nil else { return false }
            result = ClearResult(automaticCallsToday: count)
            return true
        }
        return succeeded ? result : nil
    }

    /// Removes every visible and private accounting record for an explicit full
    /// app reset. Unlike `clearVisibleAccounting`, this deliberately resets the
    /// current-day automatic counter as well. The operation runs under the same
    /// cross-process lock as reservations so no native-host process can race the
    /// removal. A late settlement whose lease was removed fails closed and cannot
    /// recreate either visible ledger.
    func resetAllAccounting() -> ResetResult {
        var result = ResetResult(
            privateStateRemoved: false,
            visibleUsageRemoved: false,
            visibleHistoryRemoved: false
        )
        let entered = lock.withExclusiveLock {
            let privateStateRemoved: Bool
            switch BeanSecureStorePath.entry(at: stateURL) {
            case .missing:
                privateStateRemoved = true
            case .regularFile:
                privateStateRemoved = Darwin.unlink(stateURL.path) == 0
                    && BeanSecureStorePath.entry(at: stateURL) == .missing
            case .unsafe:
                privateStateRemoved = false
            }

            removeDefaultsValue(usageStorageKey)
            removeDefaultsValue(historyStorageKey)
            defaults.synchronize()
            result = ResetResult(
                privateStateRemoved: privateStateRemoved,
                visibleUsageRemoved: defaults.object(forKey: usageStorageKey) == nil,
                visibleHistoryRemoved: defaults.object(forKey: historyStorageKey) == nil
            )
            return true
        }
        return entered ? result : ResetResult(
            privateStateRemoved: false,
            visibleUsageRemoved: false,
            visibleHistoryRemoved: false
        )
    }

    private func createReservation(dailyLimit: Int?, leaseDuration: TimeInterval,
                                   metadata: AutomaticCallMetadata) -> ReservationResult {
        let timestamp = now()
        var result: ReservationResult = .unavailable
        let succeeded = lock.withExclusiveLock {
            let historySanitized = sanitizeStoredOperationHistory()
            let usageSanitized = sanitizeStoredUsageLedger(at: timestamp)
            guard var state = readStateScrubbingLegacyMetadata(),
                  historySanitized,
                  usageSanitized,
                  repairStaleLeases(&state, at: timestamp),
                  reconcileSpentCounter(&state, at: timestamp),
                  decodedOperationRecords() != nil else { return false }

            if let dailyLimit {
                guard let spent = spentCount(in: state, on: timestamp) else { return false }
                let preflight = state.leases.filter {
                    $0.metadata.source.isAutomaticProviderPath
                        && $0.attemptStartedAt == nil
                        && calendar.isDate($0.startedAt, inSameDayAs: timestamp)
                }.count
                let capacity = spent.addingReportingOverflow(preflight)
                guard !capacity.overflow else { return false }
                guard capacity.partialValue < dailyLimit else {
                    state.version = 3
                    guard writeState(state) else { return false }
                    result = .limitReached
                    return true
                }
            }

            let id = UUID()
            state.leases.append(Lease(
                id: id,
                startedAt: timestamp,
                expiresAt: timestamp.addingTimeInterval(max(1, leaseDuration)),
                metadata: PersistedCallMetadata(metadata),
                attemptStartedAt: nil
            ))
            state.version = 3
            pruneSpentDays(&state, at: timestamp)
            guard writeState(state) else { return false }
            result = .reserved(Reservation(
                id: id, startedAt: timestamp, metadata: metadata, store: self
            ))
            return true
        }
        return succeeded ? result : .unavailable
    }

    private func markAttemptStarted(id: UUID) -> Bool {
        lock.withExclusiveLock {
            guard var state = readStateScrubbingLegacyMetadata() else { return false }
            let timestamp = now()
            guard repairStaleLeases(&state, at: timestamp),
                  let index = state.leases.firstIndex(where: { $0.id == id }),
                  state.leases[index].attemptStartedAt == nil,
                  reconcileSpentCounter(&state, at: timestamp) else { return false }
            if state.leases[index].metadata.source.isAutomaticProviderPath {
                guard incrementSpent(&state, on: state.leases[index].startedAt) else { return false }
            }
            state.leases[index].attemptStartedAt = timestamp
            state.version = 3
            return writeState(state)
        }
    }

    private func settle(id: UUID, metadata: AutomaticCallMetadata,
                        usage: LLMUsage?, outputLength: Int?,
                        safetyResult: String, outcome: String) -> Bool {
        lock.withExclusiveLock {
            guard var state = readStateScrubbingLegacyMetadata() else { return false }
            let timestamp = now()
            guard repairStaleLeases(&state, at: timestamp, preserving: id),
                  reconcileSpentCounter(&state, at: timestamp) else { return false }
            if state.resolutions.contains(where: { $0.id == id }) {
                return writeState(state)
            }
            guard let lease = state.leases.first(where: { $0.id == id }),
                  lease.attemptStartedAt != nil,
                  lease.metadata == PersistedCallMetadata(metadata) else {
                _ = writeState(state)
                return false
            }

            guard recordAttempt(
                id: id,
                metadata: metadata,
                startedAt: lease.startedAt,
                usage: usage,
                outputLength: outputLength,
                safetyResult: safetyResult,
                outcome: outcome
            ) else { return false }
            state.leases.removeAll { $0.id == id }
            state.resolutions.append(ResolutionMarker(id: id, resolvedAt: timestamp))
            pruneResolutionMarkers(&state, at: timestamp)
            pruneSpentDays(&state, at: timestamp)
            state.version = 3
            // The attempt is already durably counted. Leaving a lease behind if
            // this final write fails is conservative: it can only block spend.
            // If storage never recovers before expiry, stale repair may add one
            // extra nil-token failure rather than ever restoring paid capacity.
            _ = writeState(state)
            return true
        }
    }

    private func releaseUnstarted(id: UUID) {
        _ = lock.withExclusiveLock {
            guard var state = readStateScrubbingLegacyMetadata() else { return false }
            guard let lease = state.leases.first(where: { $0.id == id }) else { return true }
            guard lease.attemptStartedAt == nil else { return false }
            state.leases.removeAll { $0.id == id }
            return writeState(state)
        }
    }

    /// Expired preflight leases are released. Expired provider attempts become
    /// content-free failed operations so a crash cannot quietly restore budget.
    private func repairStaleLeases(_ state: inout State, at date: Date,
                                   preserving id: UUID? = nil) -> Bool {
        var retained: [Lease] = []
        for lease in state.leases {
            guard lease.id != id else {
                retained.append(lease)
                continue
            }
            let isStale = lease.expiresAt <= date
                || !calendar.isDate(lease.startedAt, inSameDayAs: date)
            guard isStale else {
                retained.append(lease)
                continue
            }
            if lease.attemptStartedAt != nil {
                guard recordAttempt(
                    id: lease.id,
                    metadata: lease.metadata.recovered,
                    startedAt: lease.startedAt,
                    usage: nil,
                    outputLength: nil,
                    safetyResult: "notRun",
                    outcome: "providerAttemptExpired"
                ) else { return false }
            }
            state.resolutions.append(ResolutionMarker(id: lease.id, resolvedAt: date))
        }
        state.leases = retained
        pruneResolutionMarkers(&state, at: date)
        state.version = 3
        return true
    }

    private func pruneResolutionMarkers(_ state: inout State, at date: Date) {
        let cutoff = calendar.date(byAdding: .day, value: -2,
                                   to: calendar.startOfDay(for: date)) ?? date
        state.resolutions.removeAll { $0.resolvedAt < cutoff }
    }

    private func automaticCalls(on date: Date) -> Int? {
        defaults.synchronize()
        guard let buckets = decodedUsageBuckets() else { return nil }
        var count = 0
        for bucket in buckets where calendar.isDate(bucket.day, inSameDayAs: date)
            && bucket.source.isAutomaticProviderPath {
            let addition = count.addingReportingOverflow(bucket.operationCount)
            if addition.overflow { return Int.max }
            count = addition.partialValue
        }
        return count
    }

    private func reconcileSpentCounter(
        _ state: inout State,
        at date: Date,
        allowsUnavailableVisibleLedger: Bool = false
    ) -> Bool {
        let recorded: Int
        if let count = automaticCalls(on: date) {
            recorded = count
        } else {
            guard allowsUnavailableVisibleLedger, state.version >= 3 else { return false }
            pruneSpentDays(&state, at: date)
            return spentCount(in: state, on: date) != nil
        }

        guard let records = decodedOperationRecords() else {
            // A version-three private counter has already been durably
            // reconciled at every provider start. During an explicit clear it
            // is therefore safe to discard a corrupt visible history without
            // using it to reconstruct the cap. Ordinary reserve/status paths
            // still fail closed so corruption cannot go unnoticed there.
            guard allowsUnavailableVisibleLedger, state.version >= 3 else { return false }
            pruneSpentDays(&state, at: date)
            return spentCount(in: state, on: date) != nil
        }
        let recordedIDs = Set(records.map(\.id))
        let started = state.leases.filter {
            $0.metadata.source.isAutomaticProviderPath
                && $0.attemptStartedAt != nil
                && !recordedIDs.contains($0.id)
                && calendar.isDate($0.startedAt, inSameDayAs: date)
        }.count
        let visibleAndStarted = recorded.addingReportingOverflow(started)
        guard !visibleAndStarted.overflow,
              let existing = spentCount(in: state, on: date) else { return false }
        setSpent(&state, on: date, to: max(existing, visibleAndStarted.partialValue))
        state.version = 3
        pruneSpentDays(&state, at: date)
        return true
    }

    private func spentCount(in state: State, on date: Date) -> Int? {
        var count = 0
        for entry in state.spentDays where calendar.isDate(entry.day, inSameDayAs: date) {
            let addition = count.addingReportingOverflow(entry.count)
            if addition.overflow { return nil }
            count = addition.partialValue
        }
        return count
    }

    private func setSpent(_ state: inout State, on date: Date, to count: Int) {
        state.spentDays.removeAll { calendar.isDate($0.day, inSameDayAs: date) }
        state.spentDays.append(SpentDay(day: calendar.startOfDay(for: date), count: count))
    }

    private func incrementSpent(_ state: inout State, on date: Date) -> Bool {
        guard let current = spentCount(in: state, on: date) else { return false }
        let next = current.addingReportingOverflow(1)
        guard !next.overflow else { return false }
        setSpent(&state, on: date, to: next.partialValue)
        return true
    }

    private func pruneSpentDays(_ state: inout State, at date: Date) {
        let cutoff = calendar.date(byAdding: .day, value: -2,
                                   to: calendar.startOfDay(for: date)) ?? date
        state.spentDays.removeAll { $0.day < cutoff }
    }

    private func recordAttempt(id: UUID, metadata: AutomaticCallMetadata, startedAt: Date,
                               usage: LLMUsage?, outputLength: Int?,
                               safetyResult: String, outcome: String) -> Bool {
        defaults.synchronize()
        guard var buckets = decodedUsageBuckets(),
              var records = decodedOperationRecords() else { return false }
        // The reservation UUID is also the operation UUID. If usage/history were
        // written but the final lease-state write failed, a retry settles the
        // lease without double-counting the paid call.
        if records.contains(where: { $0.id == id }) { return true }
        let day = calendar.startOfDay(for: startedAt)
        if let index = buckets.firstIndex(where: {
            calendar.isDate($0.day, inSameDayAs: day)
                && $0.source == metadata.source
                && $0.provider == metadata.provider
                && $0.model == metadata.model
        }) {
            let input = buckets[index].inputTokens.addingReportingOverflow(
                usage?.inputTokens ?? 0
            )
            let output = buckets[index].outputTokens.addingReportingOverflow(
                usage?.outputTokens ?? 0
            )
            let operations = buckets[index].operationCount.addingReportingOverflow(1)
            let estimated = buckets[index].estimatedOperationCount.addingReportingOverflow(
                usage?.isEstimated == true ? 1 : 0
            )
            guard !input.overflow, !output.overflow,
                  !operations.overflow, !estimated.overflow else { return false }
            buckets[index].inputTokens = input.partialValue
            buckets[index].outputTokens = output.partialValue
            buckets[index].operationCount = operations.partialValue
            buckets[index].estimatedOperationCount = estimated.partialValue
        } else {
            buckets.append(DailyUsageBucket(
                day: day,
                source: metadata.source,
                provider: metadata.provider,
                model: metadata.model,
                inputTokens: usage?.inputTokens ?? 0,
                outputTokens: usage?.outputTokens ?? 0,
                operationCount: 1,
                estimatedOperationCount: usage?.isEstimated == true ? 1 : 0
            ))
        }
        if let cutoff = calendar.date(byAdding: .day, value: -Self.usageRetentionDays,
                                      to: calendar.startOfDay(for: startedAt)) {
            buckets.removeAll { $0.day < cutoff }
        }

        records.insert(OperationRecord(
            id: id,
            timestamp: startedAt,
            source: metadata.source,
            appName: metadata.appName,
            appBundleIdentifier: metadata.appBundleIdentifier,
            appCategory: metadata.appCategory,
            action: metadata.action,
            inputMode: metadata.inputMode,
            inputLength: metadata.inputLength,
            outputLength: outputLength,
            provider: metadata.provider,
            model: metadata.model,
            safetyResult: safetyResult,
            outcome: outcome,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            usageEstimated: usage?.isEstimated ?? false
        ), at: 0)
        records = Array(records.prefix(Self.maximumHistoryRecords))

        guard let usageData = try? JSONEncoder().encode(buckets),
              let historyData = try? JSONEncoder().encode(records) else { return false }
        defaults.set(usageData, forKey: usageStorageKey)
        defaults.set(historyData, forKey: historyStorageKey)
        defaults.synchronize()
        return true
    }

    private func decodedUsageBuckets() -> [DailyUsageBucket]? {
        guard let data = defaults.data(forKey: usageStorageKey) else { return [] }
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode([DailyUsageBucket].self, from: data) else {
            return nil
        }
        guard decoded.allSatisfy({
            $0.inputTokens >= 0 && $0.outputTokens >= 0
                && $0.operationCount >= 0 && $0.estimatedOperationCount >= 0
                && $0.estimatedOperationCount <= $0.operationCount
        }) else { return nil }
        return decoded
    }

    /// Rewrites provider/model labels decoded from older visible ledgers while
    /// the shared lock is held. Comparing encoded bytes catches sanitation done
    /// by `DailyUsageBucket.init(from:)`, not just semantic object changes.
    private func sanitizeStoredUsageLedger(at date: Date) -> Bool {
        defaults.synchronize()
        guard let data = defaults.data(forKey: usageStorageKey) else { return true }
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode([DailyUsageBucket].self, from: data),
              decoded.allSatisfy({
                  $0.inputTokens >= 0 && $0.outputTokens >= 0
                      && $0.operationCount >= 0 && $0.estimatedOperationCount >= 0
                      && $0.estimatedOperationCount <= $0.operationCount
              }) else { return false }
        let cutoff = calendar.date(
            byAdding: .day,
            value: -Self.usageRetentionDays,
            to: calendar.startOfDay(for: date)
        ) ?? date
        let retained = decoded.filter { $0.day >= cutoff }
        guard let encoded = try? JSONEncoder().encode(retained) else { return false }
        guard encoded != data else { return true }
        defaults.set(encoded, forKey: usageStorageKey)
        defaults.synchronize()
        return defaults.data(forKey: usageStorageKey) == encoded
    }

    private func decodedOperationRecords() -> [OperationRecord]? {
        guard let data = defaults.data(forKey: historyStorageKey) else { return [] }
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode([OperationRecord].self, from: data) else {
            return nil
        }
        return decoded.map(\.persistenceSanitized)
    }

    /// One-time upgrade cleanup for browser history written by earlier builds.
    /// Runs only while the shared cross-process lock is held.
    private func sanitizeStoredOperationHistory() -> Bool {
        defaults.synchronize()
        guard let data = defaults.data(forKey: historyStorageKey) else { return true }
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode([OperationRecord].self, from: data) else {
            return false
        }
        let sanitized = decoded.map(\.persistenceSanitized)
        guard let encoded = try? JSONEncoder().encode(sanitized) else { return false }
        guard encoded != data else { return true }
        defaults.set(encoded, forKey: historyStorageKey)
        defaults.synchronize()
        return true
    }

    private func readState() -> State? {
        // Missing state may be a first run or an upgrade from the visible-ledger
        // implementation. Treat it as legacy until reconciliation succeeds;
        // otherwise a corrupt legacy ledger could be cleared to restore capacity.
        switch BeanSecureStorePath.entry(at: stateURL) {
        case .missing:
            return State(version: 1)
        case .unsafe:
            return nil
        case .regularFile:
            break
        }
        guard let data = BeanSecureStorePath.readRegularFile(
                  at: stateURL, maximumBytes: 1_000_000
              ), !data.isEmpty,
              let state = try? JSONDecoder().decode(State.self, from: data),
              (1...3).contains(state.version),
              state.leases.allSatisfy({ lease in
                  (lease.metadata.source.isAutomaticProviderPath || lease.metadata.source == .manual)
                      && lease.metadata.inputLength >= 0
                      && lease.startedAt.timeIntervalSinceReferenceDate.isFinite
                      && lease.expiresAt.timeIntervalSinceReferenceDate.isFinite
                      && lease.expiresAt >= lease.startedAt
              }),
              state.resolutions.allSatisfy({
                  $0.resolvedAt.timeIntervalSinceReferenceDate.isFinite
              }),
              state.spentDays.allSatisfy({
                  $0.count >= 0 && $0.day.timeIntervalSinceReferenceDate.isFinite
              }) else { return nil }
        return state
    }

    /// Decoding drops legacy app/browser identity and normalizes every retained
    /// label. Rewrite the sanitized shape immediately, including version-three
    /// files, so a hostile or oversized value never remains in crash storage.
    /// The version itself is preserved until visible-ledger reconciliation
    /// succeeds.
    /// Must be called only while `lock` is held.
    private func readStateScrubbingLegacyMetadata() -> State? {
        let existed = BeanSecureStorePath.entry(at: stateURL) == .regularFile
        guard let state = readState() else { return nil }
        guard !existed || writeState(state) else { return nil }
        return state
    }

    private func writeState(_ state: State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        return BeanSecureStorePath.writeAtomically(data, to: stateURL)
    }
}
