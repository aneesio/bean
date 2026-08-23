import AppKit
import XCTest
@testable import Bean

@MainActor
final class ApplicationMainMenuTests: XCTestCase {
    func testMainMenuContainsStandardBeanAndEditCommands() throws {
        let target = MainMenuTarget()
        let result = ApplicationMainMenuBuilder.build(
            target: target,
            aboutAction: #selector(MainMenuTarget.performAction(_:)),
            settingsAction: #selector(MainMenuTarget.performAction(_:)),
            quitAction: #selector(MainMenuTarget.performAction(_:))
        )

        XCTAssertEqual(result.menu.items.map(\.title), ["Bean", "Edit"])

        let beanMenu = try XCTUnwrap(result.menu.item(withTitle: "Bean")?.submenu)
        XCTAssertNotNil(beanMenu.item(withTitle: "About Bean"))
        XCTAssertEqual(beanMenu.item(withTitle: "Settings…")?.keyEquivalent, ",")
        XCTAssertTrue(beanMenu.item(withTitle: "Services")?.submenu === result.servicesMenu)
        XCTAssertEqual(beanMenu.item(withTitle: "Quit Bean")?.keyEquivalent, "q")

        let editMenu = try XCTUnwrap(result.menu.item(withTitle: "Edit")?.submenu)
        let expectedKeys = [
            "Undo": "z",
            "Redo": "z",
            "Cut": "x",
            "Copy": "c",
            "Paste": "v",
            "Select All": "a"
        ]
        for (title, key) in expectedKeys {
            let item = try XCTUnwrap(editMenu.item(withTitle: title), title)
            XCTAssertEqual(item.keyEquivalent, key, title)
            XCTAssertNil(item.target, "\(title) must route through the responder chain")
        }
        XCTAssertEqual(editMenu.item(withTitle: "Redo")?.keyEquivalentModifierMask, [.command, .shift])
    }
}

private final class MainMenuTarget: NSObject {
    @objc func performAction(_ sender: Any?) {}
}
