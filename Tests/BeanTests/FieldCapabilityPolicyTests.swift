import XCTest
@testable import Bean

final class FieldCapabilityPolicyTests: XCTestCase {
    private var enabled: CapabilityPreferences {
        CapabilityPreferences(
            accessibilityGranted: true,
            focusedFieldFallbackEnabled: true,
            bubbleEnabled: true,
            bubbleInChat: true,
            bubbleInMailBrowser: true,
            bubbleInCode: false,
            bubbleInSearch: false,
            inlineEnabled: true,
            webInlineEnabled: true
        )
    }

    func testFiveReferenceSurfaceProfiles() {
        let native = FieldTraits()
        let textEdit = evaluate("com.apple.TextEdit", .unknown, native)
        XCTAssertEqual(textEdit.referenceSurface, .textEdit)
        XCTAssertEqual(levels(textEdit), [.supported, .supported, .supported, .supported])

        let notes = evaluate("com.apple.Notes", .unknown, native)
        XCTAssertEqual(notes.referenceSurface, .appleNotes)
        XCTAssertEqual(levels(notes), [.supported, .supported, .supported, .supported])

        let mail = evaluate("com.apple.mail", .mail, native)
        XCTAssertEqual(mail.referenceSurface, .appleMail)
        XCTAssertEqual(levels(mail), [.supported, .supported, .supported, .supported])

        let electron = FieldTraits(isSemanticTextSurface: true, acceptsTextInput: false,
                                   isValueSettable: false, hasBubbleBounds: false,
                                   nativeRangeBoundsReliable: false)
        let slack = evaluate("com.tinyspeck.slackmacgap", .chat, electron)
        XCTAssertEqual(slack.referenceSurface, .slackDesktop)
        XCTAssertEqual(levels(slack), [.supported, .degraded, .degraded, .degraded])
        XCTAssertEqual(slack.focusedFieldReplacement.reason, "electronPasteBestEffort")
        XCTAssertEqual(slack.beanBubble.reason, "electronTypingEvidenceFallback")

        let web = FieldTraits(isValueSettable: false, nativeRangeBoundsReliable: false)
        let chromium = evaluate("com.google.Chrome", .unknown, web)
        XCTAssertEqual(chromium.referenceSurface, .chromiumWeb)
        XCTAssertEqual(levels(chromium), [.supported, .degraded, .supported, .degraded])
        XCTAssertEqual(chromium.inlineChecking.reason, "browserExtensionEnabled")
    }

    func testSecureAndDisabledFieldsAreUnavailableEverywhere() {
        for traits in [FieldTraits(isSecure: true), FieldTraits(isEnabled: false)] {
            let result = evaluate("com.apple.TextEdit", .unknown, traits)
            XCTAssertTrue(levels(result).allSatisfy { $0 == .unsupported })
        }
    }

    func testReadOnlyFieldNeverAdvertisesFocusedReplacementOrBubble() {
        let readOnly = FieldTraits(isSemanticTextSurface: true, acceptsTextInput: false,
                                   isValueSettable: false)
        let result = evaluate("com.apple.Notes", .unknown, readOnly)
        XCTAssertEqual(result.selectedTextAction.level, .supported)
        XCTAssertEqual(result.focusedFieldReplacement.level, .unsupported)
        XCTAssertEqual(result.beanBubble.level, .unsupported)
        XCTAssertEqual(result.inlineChecking.level, .unsupported)
    }

    func testSearchAndCodeSurfacesFailClosedForWholeFieldAndAutomaticUI() {
        let search = evaluate("com.apple.Safari", .unknown,
                              FieldTraits(isSearchLike: true))
        XCTAssertEqual(search.focusedFieldReplacement.reason, "searchFieldDisabled")
        XCTAssertEqual(search.beanBubble.reason, "searchFieldDisabled")
        XCTAssertEqual(search.inlineChecking.reason, "searchFieldDisabled")

        let code = evaluate("com.microsoft.VSCode", .codeEditor, FieldTraits())
        XCTAssertEqual(code.focusedFieldReplacement.reason, "codeEditorDisabled")
        XCTAssertEqual(code.beanBubble.reason, "categoryDisabled")
        XCTAssertEqual(code.inlineChecking.reason, "codeEditorDisabled")
    }

    func testPermissionNoFieldAndFeatureOffStatesAreExplicit() {
        var noPermission = enabled
        noPermission = CapabilityPreferences(
            accessibilityGranted: false,
            focusedFieldFallbackEnabled: noPermission.focusedFieldFallbackEnabled,
            bubbleEnabled: noPermission.bubbleEnabled,
            bubbleInChat: noPermission.bubbleInChat,
            bubbleInMailBrowser: noPermission.bubbleInMailBrowser,
            bubbleInCode: noPermission.bubbleInCode,
            bubbleInSearch: noPermission.bubbleInSearch,
            inlineEnabled: noPermission.inlineEnabled,
            webInlineEnabled: noPermission.webInlineEnabled)
        let denied = FieldCapabilityPolicy.evaluate(
            bundleIdentifier: "com.apple.TextEdit", category: .unknown,
            traits: FieldTraits(), preferences: noPermission)
        XCTAssertTrue(levels(denied).allSatisfy { $0 == .unsupported })

        let noField = FieldCapabilityPolicy.evaluate(
            bundleIdentifier: "com.apple.TextEdit", category: .unknown,
            traits: nil, preferences: enabled)
        XCTAssertTrue(levels(noField).allSatisfy { $0 == .unsupported })

        let manualOnly = CapabilityPreferences.manual(focusedFieldFallbackEnabled: true)
        let off = FieldCapabilityPolicy.evaluate(
            bundleIdentifier: "com.apple.TextEdit", category: .unknown,
            traits: FieldTraits(), preferences: manualOnly)
        XCTAssertEqual(off.focusedFieldReplacement.level, .supported)
        XCTAssertEqual(off.beanBubble.reason, "categoryDisabled")
        XCTAssertEqual(off.inlineChecking.reason, "supportedButDisabled")
    }

    private func evaluate(_ bundle: String, _ category: AppCategory,
                          _ traits: FieldTraits) -> FieldCapabilities {
        FieldCapabilityPolicy.evaluate(bundleIdentifier: bundle, category: category,
                                       traits: traits, preferences: enabled)
    }

    private func levels(_ result: FieldCapabilities) -> [CapabilityLevel] {
        [result.selectedTextAction.level, result.focusedFieldReplacement.level,
         result.beanBubble.level, result.inlineChecking.level]
    }
}
