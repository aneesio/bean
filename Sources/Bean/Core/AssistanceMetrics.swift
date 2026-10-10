import Foundation
import Combine

enum AssistanceMetricKind: String, Codable, CaseIterable {
    case nativeAnalysis, typingPauseToFeedback, nativeAcceptance, providerAction
    case browserAnalysis, browserAcceptance
}

struct AssistanceMetricSample: Codable, Equatable {
    let kind: AssistanceMetricKind
    let inputLength: Int
    let issueCount: Int
    let elapsedMilliseconds: Int
    let cached: Bool
    let outcome: String
}

/// Local, bounded timing evidence. No writing, app identity, field labels,
/// prompts or clipboard data are collected. Samples disappear on quit.
@MainActor
final class AssistanceMetrics: ObservableObject {
    static let shared = AssistanceMetrics()
    static let maximumSamples = 500
    private static let outcomes: Set<String> = [
        "shown", "noIssues", "cannotReadText", "cannotLocateRanges", "unsupportedField",
        "textTooLong", "staleDiscarded", "cancelled", "failed", "replacedConfirmed",
        "replacementSentUnconfirmed", "noChangesNeeded", "providerFailed", "unknown"
    ]
    @Published private(set) var samples: [AssistanceMetricSample] = []

    func recordNativeAnalysis(inputLength: Int, issueCount: Int,
                              elapsedMilliseconds: Int, cached: Bool, outcome: String) {
        append(kind: .nativeAnalysis, inputLength: inputLength, issueCount: issueCount,
               elapsedMilliseconds: elapsedMilliseconds, cached: cached, outcome: outcome)
    }

    func record(kind: AssistanceMetricKind, inputLength: Int = 0, issueCount: Int = 0,
                elapsedMilliseconds: Int, outcome: String) {
        append(kind: kind, inputLength: inputLength, issueCount: issueCount,
               elapsedMilliseconds: elapsedMilliseconds, cached: false, outcome: outcome)
    }

    private func append(kind: AssistanceMetricKind, inputLength: Int, issueCount: Int,
                        elapsedMilliseconds: Int, cached: Bool, outcome: String) {
        let sample = AssistanceMetricSample(kind: kind, inputLength: min(max(inputLength, 0), 200_000),
            issueCount: min(max(issueCount, 0), 1_000),
            elapsedMilliseconds: min(max(elapsedMilliseconds, 0), 600_000), cached: cached,
            outcome: Self.outcomes.contains(outcome) ? outcome : "unknown")
        if samples.count >= Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples + 1) }
        samples.append(sample)
    }

    func clear() { samples.removeAll() }

    static func percentile(_ durations: [Int], fraction: Double) -> Int? {
        guard !durations.isEmpty, fraction.isFinite else { return nil }
        let sorted = durations.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * min(max(fraction, 0), 1))) - 1))
        return sorted[index]
    }

    var summary: String {
        var lines = ["Bean local performance summary", "Samples are in memory only; no writing or app identities."]
        for kind in AssistanceMetricKind.allCases {
            let measured = samples.filter { $0.kind == kind && !$0.cached }
            guard !measured.isEmpty else { continue }
            let times = measured.map(\.elapsedMilliseconds)
            lines.append("\(kind.rawValue): n=\(times.count), p50=\(Self.percentile(times, fraction: 0.5) ?? 0)ms, p95=\(Self.percentile(times, fraction: 0.95) ?? 0)ms")
            let outcomes = Dictionary(grouping: measured, by: \.outcome).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
            lines.append("  \(outcomes)")
        }
        if samples.isEmpty { lines.append("No measurements yet. Use Bean in an editable field to collect a baseline.") }
        return lines.joined(separator: "\n")
    }
}
