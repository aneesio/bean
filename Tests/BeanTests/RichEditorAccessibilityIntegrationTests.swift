import AppKit
import ApplicationServices
import WebKit
import XCTest
@testable import Bean

/// Live coverage against an editor created by this test process. These tests
/// never query system-wide focus, another application, the clipboard, or keys.
/// An unavailable local AX endpoint is reported as a skip, without a TCC prompt.
final class RichEditorAccessibilityIntegrationTests: XCTestCase {
    @MainActor
    func testRichEditorReadsTheCompleteEmojiAndRepeatedText() async throws {
        try requireTrustedFixtureHost()
        let original = "👩🏽‍💻 teh and teh"
        let fixture = OwnedRichEditorFixture(text: original, readOnly: false)
        defer { fixture.close() }
        try await fixture.load()
        try await fixture.select(start: 0, length: (original as NSString).length)
        let element = try await fixture.accessibilityElement()
        let value = await Task.detached { AccessibilityService.value(of: element) }.value
        XCTAssertEqual(value, original, "The rich editor must supply a complete exact field snapshot")
        let field = await Task.detached {
            AccessibilityService.focusedField(from: element)
        }.value
        XCTAssertTrue(try XCTUnwrap(field).acceptsTextInput)
        XCTAssertEqual(field?.value, original)
    }

    @MainActor
    func testSelectionIdentityDistinguishesTwoIdenticalWordsAfterEmoji() async throws {
        try requireTrustedFixtureHost()
        let original = "👩🏽‍💻 teh and teh"
        let first = (original as NSString).range(of: "teh")
        let second = (original as NSString).range(of: "teh", options: .backwards)
        let fixture = OwnedRichEditorFixture(text: original, readOnly: false)
        defer { fixture.close() }
        try await fixture.load()
        try await fixture.select(start: first.location, length: first.length)
        let element = try await fixture.accessibilityElement()
        let firstSnapshot = await Task.detached {
            AccessibilityService.selectionSnapshot(of: element)
        }.value
        let captured = try XCTUnwrap(firstSnapshot, "WebKit must expose the selected range or opaque marker")
        XCTAssertEqual(captured.text, "teh")
        let initiallyMatches = await Task.detached {
            AccessibilityService.selectionMatches(captured, on: element)
        }.value
        XCTAssertTrue(initiallyMatches)

        try await fixture.select(start: second.location, length: second.length)
        let secondSnapshot = await Task.detached {
            AccessibilityService.selectionSnapshot(of: element)
        }.value
        XCTAssertEqual(try XCTUnwrap(secondSnapshot).text, "teh")
        let stillMatches = await Task.detached {
            AccessibilityService.selectionMatches(captured, on: element)
        }.value
        XCTAssertFalse(stillMatches, "Identical selected words at different positions are different destinations")
        let unchangedText = try await fixture.currentText()
        XCTAssertEqual(unchangedText, original, "Reading selection must not edit the field")
    }

    @MainActor
    func testReadonlyRichTextNeverQualifiesForFieldReplacement() async throws {
        try requireTrustedFixtureHost()
        let original = "Read only 👩🏽‍💻 teh and teh"
        let fixture = OwnedRichEditorFixture(text: original, readOnly: true)
        defer { fixture.close() }
        try await fixture.load()
        try await fixture.select(start: 0, length: (original as NSString).length)
        let element = try await fixture.accessibilityElement()
        let field = await Task.detached {
            AccessibilityService.focusedField(from: element)
        }.value
        let captured = try XCTUnwrap(field)
        XCTAssertFalse(captured.acceptsTextInput,
                       "Readonly traits: role=\(captured.role ?? "nil"), explicitEditable=\(String(describing: captured.isExplicitlyEditable)), valueSettable=\(captured.isValueSettable), selectedTextSettable=\(captured.isSelectedTextSettable), selectedRangeSettable=\(captured.isSelectedRangeSettable), editableAncestor=\(captured.hasEditableAncestor)")
        let unchangedText = try await fixture.currentText()
        XCTAssertEqual(unchangedText, original)
    }

    @MainActor
    func testDesignModeWebAreaReadsFullMarkerTextAndDistinguishesRepeatedSelections() async throws {
        try requireTrustedFixtureHost()
        let original = "👩🏽‍💻 teh and teh"
        let fixture = OwnedRichEditorFixture(text: original, readOnly: false, designMode: true)
        defer { fixture.close() }
        try await fixture.load()
        let first = (original as NSString).range(of: "teh")
        let second = (original as NSString).range(of: "teh", options: .backwards)
        try await fixture.select(start: first.location, length: first.length)
        let webArea = try await fixture.accessibilityElement()
        let field = await Task.detached { AccessibilityService.focusedField(from: webArea) }.value
        XCTAssertEqual(try XCTUnwrap(field).role, "AXWebArea")
        XCTAssertTrue(field?.acceptsTextInput == true)
        let fullValue = await Task.detached { AccessibilityService.value(of: webArea) }.value
        XCTAssertEqual(fullValue, original)
        let selected = await Task.detached { AccessibilityService.selectionSnapshot(of: webArea) }.value
        let snapshot = try XCTUnwrap(selected)
        XCTAssertEqual(snapshot.text, "teh")
        guard snapshot.range == nil else {
            throw XCTSkip("This WebKit host supplies numeric WebArea selection; opaque marker selection identity was not exercised.")
        }
        let initialMatch = await Task.detached { AccessibilityService.selectionMatches(snapshot, on: webArea) }.value
        XCTAssertTrue(initialMatch)
        try await fixture.select(start: second.location, length: second.length)
        let movedMatch = await Task.detached { AccessibilityService.selectionMatches(snapshot, on: webArea) }.value
        XCTAssertFalse(movedMatch)
    }

    @MainActor
    func testReadonlyWebAreaRemainsReadableWithoutBeingAnEditingDestination() async throws {
        try requireTrustedFixtureHost()
        let original = "Read only 👩🏽‍💻 teh and teh"
        let fixture = OwnedRichEditorFixture(text: original, readOnly: false, designMode: true)
        defer { fixture.close() }
        try await fixture.load()
        try await fixture.disableDocumentEditing()
        try await fixture.select(start: 0, length: (original as NSString).length)
        let webArea = try await fixture.accessibilityElement()
        let field = await Task.detached { AccessibilityService.focusedField(from: webArea) }.value
        XCTAssertEqual(try XCTUnwrap(field).role, "AXWebArea")
        XCTAssertFalse(field?.acceptsTextInput == true,
                       "Selectable document text alone must not authorize replacement")
        let unchangedText = try await fixture.currentText()
        XCTAssertEqual(unchangedText, original)
    }

    private func requireTrustedFixtureHost() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Live WebKit AX coverage requires a trusted GUI test host; this XCTest process is untrusted, and the suite never requests permission.")
        }
    }
}

@MainActor
private final class OwnedRichEditorFixture: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private let html: String
    private let readOnly: Bool
    private let designMode: Bool
    private var loaded = false
    private var navigationError: Error?
    private static let label = "Bean owned rich editor fixture"
    private static var applicationPrepared = false

    init(text: String, readOnly: Bool, designMode: Bool = false) {
        let application = NSApplication.shared
        if !Self.applicationPrepared {
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            Self.applicationPrepared = true
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 150), configuration: configuration)
        window = NSPanel(contentRect: NSRect(x: 80, y: 80, width: 600, height: 150),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Bean owned integration fixture"
        window.contentView = webView
        self.readOnly = readOnly
        self.designMode = designMode
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let control = designMode ? escaped : readOnly
            ? "<textarea id='editor' readonly aria-label='\(Self.label)'>\(escaped)</textarea>"
            : "<div id='editor' contenteditable='true' role='textbox' aria-multiline='true' aria-label='\(Self.label)'>\(escaped)</div>"
        html = "<!doctype html><html><head><meta charset='utf-8'><style>body{margin:16px;font:16px sans-serif}#editor{min-height:80px;width:540px;white-space:pre-wrap}</style></head><body>\(control)</body></html>"
        super.init()
        webView.navigationDelegate = self
    }

    func load() async throws {
        window.orderFront(nil)
        webView.loadHTMLString(html, baseURL: nil)
        for _ in 0..<160 {
            if let navigationError { throw navigationError }
            if loaded {
                if designMode { _ = try await webView.evaluateJavaScript("document.designMode='on';true") }
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FixtureError.loadTimeout
    }

    func select(start: Int, length: Int) async throws {
        let script: String
        if readOnly {
            script = "const e=document.getElementById('editor');e.focus();e.setSelectionRange(\(start),\(start + length));true"
        } else {
            let editor = designMode ? "document.body" : "document.getElementById('editor')"
            script = """
            const e=\(editor);e.focus();
            const r=document.createRange();r.setStart(e.firstChild,\(start));r.setEnd(e.firstChild,\(start + length));
            const s=window.getSelection();s.removeAllRanges();s.addRange(r);true
            """
        }
        _ = try await webView.evaluateJavaScript(script)
        // WebKit delivers its AX selection notification asynchronously.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func currentText() async throws -> String {
        let script = designMode ? "document.body.textContent" : readOnly ? "document.getElementById('editor').value" : "document.getElementById('editor').textContent"
        let result = try await webView.evaluateJavaScript(script)
        return try XCTUnwrap(result as? String)
    }

    func disableDocumentEditing() async throws {
        _ = try await webView.evaluateJavaScript("document.designMode='off';true")
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func accessibilityElement() async throws -> AXUIElement {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let label = Self.label
        let role = designMode ? "AXWebArea" : nil
        let probe = await Task.detached {
            OwnedAXProbe.find(label: label, role: role, processIdentifier: ownPID)
        }.value
        if let element = probe.element { return element }
        if let error = probe.endpointError {
            throw XCTSkip("The owned test-process AX endpoint is unavailable (\(error.rawValue)); no Accessibility permission was requested.")
        }
        if probe.encounteredOtherProcess {
            throw XCTSkip("WebKit exposes the fixture through a separate process; this suite permits only test-process AX elements.")
        }
        if !probe.exposedWebContent {
            throw XCTSkip("The own-process AppKit AX endpoint responds, but this XCTest host does not expose WKWebView AXWebArea content. Live marker behavior was not exercised.")
        }
        throw FixtureError.missingEditor
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }

    private enum FixtureError: Error { case loadTimeout, missingEditor }
}

/// All AX calls stay inside the synthetic fixture's process. WebKit remote
/// references, if present, are declined before reading their UI attributes.
private enum OwnedAXProbe {
    struct Result {
        let element: AXUIElement?
        let endpointError: AXError?
        let encounteredOtherProcess: Bool
        let exposedWebContent: Bool
    }

    static func find(label: String, role: String?, processIdentifier: pid_t) -> Result {
        let root = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var queue = [root]
        var visited = 0
        var encounteredOtherProcess = false
        var exposedWebContent = false
        var seen: [AXUIElement] = []
        while !queue.isEmpty, visited < 160 {
            let element = queue.removeFirst()
            if seen.contains(where: { CFEqual($0, element) }) { continue }
            seen.append(element)
            visited += 1
            var elementPID: pid_t = 0
            guard AXUIElementGetPid(element, &elementPID) == .success,
                  elementPID == processIdentifier else {
                encounteredOtherProcess = true
                continue
            }
            AXUIElementSetMessagingTimeout(element, 0.2)
            var roleValue: AnyObject?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            if roleValue as? String == "AXWebArea" { exposedWebContent = true }
            if let role, roleValue as? String == role {
                return Result(element: element, endpointError: nil, encounteredOtherProcess: encounteredOtherProcess, exposedWebContent: exposedWebContent)
            }
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   value as? String == label {
                    return Result(element: element, endpointError: nil, encounteredOtherProcess: encounteredOtherProcess, exposedWebContent: exposedWebContent)
                }
            }
            var children: AnyObject?
            let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            if visited == 1 {
                var windows: AnyObject?
                let windowStatus = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
                if let windowElements = windows as? [AXUIElement] { queue += windowElements }
                if windowStatus != .success, status != .success {
                    return Result(element: nil, endpointError: status, encounteredOtherProcess: false, exposedWebContent: false)
                }
            }
            if let childElements = children as? [AXUIElement] { queue += childElements }
        }
        return Result(element: nil, endpointError: nil, encounteredOtherProcess: encounteredOtherProcess, exposedWebContent: exposedWebContent)
    }
}
