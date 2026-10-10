import XCTest
import ApplicationServices
@testable import Bean

final class FocusedFieldDetectionTests: XCTestCase {
    func testWebDocumentEditorQualifiesByTextEditingCapabilities() {
        for field in [
            textField(role: "AXWebArea", valueSettable: true),
            textField(role: "AXWebArea", selectedTextSettable: true),
            textField(role: "AXWebArea", editable: true)
        ] {
            XCTAssertTrue(field.isSemanticTextSurface)
            XCTAssertTrue(field.acceptsTextInput)
        }
    }

    func testSelectableWebDocumentIsNotMistakenForAnEditor() {
        let page = textField(role: "AXWebArea", rangeSettable: true)
        XCTAssertFalse(page.isSemanticTextSurface)
        XCTAssertFalse(page.acceptsTextInput)
        let readOnly = textField(role: "AXWebArea", valueSettable: true,
                                 selectedTextSettable: true, rangeSettable: true, editable: false)
        XCTAssertFalse(readOnly.isSemanticTextSurface)
        XCTAssertFalse(readOnly.acceptsTextInput)
    }

    func testWebEditorEvidenceDoesNotBroadenOtherControlRoles() {
        for role in ["AXButton", "AXSlider", "AXGroup", "AXStaticText", "AXWindow"] {
            let control = textField(role: role, valueSettable: true,
                                    selectedTextSettable: true, rangeSettable: true, editable: true)
            XCTAssertFalse(control.isSemanticTextSurface, role)
            XCTAssertFalse(control.acceptsTextInput, role)
        }
    }

    func testDisabledAndSecureWebEditorsRemainExcluded() {
        let disabled = textField(role: "AXWebArea", valueSettable: true, enabled: false)
        XCTAssertFalse(disabled.isSemanticTextSurface)
        XCTAssertFalse(disabled.acceptsTextInput)
        let secure = textField(role: "AXWebArea", subrole: "AXSecureTextField", valueSettable: true)
        XCTAssertFalse(secure.isSemanticTextSurface)
        XCTAssertFalse(secure.acceptsTextInput)
    }

    func testLegacyAndCurrentEditableAttributesUseExplicitReadOnlyPrecedence() {
        XCTAssertEqual(AccessibilityService.explicitEditability(
            readOnly: nil, editable: nil, isEditable: true), true)
        XCTAssertEqual(AccessibilityService.explicitEditability(
            readOnly: nil, editable: true, isEditable: nil), true)
        XCTAssertNil(AccessibilityService.explicitEditability(
            readOnly: false, editable: nil, isEditable: nil))
        for attributes in [(true, true, true), (false, false, true), (false, true, false)] {
            XCTAssertEqual(AccessibilityService.explicitEditability(
                readOnly: attributes.0, editable: attributes.1, isEditable: attributes.2), false)
        }
    }

    func testKeyboardEditableFieldsDoNotRequireDirectAXTextWrites() {
        XCTAssertTrue(AccessibilityService.acceptsTextInput(
            isSemanticTextSurface: true, isExplicitlyEditable: nil,
            hasEditableAncestor: false, isValueSettable: false,
            isSelectedTextSettable: false, isSelectedRangeSettable: true
        ))
        XCTAssertTrue(AccessibilityService.acceptsTextInput(
            isSemanticTextSurface: true, isExplicitlyEditable: true,
            hasEditableAncestor: false, isValueSettable: false,
            isSelectedTextSettable: false, isSelectedRangeSettable: false
        ))
    }

    func testExplicitReadOnlyOverridesSettersAndEditableAncestor() {
        XCTAssertFalse(AccessibilityService.acceptsTextInput(
            isSemanticTextSurface: true, isExplicitlyEditable: false,
            hasEditableAncestor: true, isValueSettable: true,
            isSelectedTextSettable: true, isSelectedRangeSettable: true
        ))
    }

    func testNonTextSecureAndDisabledSemanticGateCannotBecomeEditable() {
        XCTAssertFalse(AccessibilityService.acceptsTextInput(
            isSemanticTextSurface: false, isExplicitlyEditable: true,
            hasEditableAncestor: true, isValueSettable: true,
            isSelectedTextSettable: true, isSelectedRangeSettable: true
        ))
        XCTAssertFalse(AccessibilityService.acceptsTextInput(
            isSemanticTextSurface: true, isExplicitlyEditable: nil,
            hasEditableAncestor: false, isValueSettable: false,
            isSelectedTextSettable: false, isSelectedRangeSettable: false
        ))
    }

    func testRangeOnlyTextReadsAreBoundedWithoutTruncation() {
        XCTAssertTrue(AccessibilityService.canReadFallbackText(characterCount: 0))
        XCTAssertTrue(AccessibilityService.canReadFallbackText(characterCount: 200_000))
        XCTAssertFalse(AccessibilityService.canReadFallbackText(characterCount: -1))
        XCTAssertFalse(AccessibilityService.canReadFallbackText(characterCount: 200_001))
        XCTAssertFalse(AccessibilityService.canReadFallbackText(characterCount: Int.max))
    }

    func testFocusPollingChecksAnExistingDraftWithoutAKeyEvent() {
        var tracker = TypingPauseActivityTracker()
        XCTAssertEqual(tracker.observe(nil), .unchanged)
        let draft = snapshot("I recieved your message.")
        XCTAssertEqual(tracker.observe(draft), .focusChanged)
        XCTAssertEqual(tracker.observe(draft), .unchanged)
    }

    func testPollingNoticesPasteAndProgrammaticChangesButNotCaretMovement() {
        var tracker = TypingPauseActivityTracker()
        let original = snapshot("Hello")
        _ = tracker.observe(original)
        XCTAssertEqual(tracker.observe(snapshot("Hello teh team")), .textChanged)
        XCTAssertEqual(tracker.observe(snapshot("Hello teh team")), .unchanged)
        XCTAssertEqual(tracker.observe(snapshot("Hello the team")), .textChanged)
    }

    func testIdenticalTextInDifferentFieldsIsANewTarget() {
        var tracker = TypingPauseActivityTracker()
        _ = tracker.observe(snapshot("teh"))
        XCTAssertEqual(tracker.observe(snapshot("teh", field: 2)), .focusChanged)
        XCTAssertEqual(tracker.observe(snapshot("teh", app: 2, field: 2)), .focusChanged)
    }

    func testUnreadableFieldDoesNotPretendToHaveAnEmptyCheckedValue() {
        var tracker = TypingPauseActivityTracker()
        _ = tracker.observe(snapshot(nil))
        XCTAssertEqual(tracker.observe(snapshot("")), .textChanged)
        XCTAssertEqual(tracker.observe(snapshot(nil)), .textChanged)
        XCTAssertEqual(tracker.observe(snapshot(nil)), .unchanged)
        XCTAssertEqual(tracker.observe(nil), .focusChanged)
        XCTAssertEqual(tracker.observe(nil), .unchanged)
    }

    func testDisablingFocusedFieldAndResetDiscardStoredContent() {
        var tracker = TypingPauseActivityTracker()
        _ = tracker.observe(snapshot("Draft"))
        XCTAssertEqual(tracker.observe(snapshot("Draft", editable: false)), .focusChanged)
        tracker.reset()
        XCTAssertNil(tracker.snapshot)
        XCTAssertEqual(tracker.observe(snapshot("Draft")), .focusChanged)
    }

    private func snapshot(_ value: String?, app: Int32 = 1, field: Int = 1,
                          editable: Bool = true) -> TypingPauseActivityTracker.Snapshot {
        .init(processIdentifier: app, fieldIdentity: field,
              value: value, acceptsTextInput: editable)
    }

    private func textField(role: String, subrole: String? = nil,
                           valueSettable: Bool = false, selectedTextSettable: Bool = false,
                           rangeSettable: Bool = false, editable: Bool? = nil,
                           enabled: Bool = true) -> AccessibilityService.FocusedField {
        .init(element: AXUIElementCreateApplication(1), role: role, subrole: subrole,
              value: nil, title: nil, placeholder: nil,
              isValueSettable: valueSettable, isSelectedTextSettable: selectedTextSettable,
              isEnabled: enabled, hasEditableAncestor: false,
              isExplicitlyEditable: editable, isSelectedRangeSettable: rangeSettable)
    }
}
