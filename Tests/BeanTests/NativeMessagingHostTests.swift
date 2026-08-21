import XCTest
@testable import Bean

final class NativeMessagingHostTests: XCTestCase {
    @MainActor
    func testPingCanCompleteWhenCalledFromMainActor() {
        let request = Data(#"{"id":"test","type":"ping"}"#.utf8)
        let response = NativeMessagingHost.processSync(request)
        let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]

        XCTAssertEqual(object?["id"] as? String, "test")
        XCTAssertEqual(object?["ok"] as? Bool, true)
    }
}
