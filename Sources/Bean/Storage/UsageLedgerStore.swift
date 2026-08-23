import Foundation

/// Usage values are persisted counters and may be read from an older or
/// externally modified preferences domain. Saturating at the display/accounting
/// boundary keeps one extreme but valid counter from trapping the process.
private func saturatingNonnegativeUsageAdd(_ left: Int, _ right: Int) -> Int {
    let addition = max(0, left).addingReportingOverflow(max(0, right))
    return addition.overflow ? Int.max : addition.partialValue
}

private func saturatingUsageCostAdd(_ left: Double, _ right: Double) -> Double {
    guard left.isFinite, right.isFinite, left >= 0, right >= 0 else {
        return Double.greatestFiniteMagnitude
    }
    let total = left + right
    return total.isFinite ? total : Double.greatestFiniteMagnitude
}

struct DailyUsageBucket: Codable, Equatable, Identifiable {
    let day: Date
    let source: OperationSource
    let provider: String
    let model: String
    var inputTokens: Int
    var outputTokens: Int
    var operationCount: Int
    var estimatedOperationCount: Int

    private enum CodingKeys: String, CodingKey {
        case day, source, provider, model, inputTokens, outputTokens
        case operationCount, estimatedOperationCount
    }

    init(day: Date, source: OperationSource, provider: String, model: String,
         inputTokens: Int, outputTokens: Int, operationCount: Int,
         estimatedOperationCount: Int) {
        self.day = day
        self.source = source
        self.provider = OperationalMetadataSanitizer.required(
            provider,
            maximumScalars: OperationalMetadataSanitizer.providerMaximumScalars
        )
        self.model = OperationalMetadataSanitizer.required(
            model,
            maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars
        )
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.operationCount = operationCount
        self.estimatedOperationCount = estimatedOperationCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            day: try container.decode(Date.self, forKey: .day),
            source: try container.decode(OperationSource.self, forKey: .source),
            provider: try container.decode(String.self, forKey: .provider),
            model: try container.decode(String.self, forKey: .model),
            inputTokens: try container.decode(Int.self, forKey: .inputTokens),
            outputTokens: try container.decode(Int.self, forKey: .outputTokens),
            operationCount: try container.decode(Int.self, forKey: .operationCount),
            estimatedOperationCount: try container.decode(
                Int.self, forKey: .estimatedOperationCount
            )
        )
    }

    var id: String {
        "\(day.timeIntervalSince1970)|\(source.rawValue)|\(provider)|\(model)"
    }

    var persistenceSanitized: DailyUsageBucket {
        DailyUsageBucket(
            day: day, source: source, provider: provider, model: model,
            inputTokens: inputTokens, outputTokens: outputTokens,
            operationCount: operationCount,
            estimatedOperationCount: estimatedOperationCount
        )
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

    var totalTokens: Int {
        saturatingNonnegativeUsageAdd(inputTokens, outputTokens)
    }
    var averageTokensPerOperation: Int {
        operationCount > 0 ? totalTokens / operationCount : 0
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
        guard inputTokens >= 0, outputTokens >= 0,
              let rates = rates(provider: provider, model: model) else { return nil }
        let inputCost = Double(inputTokens) * rates.input
        let outputCost = Double(outputTokens) * rates.output
        let cost = saturatingUsageCostAdd(inputCost, outputCost) / 1_000_000
        return cost.isFinite ? cost : Double.greatestFiniteMagnitude
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
    private let crossProcessLock: BeanCrossProcessStoreLock

    init(defaults: UserDefaults = .standard, storageKey: String = "usageLedgerV1",
         calendar: Calendar = .current,
         coordinationDirectoryURL: URL = BeanCrossProcessStoreLock.defaultDirectoryURL) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.calendar = calendar
        let lock = BeanCrossProcessStoreLock(directoryURL: coordinationDirectoryURL)
        self.crossProcessLock = lock

        let now = Date()
        var loaded: [DailyUsageBucket] = []
        var enteredLock = false
        _ = lock.withExclusiveLock {
            enteredLock = true
            loaded = Self.loadBuckets(
                defaults: defaults,
                storageKey: storageKey,
                calendar: calendar,
                now: now,
                persistSanitizedForm: true
            ) ?? []
            return true
        }
        if !enteredLock {
            // Do not migrate or prune a stale snapshot unless the same lock used
            // by the native host is held. A read-only copy is still useful in UI.
            loaded = Self.loadBuckets(
                defaults: defaults,
                storageKey: storageKey,
                calendar: calendar,
                now: now,
                persistSanitizedForm: false
            ) ?? []
        }
        self.buckets = loaded
    }

    func record(_ usage: LLMUsage, source: OperationSource,
                provider: String, model: String, at date: Date = Date()) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        // Manual calls are intentionally not capped, but their read/modify/write
        // must share the same lock as automatic app/native-host settlements so
        // neither process can overwrite the other's content-free accounting.
        _ = crossProcessLock.withExclusiveLock {
            guard self.refreshAssumingLock(now: date) else { return false }
            let day = self.calendar.startOfDay(for: date)
            let safeProvider = OperationalMetadataSanitizer.required(
                provider,
                maximumScalars: OperationalMetadataSanitizer.providerMaximumScalars
            )
            let safeModel = OperationalMetadataSanitizer.required(
                model,
                maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars
            )
            if let index = self.buckets.firstIndex(where: {
                self.calendar.isDate($0.day, inSameDayAs: day)
                    && $0.source == source
                    && $0.provider == safeProvider
                    && $0.model == safeModel
            }) {
                self.buckets[index].inputTokens = saturatingNonnegativeUsageAdd(
                    self.buckets[index].inputTokens,
                    usage.inputTokens
                )
                self.buckets[index].outputTokens = saturatingNonnegativeUsageAdd(
                    self.buckets[index].outputTokens,
                    usage.outputTokens
                )
                self.buckets[index].operationCount = saturatingNonnegativeUsageAdd(
                    self.buckets[index].operationCount,
                    1
                )
                if usage.isEstimated {
                    self.buckets[index].estimatedOperationCount =
                        saturatingNonnegativeUsageAdd(
                            self.buckets[index].estimatedOperationCount,
                            1
                        )
                }
            } else {
                self.buckets.append(DailyUsageBucket(
                    day: day, source: source, provider: safeProvider, model: safeModel,
                    inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                    operationCount: 1, estimatedOperationCount: usage.isEstimated ? 1 : 0
                ))
            }
            self.prune(now: date)
            return self.persistAssumingLock()
        }
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
                cost = saturatingUsageCostAdd(cost, bucketCost)
            } else {
                unpriced = saturatingNonnegativeUsageAdd(
                    unpriced,
                    bucket.operationCount
                )
            }
        }
        return UsageSummary(
            inputTokens: selected.reduce(0) {
                saturatingNonnegativeUsageAdd($0, $1.inputTokens)
            },
            outputTokens: selected.reduce(0) {
                saturatingNonnegativeUsageAdd($0, $1.outputTokens)
            },
            operationCount: selected.reduce(0) {
                saturatingNonnegativeUsageAdd($0, $1.operationCount)
            },
            automaticOperationCount: selected.filter { $0.source.isAutomaticProviderPath }
                .reduce(0) { saturatingNonnegativeUsageAdd($0, $1.operationCount) },
            estimatedOperationCount: selected.reduce(0) {
                saturatingNonnegativeUsageAdd($0, $1.estimatedOperationCount)
            },
            estimatedCostUSD: cost,
            unpricedOperationCount: unpriced
        )
    }

    func automaticCallsToday(now: Date = Date()) -> Int {
        buckets.filter {
            calendar.isDate($0.day, inSameDayAs: now) && $0.source.isAutomaticProviderPath
        }.reduce(0) { saturatingNonnegativeUsageAdd($0, $1.operationCount) }
    }

    func allowsAutomaticCall(dailyLimit: Int, now: Date = Date()) -> Bool {
        automaticCallsToday(now: now) < max(1, dailyLimit)
    }

    func clear() {
        _ = crossProcessLock.withExclusiveLock {
            self.buckets = []
            self.defaults.removeObject(forKey: self.storageKey)
            self.defaults.synchronize()
            return true
        }
    }

    func refresh() {
        let now = Date()
        var enteredLock = false
        _ = crossProcessLock.withExclusiveLock {
            enteredLock = true
            return self.refreshAssumingLock(now: now)
        }
        if !enteredLock, let decoded = Self.loadBuckets(
            defaults: defaults,
            storageKey: storageKey,
            calendar: calendar,
            now: now,
            persistSanitizedForm: false
        ), decoded != buckets {
            buckets = decoded
        }
    }

    private func prune(now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays,
                                         to: calendar.startOfDay(for: now)) else { return }
        buckets.removeAll { $0.day < cutoff }
    }

    private func refreshAssumingLock(now: Date) -> Bool {
        guard let decoded = Self.loadBuckets(
            defaults: defaults,
            storageKey: storageKey,
            calendar: calendar,
            now: now,
            persistSanitizedForm: true
        ) else { return false }
        if decoded != buckets { buckets = decoded }
        return true
    }

    private static func loadBuckets(
        defaults: UserDefaults,
        storageKey: String,
        calendar: Calendar,
        now: Date,
        persistSanitizedForm: Bool
    ) -> [DailyUsageBucket]? {
        defaults.synchronize()
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode([DailyUsageBucket].self, from: data),
              decoded.allSatisfy({
                  $0.day.timeIntervalSinceReferenceDate.isFinite
                      && $0.inputTokens >= 0 && $0.outputTokens >= 0
                      && $0.operationCount >= 0 && $0.estimatedOperationCount >= 0
                      && $0.estimatedOperationCount <= $0.operationCount
              }) else { return nil }

        var sanitized = decoded.map(\.persistenceSanitized)
        if let cutoff = calendar.date(
            byAdding: .day,
            value: -Self.retentionDays,
            to: calendar.startOfDay(for: now)
        ) {
            sanitized.removeAll { $0.day < cutoff }
        }
        if persistSanitizedForm,
           let encoded = try? JSONEncoder().encode(sanitized),
           encoded != data {
            defaults.set(encoded, forKey: storageKey)
            defaults.synchronize()
        }
        return sanitized
    }

    /// Call only while `crossProcessLock` is held.
    private func persistAssumingLock() -> Bool {
        guard let data = try? JSONEncoder().encode(buckets) else { return false }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
        return true
    }
}
