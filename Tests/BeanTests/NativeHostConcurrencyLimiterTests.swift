import Foundation
import XCTest
@testable import Bean

final class NativeHostConcurrencyLimiterTests: XCTestCase {
    func testOfflineSpellingAndOwnershipRemainAvailableWhileProviderCapacityIsFull() {
        let limiter = NativeHostConcurrencyLimiter(maximumInFlight: 5, maximumProviderInFlight: 2)
        XCTAssertTrue(limiter.acquire(providerBacked: true))
        XCTAssertTrue(limiter.acquire(providerBacked: true))
        XCTAssertFalse(limiter.acquire(providerBacked: true))
        XCTAssertTrue(limiter.acquire(providerBacked: false))
        XCTAssertTrue(limiter.acquire(providerBacked: false))
        XCTAssertTrue(limiter.acquire(providerBacked: false))
        XCTAssertFalse(limiter.acquire(providerBacked: false))
        limiter.release(providerBacked: false)
        XCTAssertTrue(limiter.acquire(providerBacked: false))
        XCTAssertFalse(limiter.acquire(providerBacked: true))
        limiter.release(providerBacked: true)
        XCTAssertTrue(limiter.acquire(providerBacked: true))
    }

    func testConcurrentAcquisitionCannotExceedProviderLimit() {
        let limiter = NativeHostConcurrencyLimiter(maximumInFlight: 20, maximumProviderInFlight: 2)
        let lock = NSLock()
        var accepted = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if limiter.acquire(providerBacked: true) {
                lock.lock()
                accepted += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(accepted, 2)
        XCTAssertTrue(limiter.acquire(providerBacked: false))
    }
}
