import Foundation
import XCTest

/// Prevents a future test from silently falling back to Bean's real
/// Application Support coordination directory. Isolated UserDefaults alone is
/// not enough: every accounting/history store also owns a lock-file path.
final class TestStorageIsolationTests: XCTestCase {
    func testEveryTestAccountingStoreUsesAnExplicitTemporaryDirectory() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let testsDirectory = repositoryRoot.appendingPathComponent(
            "Tests/BeanTests", isDirectory: true
        )
        let contracts = [
            (constructor: "UsageLedgerStore(", requiredLabel: "coordinationDirectoryURL:"),
            (constructor: "OperationHistoryStore(", requiredLabel: "coordinationDirectoryURL:"),
            (constructor: "AutomaticCallBudgetStore(", requiredLabel: "directoryURL:")
        ]

        let files = try FileManager.default.contentsOfDirectory(
            at: testsDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension == "swift"
                && $0.lastPathComponent != "TestStorageIsolationTests.swift"
        }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for contract in contracts {
                for arguments in argumentLists(
                    for: contract.constructor,
                    in: source
                ) {
                    XCTAssertTrue(
                        arguments.contains(contract.requiredLabel),
                        "\(file.lastPathComponent) constructs \(contract.constructor.dropLast()) without \(contract.requiredLabel); tests must never use Bean's live coordination directory"
                    )
                }
            }
        }
    }

    /// Extracts balanced Swift call arguments while ignoring parentheses inside
    /// ordinary string literals. The test constructors do not use raw strings,
    /// so a small purpose-built scanner keeps this gate dependency-free.
    private func argumentLists(for constructor: String, in source: String) -> [String] {
        var results: [String] = []
        var cursor = source.startIndex
        while cursor < source.endIndex,
              let marker = source.range(
                of: constructor,
                range: cursor..<source.endIndex
              ) {
            let opening = source.index(before: marker.upperBound)
            var index = source.index(after: opening)
            let argumentsStart = index
            var depth = 1
            var insideString = false
            var escaped = false

            while index < source.endIndex {
                let character = source[index]
                if insideString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        insideString = false
                    }
                } else if character == "\"" {
                    insideString = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        results.append(String(source[argumentsStart..<index]))
                        index = source.index(after: index)
                        break
                    }
                }
                index = source.index(after: index)
            }
            cursor = max(index, marker.upperBound)
        }
        return results
    }
}
