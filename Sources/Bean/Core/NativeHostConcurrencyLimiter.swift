import Foundation

/// A slow provider response must not hold offline spelling, status, or field
/// ownership behind it. Bound concurrent work without storing request text.
final class NativeHostConcurrencyLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumInFlight: Int
    private let maximumProviderInFlight: Int
    private var inFlight = 0
    private var providersInFlight = 0

    init(maximumInFlight: Int = 32, maximumProviderInFlight: Int = 2) {
        self.maximumInFlight = max(1, maximumInFlight)
        self.maximumProviderInFlight = max(1, min(maximumProviderInFlight, maximumInFlight))
    }

    func acquire(providerBacked: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < maximumInFlight,
              !providerBacked || providersInFlight < maximumProviderInFlight else { return false }
        inFlight += 1
        if providerBacked { providersInFlight += 1 }
        return true
    }

    func release(providerBacked: Bool) {
        lock.lock()
        defer { lock.unlock() }
        inFlight = max(0, inFlight - 1)
        if providerBacked { providersInFlight = max(0, providersInFlight - 1) }
    }
}
