import AppKit
import XCTest
@testable import Bean

final class SingleInstanceGuardTests: XCTestCase {
    func testHeadlessNativeBrowserHostNeverPreventsTheGUIFromLaunching() {
        XCTAssertFalse(SingleInstanceGuard.isDuplicateGUIApplication(
            bundleIdentifier: "com.bean.app", processIdentifier: 456, activationPolicy: .prohibited,
            currentBundleIdentifier: "com.bean.app", currentProcessIdentifier: 123
        ))
    }

    func testExistingMenuBarAndWindowedCopiesAreBothDuplicates() {
        for policy: NSApplication.ActivationPolicy in [.accessory, .regular] {
            XCTAssertTrue(SingleInstanceGuard.isDuplicateGUIApplication(
                bundleIdentifier: "com.bean.app", processIdentifier: 456, activationPolicy: policy,
                currentBundleIdentifier: "com.bean.app", currentProcessIdentifier: 123
            ))
        }
    }

    func testSelfOtherAppsAndUnbundledDeveloperRunsAreNotDuplicates() {
        XCTAssertFalse(SingleInstanceGuard.isDuplicateGUIApplication(
            bundleIdentifier: "com.bean.app", processIdentifier: 123, activationPolicy: .accessory,
            currentBundleIdentifier: "com.bean.app", currentProcessIdentifier: 123
        ))
        XCTAssertFalse(SingleInstanceGuard.isDuplicateGUIApplication(
            bundleIdentifier: "com.other.app", processIdentifier: 456, activationPolicy: .regular,
            currentBundleIdentifier: "com.bean.app", currentProcessIdentifier: 123
        ))
        XCTAssertFalse(SingleInstanceGuard.isDuplicateGUIApplication(
            bundleIdentifier: nil, processIdentifier: 456, activationPolicy: .regular,
            currentBundleIdentifier: nil, currentProcessIdentifier: 123
        ))
    }
}
