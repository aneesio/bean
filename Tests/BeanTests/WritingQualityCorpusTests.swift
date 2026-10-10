import AppKit
import Foundation
import XCTest
@testable import Bean

/// The fixture contains synthetic text only. Normal tests never contact a
/// provider; replay scores evaluate candidate mapping, not model judgment.
@MainActor
final class WritingQualityCorpusTests: XCTestCase {
    func testCorpusAnnotationsAndFamilyHoldoutAreConsistent() throws {
        let samples = try QualityCorpus.load()
        XCTAssertEqual(samples.count, 1_024)
        XCTAssertEqual(Set(samples.map(\.id)).count, samples.count)
        XCTAssertGreaterThanOrEqual(samples.filter { $0.issues.isEmpty }.count, 300)
        var splits: [String: Set<String>] = [:]
        for sample in samples {
            splits[sample.family, default: []].insert(sample.split)
            let text = sample.text as NSString
            var corrected = sample.text
            for annotation in sample.issues.sorted(by: { $0.location > $1.location }) {
                XCTAssertGreaterThanOrEqual(annotation.location, 0, sample.id)
                XCTAssertLessThanOrEqual(annotation.location + annotation.length, text.length, sample.id)
                XCTAssertEqual(text.substring(with: annotation.range), annotation.original, sample.id)
                XCTAssertNotNil(Range(annotation.range, in: sample.text), sample.id)
                let mutable = NSMutableString(string: corrected)
                mutable.replaceCharacters(in: annotation.range, with: try XCTUnwrap(annotation.corrections.first))
                corrected = mutable as String
            }
            XCTAssertEqual(corrected, sample.expectedText, sample.id)
        }
        XCTAssertTrue(splits.values.allSatisfy { $0.count == 1 })
    }

    func testDeterministicCorpusBenchmark() throws {
        let report = try evaluate(engine: "deterministic", includeSystemChecker: false)
        try persistIfRequested(report)
        print("BEAN_QUALITY_REPORT \(try report.json())")
        // Deterministic rules should never sacrifice precision to make a broad
        // recall claim. Recall is reported for unsupported grammar as well.
        XCTAssertGreaterThanOrEqual(report.overall.precision ?? 0, 0.97)
        XCTAssertGreaterThanOrEqual(report.overall.correctionAccuracy ?? 0, 0.99)
    }

    func testMacSystemCorpusBenchmarkWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["BEAN_RUN_SYSTEM_QUALITY_BENCHMARK"] == "1" else {
            throw XCTSkip("Set BEAN_RUN_SYSTEM_QUALITY_BENCHMARK=1 to measure actual macOS spelling/grammar and OS-dependent latency.")
        }
        guard NativeMessagingHost.localSpellingIsAvailable() else {
            if ProcessInfo.processInfo.environment["BEAN_ENFORCE_QUALITY_GATES"] == "1" {
                XCTFail("Required macOS spelling service is unavailable; the quality gate cannot be certified.")
                return
            }
            throw XCTSkip("The macOS spelling service is unavailable; zero findings would not be a valid benchmark.")
        }
        let report = try evaluate(engine: "localAndMacOS", includeSystemChecker: true)
        try persistIfRequested(report)
        print("BEAN_QUALITY_REPORT \(try report.json())")
        if ProcessInfo.processInfo.environment["BEAN_ENFORCE_QUALITY_GATES"] == "1" {
            for (split, counts) in report.bySplit {
                XCTAssertGreaterThanOrEqual(counts.precision ?? 0, 0.97, split)
                XCTAssertGreaterThanOrEqual(counts.recall ?? 0, 0.85, split)
                XCTAssertGreaterThanOrEqual(counts.correctionAccuracy ?? 0, 0.99, split)
                XCTAssertGreaterThanOrEqual(counts.cleanRetention ?? 0, 0.99, split)
            }
            XCTAssertLessThanOrEqual(report.latencyMilliseconds.p95, 750)
        }
    }

    func testSyntheticProviderReplayMapsExactAnnotatedEdits() throws {
        let samples = try QualityCorpus.load()
        var detector = IssueDetector()
        detector.maxIssues = 64
        var metrics = QualityCounts()
        for sample in samples {
            let candidates: [[String: Any]] = sample.issues.map {
                let source = sample.text as NSString
                let before = String(source.substring(to: $0.location).suffix(40))
                    .components(separatedBy: .newlines).last ?? ""
                let after = String(source.substring(from: $0.location + $0.length).prefix(40))
                    .components(separatedBy: .newlines).first ?? ""
                return ["original": $0.original, "suggestion": $0.corrections[0],
                 "type": $0.type, "confidence": 0.95,
                 "contextBefore": before, "contextAfter": after,
                 // These are generated fixture positions, not blindly trusted
                 // model offsets. Runtime mapping must prove them exactly.
                 "start": $0.location, "end": $0.location + $0.length]
            }
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: candidates), as: UTF8.self)
            let findings = detector.issues(fromModelOutput: raw, in: sample.text,
                                          dictionary: sample.dictionary.map { DictionaryTerm(term: $0) })
            metrics.add(QualityCorpus.score(sample: sample, findings: findings).overall)
        }
        print("BEAN_PROVIDER_MAPPING_REPLAY \(try metrics.json())")
        XCTAssertEqual(metrics.falsePositives, 0)
        // The replay cannot establish provider accuracy; a real-model score
        // must never be fabricated from these annotations.
    }

    private func evaluate(engine: String, includeSystemChecker: Bool) throws -> QualityReport {
        let samples = try QualityCorpus.load()
        var report = QualityReport(engine: engine, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString)
        var detector = IssueDetector()
        detector.maxIssues = 64
        for sample in samples {
            let started = ContinuousClock.now
            let findings = detector.localIssues(in: sample.text,
                dictionary: sample.dictionary.map { DictionaryTerm(term: $0) },
                includeSpellChecker: includeSystemChecker,
                dialect: WritingDialect(rawValue: sample.dialect) ?? .automatic)
            let elapsed = started.duration(to: .now)
            let milliseconds = Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15
            report.record(sample: sample, findings: findings, latency: milliseconds)
        }
        return report
    }

    private func persistIfRequested(_ report: QualityReport) throws {
        guard let directory = ProcessInfo.processInfo.environment["BEAN_QUALITY_REPORT_DIRECTORY"] else { return }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try report.json().write(to: destination.appendingPathComponent("\(report.engine).json"), atomically: true, encoding: .utf8)
    }
}

private struct QualitySample: Decodable {
    struct Annotation: Decodable {
        let location: Int
        let length: Int
        let original: String
        let corrections: [String]
        let type: String
        var range: NSRange { NSRange(location: location, length: length) }
    }
    let id: String
    let family: String
    let split: String
    let domain: String
    let dialect: String
    let text: String
    let expectedText: String
    let dictionary: [String]
    let issues: [Annotation]
}

private struct QualityCounts: Codable {
    var truePositives = 0
    var falsePositives = 0
    var falseNegatives = 0
    var correctSuggestions = 0
    var words = 0
    var cases = 0
    var cleanCases = 0
    var cleanCasesWithoutFindings = 0

    var precision: Double? {
        fraction(truePositives, truePositives + falsePositives)
    }
    var recall: Double? { fraction(truePositives, truePositives + falseNegatives) }
    var correctionAccuracy: Double? { fraction(correctSuggestions, truePositives) }
    var falseAlarmsPerThousandWords: Double? {
        fraction(falsePositives * 1_000, words)
    }
    var cleanRetention: Double? { fraction(cleanCasesWithoutFindings, cleanCases) }

    private func fraction(_ numerator: Int, _ denominator: Int) -> Double? {
        denominator > 0 ? Double(numerator) / Double(denominator) : nil
    }

    mutating func add(_ other: Self) {
        truePositives += other.truePositives
        falsePositives += other.falsePositives
        falseNegatives += other.falseNegatives
        correctSuggestions += other.correctSuggestions
        words += other.words
        cases += other.cases
        cleanCases += other.cleanCases
        cleanCasesWithoutFindings += other.cleanCasesWithoutFindings
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Derived rates must appear in the persisted evidence, not only counts.
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        var object = encoded
        object["precision"] = precision.map { $0 as Any } ?? NSNull()
        object["recall"] = recall.map { $0 as Any } ?? NSNull()
        object["correctionAccuracy"] = correctionAccuracy.map { $0 as Any } ?? NSNull()
        object["falseAlarmsPerThousandWords"] = falseAlarmsPerThousandWords.map { $0 as Any } ?? NSNull()
        object["cleanRetention"] = cleanRetention.map { $0 as Any } ?? NSNull()
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

private enum QualityCorpus {
    static func load() throws -> [QualitySample] {
        let override = ProcessInfo.processInfo.environment["BEAN_QUALITY_CORPUS_PATH"]
        let url = override.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/WritingQuality/corpus-v1.jsonl")
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try contents.split(separator: "\n").map {
            try JSONDecoder().decode(QualitySample.self, from: Data($0.utf8))
        }
    }

    struct Score {
        var overall = QualityCounts()
        var byType: [String: QualityCounts] = [:]
        var bySource: [String: QualityCounts] = [:]
        var failures: [String] = []
    }

    static func score(sample: QualitySample, findings: [TextIssue]) -> Score {
        var result = Score()
        result.overall.cases = 1
        result.overall.words = sample.text.split(whereSeparator: { $0.isWhitespace }).count
        if sample.issues.isEmpty {
            result.overall.cleanCases = 1
            result.overall.cleanCasesWithoutFindings = findings.isEmpty ? 1 : 0
        }
        var matched = Set<Int>()
        for finding in findings {
            let source = finding.source.rawValue
            let match = sample.issues.indices.first {
                !matched.contains($0) && finding.range.location <= sample.issues[$0].location
                    && NSMaxRange(finding.range) >= NSMaxRange(sample.issues[$0].range)
                    && finding.range.length <= sample.issues[$0].length + 80
            }
            guard let index = match else {
                result.overall.falsePositives += 1
                result.byType[finding.type.rawValue, default: QualityCounts()].falsePositives += 1
                result.bySource[source, default: QualityCounts()].falsePositives += 1
                result.failures.append("\(sample.id):falsePositive:\(finding.type.rawValue):\(source)")
                continue
            }
            matched.insert(index)
            let annotation = sample.issues[index]
            let input = sample.text as NSString
            let relative = NSRange(location: annotation.location - finding.range.location, length: annotation.length)
            let original = input.substring(with: finding.range)
            let accepted = annotation.corrections.contains { correction in
                (original as NSString).replacingCharacters(in: relative, with: correction) == finding.suggestion
            }
            result.overall.truePositives += 1
            result.byType[annotation.type, default: QualityCounts()].truePositives += 1
            result.bySource[source, default: QualityCounts()].truePositives += 1
            if accepted {
                result.overall.correctSuggestions += 1
                result.byType[annotation.type, default: QualityCounts()].correctSuggestions += 1
                result.bySource[source, default: QualityCounts()].correctSuggestions += 1
            } else {
                result.failures.append("\(sample.id):incorrectSuggestion:\(annotation.type):\(source)")
            }
        }
        for index in sample.issues.indices where !matched.contains(index) {
            result.overall.falseNegatives += 1
            result.byType[sample.issues[index].type, default: QualityCounts()].falseNegatives += 1
            result.failures.append("\(sample.id):missed:\(sample.issues[index].type)")
        }
        return result
    }
}

private struct QualityReport {
    let engine: String
    let operatingSystem: String
    var overall = QualityCounts()
    var bySplit: [String: QualityCounts] = [:]
    var byType: [String: QualityCounts] = [:]
    var bySource: [String: QualityCounts] = [:]
    var byDialect: [String: QualityCounts] = [:]
    var failures: [String] = []
    var timings: [Double] = []

    struct Latency {
        let p50: Double
        let p95: Double
        let maximum: Double
    }

    var latencyMilliseconds: Latency {
        let sorted = timings.sorted()
        guard !sorted.isEmpty else { return Latency(p50: 0, p95: 0, maximum: 0) }
        return Latency(p50: sorted[(sorted.count - 1) / 2],
                       p95: sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
                       maximum: sorted.last!)
    }

    mutating func record(sample: QualitySample, findings: [TextIssue], latency: Double) {
        let score = QualityCorpus.score(sample: sample, findings: findings)
        overall.add(score.overall)
        bySplit[sample.split, default: QualityCounts()].add(score.overall)
        byDialect[sample.dialect, default: QualityCounts()].add(score.overall)
        for (key, counts) in score.byType { byType[key, default: QualityCounts()].add(counts) }
        for (key, counts) in score.bySource { bySource[key, default: QualityCounts()].add(counts) }
        failures.append(contentsOf: score.failures)
        timings.append(latency)
    }

    func json() throws -> String {
        func object(_ counts: QualityCounts) throws -> Any {
            try JSONSerialization.jsonObject(with: Data(counts.json().utf8))
        }
        func group(_ values: [String: QualityCounts]) throws -> [String: Any] {
            try values.mapValues(object)
        }
        let latency = latencyMilliseconds
        var sourceObjects = try group(bySource)
        // A missed annotation has no returned source. A fabricated 100% recall
        // in every source group would hide misses even with an explanatory note.
        for key in sourceObjects.keys {
            var source = sourceObjects[key] as! [String: Any]
            source["recall"] = NSNull()
            sourceObjects[key] = source
        }
        let report: [String: Any] = [
            "schemaVersion": 1, "corpusVersion": 1, "engine": engine, "operatingSystem": operatingSystem,
            "provenance": "Agent-curated synthetic corpus; no human-reviewed real-provider evaluation",
            "sourceRecall": "Source groups attribute returned findings; missed issues have no source attribution. Use engine/split/type recall.",
            "overall": try object(overall), "bySplit": try group(bySplit), "byType": try group(byType),
            "bySource": sourceObjects, "byDialect": try group(byDialect),
            "latencyMilliseconds": ["p50": latency.p50, "p95": latency.p95, "maximum": latency.maximum],
            "failureCaseIds": failures
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
    }
}
