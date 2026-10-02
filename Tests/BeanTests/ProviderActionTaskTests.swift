import XCTest
@testable import Bean

@MainActor
final class ProviderActionTaskTests: XCTestCase {
    private let completion = LLMCompletion(text: "Corrected synthetic text.",
        usage: LLMUsage(inputTokens: 4, outputTokens: 4, isEstimated: true))

    func testCancelledTransportCannotDeliverLateReplacement() async throws {
        let runner = ProviderActionTask()
        let started = expectation(description: "Provider started")
        var transport: CheckedContinuation<LLMCompletion, Never>?
        let action = Task { try await runner.run {
            await withCheckedContinuation { transport = $0; started.fulfill() }
        } }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(runner.isRunning)
        runner.cancel()
        // This deliberately models a transport that ignores cancellation.
        transport?.resume(returning: completion)
        let returned = try await action.value
        XCTAssertNil(returned, "A late paid response must never reach replacement")
        XCTAssertFalse(runner.isRunning)
        let next = try await runner.run { self.completion }
        XCTAssertEqual(next, completion, "Cancellation must not leak into the next action")
    }

    func testCooperativeCancellationEndsWithoutProviderFailure() async throws {
        let runner = ProviderActionTask()
        let result = try await runner.run { throw CancellationError() }
        XCTAssertNil(result)
        XCTAssertFalse(runner.isRunning)
    }

    func testRealProviderFailureRemainsAnErrorAndReleasesSession() async {
        enum Failure: Error { case offline }
        let runner = ProviderActionTask()
        do {
            _ = try await runner.run { throw Failure.offline }
            XCTFail("A provider failure cannot be presented as cancellation or a clean result")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertFalse(runner.isRunning)
    }
}
