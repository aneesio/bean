import AppKit
import XCTest
@testable import Bean

/// Construct events only. Never post them or inspect another app or clipboard.
final class NativeKeyboardTransportTests: XCTestCase {
    func testBeanTransportMarkerSurvivesNSEventConversion() throws {
        let commands: [(CGKeyCode, CGEventFlags)] = [
            (0x00, .maskCommand), // Select All
            (0x08, .maskCommand), // Copy
            (0x09, .maskCommand), // Paste
            (0x33, []),           // Delete
            (0x7C, [])            // Collapse selection
        ]
        for (key, flags) in commands {
            let events = try XCTUnwrap(ClipboardService.syntheticKeyEvents(key, flags: flags))
            for event in [events.down, events.up] {
                let observed = try XCTUnwrap(NSEvent(cgEvent: event))
                XCTAssertTrue(ClipboardService.isBeanSyntheticKeyboardEvent(observed),
                              "Bean transport must not count as fresh user typing")
            }
        }
    }

    func testUntaggedPasteAndDeleteStillCountAsUserInteraction() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let commands: [(CGKeyCode, CGEventFlags)] = [(0x09, .maskCommand), (0x33, [])]
        for (key, flags) in commands {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true))
            event.flags = flags
            let observed = try XCTUnwrap(NSEvent(cgEvent: event))
            XCTAssertFalse(ClipboardService.isBeanSyntheticKeyboardEvent(observed),
                           "The key and modifiers alone must not hide real user edits")
        }
    }

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
