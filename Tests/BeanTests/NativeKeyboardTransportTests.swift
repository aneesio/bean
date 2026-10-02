import AppKit
import XCTest
@testable import Bean

/// Construct events only. Never post them or inspect another app or clipboard.
final class NativeKeyboardTransportTests: XCTestCase {
    func testPasteEventsUsePrivateStateExactModifiersAndNoRepeat() throws {
        let events = try XCTUnwrap(ClipboardService.syntheticKeyEvents(0x09, flags: .maskCommand))
        let privateID = events.down.getIntegerValueField(.eventSourceStateID)
        XCTAssertNotEqual(privateID, Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        XCTAssertNotEqual(privateID, Int64(CGEventSourceStateID.hidSystemState.rawValue))
        for event in [events.down, events.up] {
            XCTAssertEqual(event.flags, .maskCommand)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceStateID), privateID)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventAutorepeat), 0)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0x09)
            XCTAssertNotEqual(event.getIntegerValueField(.eventSourceUserData), 0)
        }
        XCTAssertEqual(events.down.type, .keyDown)
        XCTAssertEqual(events.up.type, .keyUp)
    }

    func testDeleteEventsHaveNoHeldShortcutModifiers() throws {
        let events = try XCTUnwrap(ClipboardService.syntheticKeyEvents(0x33, flags: []))
        XCTAssertTrue(events.down.flags.isEmpty)
        XCTAssertTrue(events.up.flags.isEmpty)
        let sourceID = events.down.getIntegerValueField(.eventSourceStateID)
        XCTAssertNotEqual(sourceID, Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        XCTAssertNotEqual(sourceID, Int64(CGEventSourceStateID.hidSystemState.rawValue))
        let other = try XCTUnwrap(ClipboardService.syntheticKeyEvents(0x33, flags: []))
        XCTAssertNotEqual(sourceID, other.down.getIntegerValueField(.eventSourceStateID),
                          "Each held source owns an independent private state table")
    }
}
