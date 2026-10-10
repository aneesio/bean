import CryptoKit
import Foundation
import XCTest
@testable import Bean

/// A reviewable, opt-in external-evaluation harness. Normal CI skips it before
/// reading an API key. Dry runs never construct a provider or touch accounting.
@MainActor
final class ProviderQualityEvaluationTests: XCTestCase {
    func testExternalProviderEvaluationOnlyWhenExplicitlyRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["BEAN_PROVIDER_EVALUATION_MODE"] else {
            throw XCTSkip("Use scripts/run_provider_quality_evaluation.sh for an offline plan or explicitly budgeted paid evaluation.")
        }
        let config = try ProviderEvaluationConfiguration(environment: environment)
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WritingQuality/corpus-v1.jsonl")
        let rawFixture = try Data(contentsOf: fixtureURL)
        let hash = SHA256.hash(data: rawFixture).map { String(format: "%02x", $0) }.joined()
        guard hash == ProviderEvaluationConfiguration.corpusHash else { throw ProviderEvaluationError.invalidConfiguration }
        let samples = try String(decoding: rawFixture, as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(ProviderEvaluationSample.self, from: Data($0.utf8))
        }
        let selected = ProviderEvaluationSample.representativeFamilies(samples, maximum: config.maximumCases)
        let directory = URL(fileURLWithPath: config.outputDirectory, isDirectory: true)
        // A new run never overwrites a human's ratings or earlier provider run.
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ProviderEvaluationError.outputAlreadyExists }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var metadata: [String: Any] = [
            "schemaVersion": 1, "mode": mode, "corpusSHA256": hash,
            "provider": config.provider?.rawValue ?? "not selected", "model": config.model,
            "configurationSource": config.usesVerifiedBeanProvider ? "verifiedBeanSettings" : "explicitEnvironmentOrDryRun",
            "blindRunLabel": "candidate-\(UUID().uuidString.prefix(8))",
            "pricingReference": config.pricingReference,
            "inputUSDPerMillion": config.inputRate, "outputUSDPerMillion": config.outputRate,
            "maximumEstimatedUSD": config.maximumEstimatedUSD,
            "maximumRequests": config.maximumRequests, "maximumCases": config.maximumCases,
            "provenance": "Frozen agent-curated synthetic corpus; labels require independent human review",
            "limits": "Configured-price estimate, not a billing guarantee. Framing allowance 2048 input tokens; failures retain reserved estimate. Synthetic exact-match scores do not certify meaning or linguistic quality."
        ]
        var blindRecords: [[String: Any]] = []
        var budget = ProviderEvaluationBudget(maximumRequests: config.maximumRequests,
            maximumEstimatedUSD: config.maximumEstimatedUSD, inputRate: config.inputRate, outputRate: config.outputRate)
        var stopReason = "completedSelectedCases"
        var providerAttempts = 0
        var failedAttempts = 0
        var inputTokens = 0, outputTokens = 0, estimatedUsageRequests = 0, successfulRequests = 0
        var providerCostEstimate = 0.0
        // Paid accounting is isolated: no live app defaults/key/history/data.
        let accountingSuite = "bean.provider-evaluation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: accountingSuite)!
        defer { defaults.removePersistentDomain(forName: accountingSuite) }
        let accountingDirectory = directory.appendingPathComponent("accounting", isDirectory: true)
        let accounting = config.isPaid ? AutomaticCallBudgetStore(defaults: defaults, directoryURL: accountingDirectory) : nil
        let ledger = config.isPaid ? UsageLedgerStore(defaults: defaults, coordinationDirectoryURL: accountingDirectory) : nil
        evaluation: for sample in selected {
            for task in ["detect", "proofread", "makeClearer"] {
                let request = sample.request(task: task, config: config)
                guard EngineConfig.providerRequestInputIsWithinLimit(systemPrompt: request.systemPrompt, userText: request.userText) else {
                    throw ProviderEvaluationError.invalidConfiguration
                }
                var record: [String: Any] = ["caseId": sample.id, "family": sample.family, "split": sample.split,
                    "domain": sample.domain, "dialect": sample.dialect, "task": task,
                    "sourceText": sample.text, "annotatedMechanicalTarget": sample.expectedText,
                    "humanRatings": ["correctionCorrectness": NSNull(), "falseAlarm": NSNull(),
                        "unnecessaryEdits": NSNull(), "meaningPreserved": NSNull(), "dialectPreserved": NSNull(),
                        "notes": NSNull()], "reviewRequired": true]
                if !config.isPaid {
                    record["mode"] = "dry-run"
                    record["requestSystemPrompt"] = request.systemPrompt
                    record["requestUserPayload"] = request.userText
                    record["maximumOutputTokens"] = request.maxOutputTokens
                    record["estimatedInputTokenEnvelope"] = request.systemPrompt.utf8.count + request.userText.utf8.count + 2_048
                    blindRecords.append(record)
                    continue
                }
                guard config.verifiedConfigurationStillMatches() else {
                    stopReason = "verifiedBeanConfigurationChanged"
                    break evaluation
                }
                guard budget.reserve(systemBytes: request.systemPrompt.utf8.count,
                    userBytes: request.userText.utf8.count, maximumOutputTokens: request.maxOutputTokens) else {
                    stopReason = "configuredBudgetReached"
                    break evaluation
                }
                let metadataForCall = AutomaticCallMetadata(source: .manual, appName: nil, appBundleIdentifier: nil,
                    appCategory: "unknown", action: task, inputMode: "syntheticEvaluation", inputLength: sample.text.count,
                    provider: config.provider!.rawValue, model: config.model)
                guard let accounting, case let .reserved(reservation) = accounting.reserveManual(
                    leaseDuration: 60, metadata: metadataForCall) else {
                    stopReason = "accountingUnavailable"
                    break evaluation
                }
                defer { reservation.cancel() }
                guard config.verifiedConfigurationStillMatches() else {
                    stopReason = "verifiedBeanConfigurationChanged"
                    break evaluation
                }
                guard reservation.beginProviderAttempt() else {
                    stopReason = "accountingUnavailable"
                    break evaluation
                }
                providerAttempts += 1
                let started = ContinuousClock.now
                do {
                    let completion = try await LLMProviderFactory.make(config.provider!).complete(request)
                    let elapsed = started.duration(to: .now)
                    record["latencyMilliseconds"] = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                    successfulRequests += 1
                    let inputSum = inputTokens.addingReportingOverflow(completion.usage.inputTokens)
                    let outputSum = outputTokens.addingReportingOverflow(completion.usage.outputTokens)
                    inputTokens = inputSum.overflow ? Int.max : inputSum.partialValue
                    outputTokens = outputSum.overflow ? Int.max : outputSum.partialValue
                    if completion.usage.isEstimated { estimatedUsageRequests += 1 }
                    providerCostEstimate += budget.cost(inputTokens: completion.usage.inputTokens, outputTokens: completion.usage.outputTokens)
                    record["providerRawOutput"] = String(completion.text.prefix(40_000))
                    record["providerRawOutputTruncated"] = completion.text.count > 40_000
                    record["usage"] = ["inputTokens": completion.usage.inputTokens, "outputTokens": completion.usage.outputTokens,
                                       "isEstimated": completion.usage.isEstimated]
                    var safety = "ok"
                    if task == "detect" {
                        var detector = IssueDetector(); detector.maxIssues = 8
                        let findings = detector.issues(fromModelOutput: completion.text, in: sample.text,
                            dictionary: sample.dictionary.map { DictionaryTerm(term: $0) })
                        record["mappedIssues"] = findings.map { ["original": $0.original, "suggestion": $0.suggestion,
                            "start": $0.range.location, "end": NSMaxRange($0.range), "type": $0.type.rawValue] as [String: Any] }
                        record["annotatedMappingScore"] = sample.mappingScore(findings)
                        safety = findings.isEmpty && !sample.issues.isEmpty ? "noMappedCandidates" : "mappedCandidatesRequireLanguageReview"
                    } else {
                        let action: WritingAction = task == "proofread" ? .proofread : .makeClearer
                        let output = NativeMessagingHost.sanitizedBrowserTransformation(completion.text, original: sample.text)
                        record["sanitizedOutput"] = output
                        if task == "proofread" { record["matchesMechanicalAnnotationExactly"] = output == sample.expectedText }
                        else { record["matchesMechanicalAnnotationExactly"] = NSNull() }
                        if case let .suspicious(reason) = OutputSafetyValidator.validate(input: sample.text, output: output,
                            action: action, protectedTerms: sample.dictionary) { safety = reason }
                        record["safetyResult"] = safety
                        record["wouldApplyAutomatically"] = safety == "ok"
                    }
                    let settled = reservation.complete(usage: completion.usage, outputLength: completion.text.count,
                        safetyResult: safety, outcome: "externalEvaluation")
                    record["accountingSettled"] = settled
                    blindRecords.append(record)
                    if !settled { stopReason = "accountingSettlementFailed"; break evaluation }
                    let inputEnvelope = request.systemPrompt.utf8.count + request.userText.utf8.count + 2_048
                    if completion.usage.inputTokens > inputEnvelope || completion.usage.outputTokens > request.maxOutputTokens {
                        stopReason = "providerUsageExceededConfiguredEnvelope"
                        break evaluation
                    }
                } catch {
                    // Failures can incur tokens even when no usage is returned.
                    // Keep their entire preflight estimate reserved; never retry.
                    failedAttempts += 1
                    let settled = reservation.fail(outcome: automaticProviderFailureOutcome(error))
                    record["accountingSettled"] = settled
                    record["failureOutcome"] = automaticProviderFailureOutcome(error)
                    record["usageUnavailable"] = true
                    blindRecords.append(record)
                    if !settled { stopReason = "accountingSettlementFailed"; break evaluation }
                    if failedAttempts >= 2 { stopReason = "twoProviderFailures"; break evaluation }
                }
            }
        }
        ledger?.refresh()
        let recorded = ledger?.summary(days: 1)
        metadata["attemptedRequests"] = providerAttempts
        metadata["reservedBudgetRequests"] = budget.attempts
        metadata["successfulRequests"] = successfulRequests
        metadata["failedRequests"] = failedAttempts
        metadata["inputTokens"] = inputTokens; metadata["outputTokens"] = outputTokens
        metadata["estimatedUsageRequests"] = estimatedUsageRequests
        metadata["conservativeReservedEstimateUSD"] = budget.reservedEstimateUSD
        metadata["observedUsageEstimateUSD"] = providerCostEstimate
        metadata["usageForFailedRequestsIsUnknown"] = failedAttempts > 0
        metadata["settledUsageOperations"] = recorded?.operationCount ?? 0
        metadata["stopReason"] = stopReason
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("run-metadata.json"), options: .atomic)
        let lines = try blindRecords.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try lines.write(to: directory.appendingPathComponent("blind-review.jsonl"), atomically: true, encoding: .utf8)
        print("BEAN_PROVIDER_EVALUATION mode=\(mode) cases=\(selected.count) attempts=\(budget.attempts) stop=\(stopReason)")
        XCTAssertEqual(recorded?.operationCount ?? 0, successfulRequests)
    }
}

private enum ProviderEvaluationError: Error { case invalidConfiguration, outputAlreadyExists, accountingFailed }

private struct ProviderEvaluationConfiguration {
    static let corpusHash = "b7c518c742d844794cbef69ba740e30afae8588997d3b01fbb2dff9957a647c2"
    let isPaid: Bool
    let usesVerifiedBeanProvider: Bool
    let provider: ProviderKind?
    let model: String
    let apiKey: String
    let outputDirectory: String
    let maximumCases: Int
    let maximumRequests: Int
    let maximumEstimatedUSD: Double
    let inputRate: Double
    let outputRate: Double
    let pricingReference: String

    init(environment: [String: String]) throws {
        let mode = environment["BEAN_PROVIDER_EVALUATION_MODE"] ?? ""
        guard ["dry-run", "paid"].contains(mode),
              let output = environment["BEAN_EVAL_OUTPUT_DIRECTORY"], !output.isEmpty else { throw ProviderEvaluationError.invalidConfiguration }
        isPaid = mode == "paid"; outputDirectory = output
        maximumCases = Int(environment["BEAN_EVAL_MAX_CASES"] ?? "12") ?? 0
        maximumRequests = Int(environment["BEAN_EVAL_MAX_REQUESTS"] ?? "0") ?? 0
        maximumEstimatedUSD = Double(environment["BEAN_EVAL_MAX_ESTIMATED_USD"] ?? "0") ?? .nan
        inputRate = Double(environment["BEAN_EVAL_INPUT_USD_PER_MILLION"] ?? "0") ?? .nan
        outputRate = Double(environment["BEAN_EVAL_OUTPUT_USD_PER_MILLION"] ?? "0") ?? .nan
        pricingReference = environment["BEAN_EVAL_PRICING_REFERENCE"] ?? "not supplied"
        guard maximumCases > 0, maximumCases <= 100,
              inputRate.isFinite, inputRate >= 0, outputRate.isFinite, outputRate >= 0,
              maximumEstimatedUSD.isFinite, maximumEstimatedUSD >= 0 else { throw ProviderEvaluationError.invalidConfiguration }
        if isPaid {
            guard environment["BEAN_EVAL_ALLOW_PAID"] == "YES",
                  maximumRequests > 0, maximumRequests <= 40,
                  maximumEstimatedUSD > 0, maximumEstimatedUSD <= 5,
                  inputRate + outputRate > 0, pricingReference != "not supplied", pricingReference.count <= 512 else {
                throw ProviderEvaluationError.invalidConfiguration
            }
            usesVerifiedBeanProvider = environment["BEAN_EVAL_USE_VERIFIED_BEAN_PROVIDER"] == "YES"
            if usesVerifiedBeanProvider {
                // Selected settings are content-free. Keychain access occurs
                // only after explicit paid authorization and every budget/rate
                // bound above succeeds, and only for a verified exact pair.
                let defaults = UserDefaults.standard
                let selected = ProviderKind(rawValue: defaults.string(forKey: "provider") ?? "") ?? .openai
                let selectedModel = selected.migratedModel(defaults.string(forKey: "model"))
                guard NativeProviderVerificationPolicy.isVerified(capturedProvider: selected,
                    capturedModel: selectedModel, defaults: defaults),
                    case let .value(key) = KeychainService.get(account: selected.keychainAccount), !key.isEmpty else {
                    throw ProviderEvaluationError.invalidConfiguration
                }
                provider = selected; model = selectedModel; apiKey = key
            } else {
                provider = ProviderKind(rawValue: environment["BEAN_EVAL_PROVIDER"] ?? "")
                model = environment["BEAN_EVAL_MODEL"] ?? "not selected"
                apiKey = environment["BEAN_EVAL_API_KEY"] ?? ""
                guard provider != nil, model != "not selected", !model.isEmpty, model.count <= 100,
                      !apiKey.isEmpty else { throw ProviderEvaluationError.invalidConfiguration }
            }
        } else {
            usesVerifiedBeanProvider = false
            provider = ProviderKind(rawValue: environment["BEAN_EVAL_PROVIDER"] ?? "")
            model = environment["BEAN_EVAL_MODEL"] ?? "not selected"
            apiKey = ""
        }
    }

    func verifiedConfigurationStillMatches() -> Bool {
        !usesVerifiedBeanProvider || NativeProviderVerificationPolicy.isVerified(
            capturedProvider: provider!, capturedModel: model, defaults: .standard)
    }
}

private struct ProviderEvaluationBudget {
    let maximumRequests: Int
    let maximumEstimatedUSD: Double
    let inputRate: Double
    let outputRate: Double
    private(set) var attempts = 0
    private(set) var reservedEstimateUSD = 0.0

    func cost(inputTokens: Int, outputTokens: Int) -> Double {
        (Double(inputTokens) * inputRate + Double(outputTokens) * outputRate) / 1_000_000
    }
    mutating func reserve(systemBytes: Int, userBytes: Int, maximumOutputTokens: Int) -> Bool {
        guard systemBytes >= 0, userBytes >= 0, maximumOutputTokens > 0, attempts < maximumRequests else { return false }
        let upper = cost(inputTokens: systemBytes + userBytes + 2_048, outputTokens: maximumOutputTokens)
        guard upper.isFinite, upper >= 0, reservedEstimateUSD + upper <= maximumEstimatedUSD else { return false }
        attempts += 1; reservedEstimateUSD += upper
        return true
    }
}

private struct ProviderEvaluationSample: Decodable {
    struct Annotation: Decodable { let location: Int; let length: Int; let corrections: [String] }
    let id: String; let family: String; let split: String; let domain: String; let dialect: String
    let text: String; let expectedText: String; let dictionary: [String]; let issues: [Annotation]

    static func representativeFamilies(_ samples: [Self], maximum: Int) -> [Self] {
        let grouped = Dictionary(grouping: samples, by: \.family)
        // Round-robin clean, spelling, grammar and surface families so a small
        // run does not accidentally consist only of the first clean controls.
        var buckets: [String: [[Self]]] = [:]
        for family in grouped.keys.sorted() {
            let variants = grouped[family]!.sorted { $0.id < $1.id }
            let kind = family.components(separatedBy: "-").dropFirst().first ?? "unknown"
            buckets[kind, default: []].append(variants)
        }
        var result: [Self] = []
        while result.count < maximum {
            var added = false
            for kind in buckets.keys.sorted() where result.count < maximum {
                guard !buckets[kind]!.isEmpty else { continue }
                let variants = buckets[kind]!.removeFirst()
                result.append(variants[result.count % variants.count]); added = true
            }
            if !added { break }
        }
        return result
    }

    func request(task: String, config: ProviderEvaluationConfiguration) -> LLMRequest {
        let bundle = domain == "email" ? "com.apple.mail" : domain == "chat" ? "com.tinyspeck.slackmacgap" : "com.apple.Notes"
        let context = SourceAppContext(appName: "Synthetic fixture", bundleIdentifier: bundle,
            processIdentifier: nil, focusedRole: "AXTextArea", focusedSubrole: nil,
            acquisitionMode: .focusedFieldFullText, isSearchLikeField: false)
        let dialect = WritingDialect(rawValue: dialect) ?? .automatic
        let action: WritingAction = task == "proofread" ? .proofread : .makeClearer
        let lines = NativeMessagingHost.dictionaryPreservationLines(for: text, dictionary: dictionary.map { DictionaryTerm(term: $0) })
            + (dialect.promptInstruction.map { [$0] } ?? [])
        return LLMRequest(systemPrompt: task == "detect" ? IssueDetector.systemPrompt : WritingTransformService.systemPrompt(for: action),
            userText: task == "detect" ? IssueDetector.userMessage(text: text, context: context,
                dictionary: dictionary.map { DictionaryTerm(term: $0) }, maximumIssues: 8, dialect: dialect)
                : WritingTransformService.userMessage(text: text, action: action, context: context, userContextLines: lines),
            model: config.model, apiKey: config.apiKey, timeout: 15,
            maxOutputTokens: task == "detect" ? IssueDetector.outputTokenBudget(maximumIssues: 8)
                : WritingTransformService.outputTokenBudget(for: text, action: action))
    }

    func mappingScore(_ findings: [TextIssue]) -> [String: Any] {
        var matched = Set<Int>(), correct = 0, falsePositives = 0
        for finding in findings {
            guard let index = issues.indices.first(where: { !matched.contains($0)
                && finding.range.location == issues[$0].location && finding.range.length == issues[$0].length }) else {
                falsePositives += 1; continue
            }
            matched.insert(index)
            if issues[index].corrections.contains(finding.suggestion) { correct += 1 }
        }
        return ["truePositives": matched.count, "falsePositives": falsePositives,
                "falseNegatives": issues.count - matched.count, "correctPreferredSuggestions": correct,
                "limitation": "Exact annotation alignment only; blind human review is required."]
    }
}

final class ProviderEvaluationPolicyTests: XCTestCase {
    func testDryRunHasNoAPIKeyEvenIfAnEnvironmentKeyExists() throws {
        let config = try ProviderEvaluationConfiguration(environment: ["BEAN_PROVIDER_EVALUATION_MODE": "dry-run",
            "BEAN_EVAL_OUTPUT_DIRECTORY": "/private/tmp/eval-preview", "BEAN_EVAL_API_KEY": "synthetic-secret",
            "BEAN_EVAL_USE_VERIFIED_BEAN_PROVIDER": "YES"])
        XCTAssertFalse(config.isPaid); XCTAssertEqual(config.apiKey, "")
        XCTAssertFalse(config.usesVerifiedBeanProvider)
    }
    func testPaidModeRequiresExplicitApprovalProviderAndBudget() {
        for values: [String: String] in [[:], ["BEAN_EVAL_ALLOW_PAID": "YES"]] {
            var environment = values
            environment["BEAN_PROVIDER_EVALUATION_MODE"] = "paid"
            environment["BEAN_EVAL_OUTPUT_DIRECTORY"] = "/private/tmp/eval-preview"
            XCTAssertThrowsError(try ProviderEvaluationConfiguration(environment: environment))
        }
    }
    func testPaidEnvironmentPolicyAcceptsOnlyFiniteBoundedRatesAndRequestCaps() throws {
        var valid = ["BEAN_PROVIDER_EVALUATION_MODE": "paid", "BEAN_EVAL_OUTPUT_DIRECTORY": "/private/tmp/eval-preview",
            "BEAN_EVAL_ALLOW_PAID": "YES", "BEAN_EVAL_PROVIDER": "openai", "BEAN_EVAL_MODEL": "synthetic-test-model",
            "BEAN_EVAL_API_KEY": "synthetic-secret", "BEAN_EVAL_MAX_REQUESTS": "1", "BEAN_EVAL_MAX_ESTIMATED_USD": "0.01",
            "BEAN_EVAL_INPUT_USD_PER_MILLION": "1", "BEAN_EVAL_OUTPUT_USD_PER_MILLION": "2",
            "BEAN_EVAL_PRICING_REFERENCE": "Synthetic policy test values; never used for billing"]
        XCTAssertTrue(try ProviderEvaluationConfiguration(environment: valid).isPaid)
        valid["BEAN_EVAL_MAX_REQUESTS"] = "41"
        XCTAssertThrowsError(try ProviderEvaluationConfiguration(environment: valid))
        valid["BEAN_EVAL_MAX_REQUESTS"] = "1"
        valid["BEAN_EVAL_INPUT_USD_PER_MILLION"] = "nan"
        XCTAssertThrowsError(try ProviderEvaluationConfiguration(environment: valid))
    }

    func testEstimateAndRequestEnvelopesCannotBeExceededOrRefundFailedAttempts() {
        var budget = ProviderEvaluationBudget(maximumRequests: 2, maximumEstimatedUSD: 0.01, inputRate: 1, outputRate: 2)
        XCTAssertTrue(budget.reserve(systemBytes: 100, userBytes: 100, maximumOutputTokens: 100))
        let reserved = budget.reservedEstimateUSD
        XCTAssertTrue(budget.reserve(systemBytes: 100, userBytes: 100, maximumOutputTokens: 100))
        XCTAssertGreaterThan(budget.reservedEstimateUSD, reserved)
        XCTAssertFalse(budget.reserve(systemBytes: 0, userBytes: 0, maximumOutputTokens: 1))
        var tiny = ProviderEvaluationBudget(maximumRequests: 2, maximumEstimatedUSD: 0.000001, inputRate: 1, outputRate: 2)
        XCTAssertFalse(tiny.reserve(systemBytes: 100, userBytes: 100, maximumOutputTokens: 100))
        XCTAssertEqual(tiny.attempts, 0)
    }
}
