import Foundation

struct DailyUsageBucket: Codable, Equatable, Identifiable {
    let day: Date
    let source: OperationSource
    let provider: String
    let model: String
    var inputTokens: Int
    var outputTokens: Int
    var operationCount: Int
    var estimatedOperationCount: Int

    var id: String {
        "\(day.timeIntervalSince1970)|\(source.rawValue)|\(provider)|\(model)"
    }
}

struct UsageSummary: Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let operationCount: Int
    let automaticOperationCount: Int
    let estimatedOperationCount: Int
    let estimatedCostUSD: Double
    let unpricedOperationCount: Int

    var totalTokens: Int { inputTokens + outputTokens }
    var averageTokensPerOperation: Int {
        operationCount == 0 ? 0 : totalTokens / operationCount
    }
}

/// Provider pricing used only for an explicitly labelled estimate. Unknown or
/// custom models are excluded instead of pretending their cost is known.
enum UsageCostEstimator {
    static let pricingSnapshot = "August 21, 2026"

    static func rates(provider: String, model: String) -> (input: Double, output: Double)? {
        let lower = model.lowercased()
        if provider == ProviderKind.openai.rawValue {
            if lower == "gpt-5-nano" || lower.hasPrefix("gpt-5-nano-") { return (0.05, 0.40) }
            if lower == "gpt-4.1-nano" || lower.hasPrefix("gpt-4.1-nano-") { return (0.10, 0.40) }
        }
        if provider == ProviderKind.anthropic.rawValue,
           lower == "claude-haiku-4-5" || lower.hasPrefix("claude-haiku-4-5-") {
            return (1.00, 5.00)
        }
        return nil
    }

    static func costUSD(inputTokens: Int, outputTokens: Int,
                        provider: String, model: String) -> Double? {
        guard let rates = rates(provider: provider, model: model) else { return nil }
        return (Double(inputTokens) * rates.input + Double(outputTokens) * rates.output) / 1_000_000
    }
}

/// Small daily aggregates keep monthly usage accurate even though detailed
/// operation history is intentionally limited to 50 records. No text, prompts,
/// responses, field labels, or clipboard data are stored.
@MainActor
final class UsageLedgerStore: ObservableObject {
    static let retentionDays = 120

    @Published private(set) var buckets: [DailyUsageBucket]
    private let defaults: UserDefaults
    private let storageKey: String
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard, storageKey: String = "usageLedgerV1",
         calendar: Calendar = .current) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.calendar = calendar
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([DailyUsageBucket].self, from: data) {
            self.buckets = decoded
        } else {
            self.buckets = []
        }
        prune(now: Date())
    }

    func record(_ usage: LLMUsage, source: OperationSource,
                provider: String, model: String, at date: Date = Date()) {
        // The Chrome native host is a separate process using the same defaults.
        // Merge its latest buckets before every write so neither process can
        // silently overwrite the other's usage.
        refresh()
        let day = calendar.startOfDay(for: date)
        if let index = buckets.firstIndex(where: {
            calendar.isDate($0.day, inSameDayAs: day)
                && $0.source == source && $0.provider == provider && $0.model == model
        }) {
            buckets[index].inputTokens += usage.inputTokens
            buckets[index].outputTokens += usage.outputTokens
            buckets[index].operationCount += 1
            if usage.isEstimated { buckets[index].estimatedOperationCount += 1 }
        } else {
            buckets.append(DailyUsageBucket(
                day: day, source: source, provider: provider, model: model,
                inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                operationCount: 1, estimatedOperationCount: usage.isEstimated ? 1 : 0
            ))
        }
        prune(now: date)
        persist()
    }

    func summary(days: Int, source: OperationSource? = nil,
                 now: Date = Date()) -> UsageSummary {
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1),
                                  to: calendar.startOfDay(for: now)) ?? now
        let selected = buckets.filter {
            $0.day >= start && $0.day <= now && (source == nil || $0.source == source)
        }
        var cost = 0.0
        var unpriced = 0
        for bucket in selected {
            if let bucketCost = UsageCostEstimator.costUSD(
                inputTokens: bucket.inputTokens, outputTokens: bucket.outputTokens,
                provider: bucket.provider, model: bucket.model) {
                cost += bucketCost
            } else {
                unpriced += bucket.operationCount
            }
        }
        return UsageSummary(
            inputTokens: selected.reduce(0) { $0 + $1.inputTokens },
            outputTokens: selected.reduce(0) { $0 + $1.outputTokens },
            operationCount: selected.reduce(0) { $0 + $1.operationCount },
            automaticOperationCount: selected.filter { $0.source.isAutomaticProviderPath }
                .reduce(0) { $0 + $1.operationCount },
            estimatedOperationCount: selected.reduce(0) { $0 + $1.estimatedOperationCount },
            estimatedCostUSD: cost,
            unpricedOperationCount: unpriced
        )
    }

    func automaticCallsToday(now: Date = Date()) -> Int {
        buckets.filter {
            calendar.isDate($0.day, inSameDayAs: now) && $0.source.isAutomaticProviderPath
        }.reduce(0) { $0 + $1.operationCount }
    }

    func allowsAutomaticCall(dailyLimit: Int, now: Date = Date()) -> Bool {
        automaticCallsToday(now: now) < max(1, dailyLimit)
    }

    func clear() {
        buckets = []
        defaults.removeObject(forKey: storageKey)
        defaults.synchronize()
    }

    func refresh() {
        defaults.synchronize()
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DailyUsageBucket].self, from: data),
              decoded != buckets else { return }
        buckets = decoded
        prune(now: Date())
    }

    private func prune(now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays,
                                         to: calendar.startOfDay(for: now)) else { return }
        buckets.removeAll { $0.day < cutoff }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(buckets) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
    }
}
