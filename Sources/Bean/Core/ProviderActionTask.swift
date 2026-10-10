import Foundation

/// Cancellation is also an application boundary. Even a transport that ignores
/// Task cancellation cannot return a result eligible for replacing the source.
@MainActor
final class ProviderActionTask {
    private var task: Task<LLMCompletion, Error>?
    private var cancelled = false
    var isRunning: Bool { task != nil }

    func run(_ operation: @escaping () async throws -> LLMCompletion) async throws -> LLMCompletion? {
        precondition(task == nil, "Provider actions must be serialized")
        cancelled = false
        let pending = Task { try await operation() }
        task = pending
        defer { task = nil }
        do {
            let completion = try await pending.value
            return cancelled ? nil : completion
        } catch {
            if cancelled || error is CancellationError { return nil }
            throw error
        }
    }

    func cancel() {
        guard let task else { return }
        cancelled = true
        task.cancel()
    }
}
