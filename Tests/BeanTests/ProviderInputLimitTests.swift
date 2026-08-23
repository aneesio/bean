import Foundation
import XCTest
@testable import Bean

final class ProviderInputLimitTests: XCTestCase {
    private var decomposedOversizedInput: String {
        // One user-perceived grapheme with a source payload just above 32 KB.
        // `String.count` alone reports 1 and would not enforce the cost boundary.
        "a" + String(
            repeating: "\u{0301}",
            count: EngineConfig.maxProviderInputUTF8Bytes / 2
        )
    }

    func testNativeProviderLimitMatchesExistingEightThousandCharacterBoundary() {
        XCTAssertEqual(EngineConfig.maxProviderInputCharacters, 8_000)
        XCTAssertEqual(EngineConfig.maxProviderInputUTF8Bytes, 32_000)
        XCTAssertEqual(EngineConfig.maxProviderRequestInputUTF8Bytes, 65_536)
        XCTAssertEqual(EngineConfig.maxAutoFieldCharacters,
                       EngineConfig.maxProviderInputCharacters)
    }

    func testSharedLimitBoundsBothGraphemesAndEncodedProviderPayload() {
        let characterBoundary = String(
            repeating: "a",
            count: EngineConfig.maxProviderInputCharacters
        )
        let fourByteScalarBoundary = String(
            repeating: "😀",
            count: EngineConfig.maxProviderInputCharacters
        )
        let decomposed = decomposedOversizedInput

        XCTAssertTrue(EngineConfig.providerInputIsWithinLimit(characterBoundary))
        XCTAssertTrue(EngineConfig.providerInputIsWithinLimit(fourByteScalarBoundary))
        XCTAssertEqual(fourByteScalarBoundary.utf8.count,
                       EngineConfig.maxProviderInputUTF8Bytes)
        XCTAssertEqual(decomposed.count, 1,
                       "the regression must bypass a grapheme-only check")
        XCTAssertGreaterThan(decomposed.utf8.count,
                             EngineConfig.maxProviderInputUTF8Bytes)
        XCTAssertTrue(EngineConfig.exceedsProviderInputLimit(decomposed))

        XCTAssertTrue(EngineConfig.exceedsProviderInputLimit(
            "a" + String(repeating: "\u{0301}", count: 4_000),
            maximumCharacters: 2_000
        ), "tighter paragraph limits receive a proportional UTF-8 ceiling")
    }

    func testExactEncodedRequestLimitCombinesSystemAndUserPayloadBytes() {
        let limit = EngineConfig.maxProviderRequestInputUTF8Bytes
        XCTAssertTrue(EngineConfig.providerRequestInputIsWithinLimit(
            systemPrompt: "system",
            userText: String(repeating: "u", count: limit - 6)
        ))
        XCTAssertFalse(EngineConfig.providerRequestInputIsWithinLimit(
            systemPrompt: "system",
            userText: String(repeating: "u", count: limit - 5)
        ))

        let escapedSource = String(repeating: "<", count: 8_000)
        XCTAssertTrue(EngineConfig.providerInputIsWithinLimit(escapedSource))
        XCTAssertGreaterThan(
            WritingTransformService.userMessage(
                text: escapedSource,
                action: .proofread,
                context: nil,
                userContextLines: []
            ).utf8.count,
            escapedSource.utf8.count,
            "the final boundary must measure the encoded payload, not only source bytes"
        )
    }

    func testByteHeavyDictionaryTermIsOmittedFromEveryIssuePrompt() throws {
        let term = "a" + String(repeating: "\u{0301}", count: 2_000)
        XCTAssertEqual(term.count, 1)
        XCTAssertGreaterThan(term.utf8.count,
                             DictionaryPromptFormatter.maximumPromptUTF8Bytes)

        let formatted = DictionaryPromptFormatter.formattedRelevantTerms(
            from: [DictionaryTerm(term: term)],
            in: "Keep \(term) exactly."
        )
        XCTAssertTrue(formatted.isEmpty)

        let message = IssueDetector.userMessage(
            text: "Keep \(term) exactly.",
            context: nil,
            dictionary: [DictionaryTerm(term: term)],
            maximumIssues: 3
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        XCTAssertNil(payload["preserveTerms"])
    }

    @MainActor
    func testProviderActionsStopAboveLimitButQuickFixRemainsUnboundedAndLocal() {
        let limit = EngineConfig.maxProviderInputCharacters
        let atLimit = String(repeating: "a", count: limit)
        let aboveLimit = String(repeating: "a", count: limit + 1)

        for action in WritingAction.allCases where action.usesProvider {
            XCTAssertFalse(TextActionCoordinator.exceedsProviderInputLimit(
                action: action,
                text: atLimit
            ), "\(action) should accept input at the boundary")
            XCTAssertTrue(TextActionCoordinator.exceedsProviderInputLimit(
                action: action,
                text: aboveLimit
            ), "\(action) should reject input above the boundary")
            XCTAssertTrue(TextActionCoordinator.exceedsProviderInputLimit(
                action: action,
                text: decomposedOversizedInput
            ), "\(action) should reject a byte-heavy decomposed grapheme")
        }

        XCTAssertFalse(TextActionCoordinator.exceedsProviderInputLimit(
            action: .localQuickCheck,
            text: String(repeating: "a", count: limit + 100_000)
        ))
        XCTAssertFalse(TextActionCoordinator.exceedsProviderInputLimit(
            action: .localQuickCheck,
            text: decomposedOversizedInput
        ))
        XCTAssertFalse(TextActionCoordinator.quickFixAction.usesProvider)
    }

    func testCoordinatorRejectsOversizeInputBeforeAnyProviderRequest() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Bean/Core/TextActionCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let localBranch = try XCTUnwrap(source.range(of: "if action == .localQuickCheck"))
        let sizeGuard = try XCTUnwrap(source.range(of:
            "if Self.exceedsProviderInputLimit(action: action, text: job.core)"))
        let reasonCode = try XCTUnwrap(source.range(of: "providerInputTooLong",
                                                    range: sizeGuard.lowerBound..<source.endIndex))
        let notice = try XCTUnwrap(source.range(of: "title: \"Select Less Text\"",
                                                range: sizeGuard.lowerBound..<source.endIndex))
        let transformCall = try XCTUnwrap(source.range(of: "transformer.transform(",
                                                       range: sizeGuard.lowerBound..<source.endIndex))

        XCTAssertLessThan(localBranch.lowerBound, sizeGuard.lowerBound,
                          "Quick Fix must finish locally before the provider-only guard")
        XCTAssertLessThan(sizeGuard.lowerBound, reasonCode.lowerBound,
                          "The refusal must record a content-free outcome")
        XCTAssertLessThan(reasonCode.lowerBound, notice.lowerBound,
                          "The refusal must lead into the persistent acquisition notice")
        XCTAssertLessThan(notice.lowerBound, transformCall.lowerBound,
                          "Oversize input must return before any provider call")

        let guardedBlock = source[sizeGuard.lowerBound..<transformCall.lowerBound]
        XCTAssertTrue(guardedBlock.contains("presentAcquisitionNotice("))
        XCTAssertTrue(guardedBlock.contains("sourceAnchorRect: job.sourceAnchorRect"))
        XCTAssertTrue(guardedBlock.contains("return"))

        let noticeHelperStart = try XCTUnwrap(source.range(of:
            "private func presentAcquisitionNotice("))
        let nextHelper = try XCTUnwrap(source.range(of:
            "private func presentProviderFailure(",
            range: noticeHelperStart.upperBound..<source.endIndex))
        let noticeHelper = source[noticeHelperStart.lowerBound..<nextHelper.lowerBound]
        XCTAssertEqual(
            noticeHelper.components(separatedBy: "finishNotice(restoreAcquisition: true)").count - 1,
            2,
            "Both acknowledging and dismissing the notice must restore the captured clipboard state"
        )
    }

    @MainActor
    func testPassiveProviderPathUsesTheSharedLimitBeforeReservation() throws {
        let limit = EngineConfig.maxProviderInputCharacters
        XCTAssertFalse(PassiveSuggestionService.exceedsProviderInputLimit(
            text: String(repeating: "a", count: limit)
        ))
        XCTAssertTrue(PassiveSuggestionService.exceedsProviderInputLimit(
            text: String(repeating: "a", count: limit + 1)
        ))
        XCTAssertTrue(PassiveSuggestionService.exceedsProviderInputLimit(
            text: decomposedOversizedInput
        ))
        let passiveByteHeavy = "a" + String(repeating: "\u{0301}", count: 4_000)
        XCTAssertTrue(PassiveSuggestionService.exceedsProviderInputLimit(
            text: passiveByteHeavy,
            maximumCharacters: 2_000
        ), "the default passive ceiling must also impose its proportional 8 KB byte cap")

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Bean/Core/PassiveSuggestionService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let guardRange = try XCTUnwrap(source.range(of:
            "guard !Self.exceedsProviderInputLimit("))
        let proportionalLimit = try XCTUnwrap(source.range(
            of: "maximumCharacters: providerCharacterLimit",
            range: guardRange.lowerBound..<source.endIndex
        ))
        let payloadRange = try XCTUnwrap(source.range(
            of: "WritingTransformService.providerPayloadIsWithinLimit(",
            range: guardRange.upperBound..<source.endIndex
        ))
        let reservationRange = try XCTUnwrap(source.range(
            of: "automaticCallBudget.reserve(",
            range: guardRange.upperBound..<source.endIndex
        ))
        XCTAssertLessThan(guardRange.lowerBound, proportionalLimit.lowerBound)
        XCTAssertLessThan(proportionalLimit.lowerBound, payloadRange.lowerBound)
        XCTAssertLessThan(payloadRange.lowerBound, reservationRange.lowerBound,
                          "oversize passive text must stop before spending a daily slot")
    }

    func testAutomaticAndBrowserReservationsCheckSharedLimitBeforeSpending() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let passive = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Bean/Core/PassiveSuggestionService.swift"
            ),
            encoding: .utf8
        )
        let retryStart = try XCTUnwrap(passive.range(of: "private func previewRetry("))
        let retryLimit = try XCTUnwrap(passive.range(
            of: "EngineConfig.providerInputIsWithinLimit(session.sourceCore)",
            range: retryStart.upperBound..<passive.endIndex
        ))
        let retryPayload = try XCTUnwrap(passive.range(
            of: "WritingTransformService.providerPayloadIsWithinLimit(",
            range: retryLimit.upperBound..<passive.endIndex
        ))
        let manualReservation = try XCTUnwrap(passive.range(
            of: "automaticCallBudget.reserveManual(",
            range: retryStart.upperBound..<passive.endIndex
        ))
        XCTAssertLessThan(retryLimit.lowerBound, retryPayload.lowerBound)
        XCTAssertLessThan(retryPayload.lowerBound, manualReservation.lowerBound)

        let inline = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Bean/Core/InlineHighlightService.swift"
            ),
            encoding: .utf8
        )
        let inlineLimit = try XCTUnwrap(inline.range(of:
            "let providerInputWithinLimit = EngineConfig.providerInputIsWithinLimit("))
        let inlinePayload = try XCTUnwrap(inline.range(
            of: "IssueDetector.providerPayloadIsWithinLimit(",
            range: inlineLimit.upperBound..<inline.endIndex
        ))
        let inlineReservation = try XCTUnwrap(inline.range(of:
            "automaticCallBudget.reserve(", range: inlineLimit.upperBound..<inline.endIndex))
        XCTAssertLessThan(inlineLimit.lowerBound, inlinePayload.lowerBound)
        XCTAssertLessThan(inlinePayload.lowerBound, inlineReservation.lowerBound)

        let native = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Bean/Core/NativeMessagingHost.swift"
            ),
            encoding: .utf8
        )
        for function in ["private static func detect(", "private static func proofreadParagraph("] {
            let start = try XCTUnwrap(native.range(of: function))
            let limit = try XCTUnwrap(native.range(
                of: "EngineConfig.providerInputIsWithinLimit(",
                range: start.upperBound..<native.endIndex
            ))
            let payloadBoundary = function.contains("detect")
                ? "IssueDetector.providerPayloadIsWithinLimit("
                : "WritingTransformService.providerPayloadIsWithinLimit("
            let payload = try XCTUnwrap(native.range(
                of: payloadBoundary,
                range: limit.upperBound..<native.endIndex
            ))
            let reservation = try XCTUnwrap(native.range(
                of: "reserveAutomaticCallIfConfigurationVerified(",
                range: start.upperBound..<native.endIndex
            ))
            XCTAssertLessThan(limit.lowerBound, payload.lowerBound, function)
            XCTAssertLessThan(payload.lowerBound, reservation.lowerBound, function)
        }
    }

    func testSharedTransformBoundaryRejectsOversizeTextBeforeProviderCreation() async {
        let oversized = String(
            repeating: "a",
            count: EngineConfig.maxProviderInputCharacters + 1
        )
        do {
            _ = try await WritingTransformService().transform(
                text: oversized,
                action: .proofread,
                context: nil,
                provider: .openai,
                model: ProviderKind.openai.defaultModel,
                apiKey: "not-a-real-key",
                timeout: 1
            )
            XCTFail("Oversize provider text must fail before a network request")
        } catch let error as LLMError {
            guard case .inputTooLong(let maxCharacters) = error else {
                return XCTFail("Expected inputTooLong, got \(error)")
            }
            XCTAssertEqual(maxCharacters, EngineConfig.maxProviderInputCharacters)
        } catch {
            XCTFail("Expected LLMError.inputTooLong, got \(error)")
        }
    }

    func testSharedTransformBoundaryRejectsDecomposedUnicodeBeforeProviderCreation() async {
        do {
            _ = try await WritingTransformService().transform(
                text: decomposedOversizedInput,
                action: .proofread,
                context: nil,
                provider: .openai,
                model: ProviderKind.openai.defaultModel,
                apiKey: "not-a-real-key",
                timeout: 1
            )
            XCTFail("A byte-heavy decomposed grapheme must fail before a network request")
        } catch let error as LLMError {
            guard case .inputTooLong(let maxCharacters) = error else {
                return XCTFail("Expected inputTooLong, got \(error)")
            }
            XCTAssertEqual(maxCharacters, EngineConfig.maxProviderInputCharacters)
        } catch {
            XCTFail("Expected LLMError.inputTooLong, got \(error)")
        }
    }

    func testSharedTransformBoundaryRejectsByteHeavyPersonalizationBeforeProviderCreation() async {
        let promptBomb = "preference" + String(
            repeating: "\u{0301}",
            count: EngineConfig.maxProviderRequestInputUTF8Bytes
        )
        XCTAssertEqual(promptBomb.count, 10)
        XCTAssertTrue(EngineConfig.providerInputIsWithinLimit("Small source"))
        XCTAssertFalse(WritingTransformService.providerPayloadIsWithinLimit(
            text: "Small source",
            action: .makeClearer,
            context: nil,
            userContextLines: [promptBomb]
        ))

        do {
            _ = try await WritingTransformService().transform(
                text: "Small source",
                action: .makeClearer,
                context: nil,
                userContextLines: [promptBomb],
                provider: .openai,
                model: ProviderKind.openai.defaultModel,
                apiKey: "not-a-real-key",
                timeout: 1
            )
            XCTFail("Byte-heavy personalization must fail before a network request")
        } catch let error as LLMError {
            guard case .inputTooLong = error else {
                return XCTFail("Expected inputTooLong, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMError.inputTooLong, got \(error)")
        }
    }

    func testStructuredIssueBoundaryRejectsDecomposedUnicodeBeforeProviderCreation() async {
        let result = await IssueDetector().llmIssues(
            in: decomposedOversizedInput,
            context: nil,
            dictionary: [],
            provider: .openai,
            model: ProviderKind.openai.defaultModel,
            apiKey: "not-a-real-key",
            timeout: 1
        )

        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertNil(result.usage)
        XCTAssertEqual(result.failureOutcome, "providerInputTooLong")
    }
}
