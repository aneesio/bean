import AppKit
import WebKit
import XCTest

/// Real production CSS/DOM render in an owned, synthetic, network-free editor.
/// The fixture retains its own closed shadow root solely to measure geometry.
/// It invokes the existing focus helper rather than fabricating trusted input;
/// these renders do not certify a browser's keyboard/accessibility transport.
@MainActor
final class OwnedBrowserOverlayVisualTests: XCTestCase {
    func testProductionAssistantAndSuggestionCardsFitRealViewportAndExportSnapshots() async throws {
        let output = ProcessInfo.processInfo.environment["BEAN_BROWSER_QA_OUTPUT_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for dark in [false, true] {
            for (sizeName, size) in [("desktop", NSSize(width: 800, height: 640)),
                                     ("narrow", NSSize(width: 320, height: 480))] {
                let fixture = try OwnedBrowserOverlayFixture(size: size, dark: dark)
                defer { fixture.close() }
                try await fixture.load()
                for state in ["draft", "selection", "suggestion"] {
                    let rendered = try await fixture.object("""
                        BeanOverlay.clear();BeanOverlay.clearAssistant();
                        const editor=document.getElementById('editor');editor.focus();
                        const r=editor.getBoundingClientRect(),rect={x:r.x,y:r.y,w:r.width,h:r.height};
                        const handlers={actionScope:'\(state == "selection" ? "selection" : "draft")',safeFixCount:2,
                            learnWordAvailable:true,onPrepareActions:()=>handlers.actionScope};
                        BeanOverlay.renderAssistant(rect,3,'nativeLocal',handlers);
                        const passivePreserved=document.activeElement===editor;
                        if('\(state)'==='suggestion') {
                            BeanOverlay.render([{id:'synthetic',rects:[{x:r.x+12,y:r.y+30,w:35,h:18}],
                                issue:{original:'recieved',suggestion:'received',type:'spelling',source:'local',
                                    alternatives:['received','receiver','receive','receiving'],
                                    explanation:'This spelling suggestion needs your choice.'}}],
                                'synthetic',{index:0,total:3},handlers);
                        } else {
                            // Non-mutating dialog opening only. Production contentScript
                            // remains responsible for isTrusted on every writing action.
                            window.__ownedBeanShadow.querySelector('[data-bean-assistant]').dispatchEvent(
                                new MouseEvent('click',{bubbles:true,detail:1}));
                        }
                        return {passivePreserved,dark:matchMedia('(prefers-color-scheme:dark)').matches};
                        """)
                    XCTAssertEqual(rendered["passivePreserved"] as? Bool, true, "Passive badge must retain editor focus")
                    XCTAssertEqual(rendered["dark"] as? Bool, dark, "Snapshot must use the actual production color-scheme media query")
                    let geometry = try await fixture.geometry(selection: state == "selection")
                    let name = "\(state)-\(sizeName)-\(dark ? "dark" : "light")"
                    if let output { try await fixture.snapshot(to: output.appendingPathComponent(name + ".png")) }
                    XCTAssertEqual(geometry["cardsFit"] as? Bool, true, "\(name): \(geometry)")
                    XCTAssertEqual(geometry["controlsFit"] as? Bool, true, "\(name): \(geometry)")
                    XCTAssertEqual(geometry["controlsInsideCards"] as? Bool, true, "\(name): \(geometry)")
                    XCTAssertEqual(geometry["scopeVisibilityMatchesSelection"] as? Bool, true, "\(name): \(geometry)")
                    XCTAssertEqual(geometry["officialMarkLoaded"] as? Bool, true)
                    print("OWNED_BROWSER_OVERLAY_GEOMETRY \(name) \(geometry)")
                }
            }
        }
    }

    func testProductionFocusHelperEntersAndPreservesSemanticControlOnRealDOM() async throws {
        let fixture = try OwnedBrowserOverlayFixture(size: NSSize(width: 800, height: 640), dark: false)
        defer { fixture.close() }
        try await fixture.load()
        _ = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();
            const r=e.getBoundingClientRect(),rect={x:r.x,y:r.y,w:r.width,h:r.height};
            BeanOverlay.renderAssistant(rect,0,'nativeLocal',{actionScope:'draft'});
            return {entered:BeanOverlay.focusFirstControl()};
            """)
        let entered = try await fixture.object("""
            const root=window.__ownedBeanShadow;
            const entryFocused=root.activeElement===root.querySelector('[data-bean-assistant]');
            // A hidden fixture has no presentation-driven animation frame.
            // Run the production helper's queued frame locally; this tests its
            // real focus target without asserting native keyboard transport.
            const originalFrame=window.requestAnimationFrame,frames=[];
            window.requestAnimationFrame=(callback)=>{frames.push(callback);return frames.length;};
            BeanOverlay._test.queueKeyboardActivationFocus();
            root.querySelector('[data-bean-assistant]').dispatchEvent(new MouseEvent('click',{bubbles:true,detail:0}));
            window.requestAnimationFrame=originalFrame;
            frames.forEach(callback=>callback(0));
            return {entryFocused};
            """)
        XCTAssertEqual(entered["entryFocused"] as? Bool, true)
        try await Task.sleep(nanoseconds: 60_000_000)
        let focused = try await fixture.object("""
            const root=window.__ownedBeanShadow;
            const proofread=root.querySelector('[data-act="proofread"]');
            const onProofread=root.activeElement===proofread;
            const e=document.getElementById('editor'),r=e.getBoundingClientRect();
            const rect={x:r.x,y:r.y,w:r.width,h:r.height};
            const originalFrame=window.requestAnimationFrame,frames=[];
            window.requestAnimationFrame=(callback)=>{frames.push(callback);return frames.length;};
            // Mirror the normal contentScript overlay update after a check.
            BeanOverlay.render([],null,null,{});BeanOverlay.renderGroups([],null,{});
            BeanOverlay.renderAssistant(rect,1,'nativeLocal',{actionScope:'draft'});
            window.requestAnimationFrame=originalFrame;frames.forEach(callback=>callback(0));
            const updatedProofread=root.querySelector('[data-act="proofread"]');
            return {onProofread,focusPreservedAfterRender:!!updatedProofread && root.activeElement===updatedProofread,
                hasControls:BeanOverlay.hasKeyboardControls(),sourceUntouched:document.getElementById('editor').value==='Synthetic draft with teh spelling issue.'};
            """)
        XCTAssertEqual(focused["onProofread"] as? Bool, true)
        XCTAssertEqual(focused["focusPreservedAfterRender"] as? Bool, true)
        XCTAssertEqual(focused["hasControls"] as? Bool, true)
        XCTAssertEqual(focused["sourceUntouched"] as? Bool, true)
    }

    func testShortViewportScrollsBoundedLongSuggestionsAndKeepsEveryActionReachable() async throws {
        let fixture = try OwnedBrowserOverlayFixture(size: NSSize(width: 320, height: 240), dark: false)
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();const r=e.getBoundingClientRect();
            const handlers={learnWordAvailable:true};
            const entry={id:'long-synthetic',rects:[{x:r.x+10,y:r.y+30,w:40,h:18}],
                issue:{original:'a'.repeat(180),suggestion:'b'.repeat(200),source:'local',type:'spelling',
                    alternatives:['c'.repeat(200),'d'.repeat(200),'e'.repeat(200),'f'.repeat(200)],
                    explanation:'This possible spelling issue has several choices. Review the word in its context before accepting a correction.'}};
            BeanOverlay.render([entry],entry.id,{index:0,total:3},handlers);
            const root=window.__ownedBeanShadow,card=root.querySelector('.card');
            const initial=card.getBoundingClientRect(),buttons=[...card.querySelectorAll('button')].filter(b=>b.getClientRects().length);
            const fit=r=>r.x>=-1 && r.y>=-1 && r.right<=innerWidth+1 && r.bottom<=innerHeight+1;
            const results=buttons.map(button=>{
                button.focus();button.scrollIntoView({block:'nearest',inline:'nearest'});
                const rect=button.getBoundingClientRect(),owner=card.getBoundingClientRect();
                return {focused:root.activeElement===button,fits:fit(rect) && rect.x>=owner.x-1 &&
                    rect.y>=owner.y-1 && rect.right<=owner.right+1 && rect.bottom<=owner.bottom+1};
            });
            card.scrollTop=0;
            return {cardFit:fit(initial),scrollable:card.scrollHeight>card.clientHeight,
                boundedHeight:initial.height<=innerHeight-16+1,actions:results.length,
                allActionsReachable:results.every(r=>r.focused && r.fits),sourceUntouched:e.value==='Synthetic draft with teh spelling issue.'};
            """)
        XCTAssertEqual(result["cardFit"] as? Bool, true)
        XCTAssertEqual(result["scrollable"] as? Bool, true)
        XCTAssertEqual(result["boundedHeight"] as? Bool, true)
        XCTAssertGreaterThan(result["actions"] as? Int ?? 0, 7)
        XCTAssertEqual(result["allActionsReachable"] as? Bool, true)
        XCTAssertEqual(result["sourceUntouched"] as? Bool, true)
        if let directory = ProcessInfo.processInfo.environment["BEAN_BROWSER_QA_OUTPUT_DIRECTORY"] {
            try await fixture.snapshot(to: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("long-suggestion-short-light.png"))
        }
    }
}

@MainActor
private final class OwnedBrowserOverlayFixture: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private let source: String
    private let iconDataURL: String
    private var loaded = false
    private var navigationError: Error?

    init(size: NSSize, dark: Bool) throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.appearance = appearance
        webView.appearance = appearance
        window.contentView = webView
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        source = try String(contentsOf: root.appendingPathComponent("BrowserExtension/src/overlay.js"), encoding: .utf8)
        iconDataURL = "data:image/png;base64," + (try Data(contentsOf: root.appendingPathComponent("BrowserExtension/icon128.png"))).base64EncodedString()
        super.init()
        webView.navigationDelegate = self
    }

    func load() async throws {
        let html = """
            <!doctype html><html><head><meta charset='utf-8'><meta name='color-scheme' content='light dark'>
            <style>html,body{margin:0;min-height:100%;font:14px -apple-system,sans-serif;background:#f7f6f4;color:#252321}
            main{padding:16px}h1{font-size:16px;margin:0 0 14px}textarea{box-sizing:border-box;width:100%;height:110px;padding:12px;border:1px solid #c4bdb5;border-radius:10px;background:white;color:#252321;font:14px -apple-system,sans-serif;resize:none}
            @media(prefers-color-scheme:dark){html,body{background:#191817;color:#f2efeb}textarea{background:#242220;color:#f2efeb;border-color:#59514a}}</style></head>
            <body><main><h1>Owned browser assistant fixture</h1><textarea id='editor'>Synthetic draft with teh spelling issue.</textarea></main></body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
        for _ in 0..<160 {
            if let navigationError { throw navigationError }
            if loaded {
                let data = try JSONSerialization.data(withJSONObject: [iconDataURL])
                let quotedIcon = try XCTUnwrap(String(data: data, encoding: .utf8))
                _ = try await webView.evaluateJavaScript("""
                    (()=>{
                    window.chrome={runtime:{getURL:()=>\(quotedIcon)[0]}};
                    const originalAttachShadow=Element.prototype.attachShadow;
                    Element.prototype.attachShadow=function(options){const root=originalAttachShadow.call(this,options);window.__ownedBeanShadow=root;return root;};
                    })();
                    """)
                _ = try await webView.evaluateJavaScript(source)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FixtureError.loadTimeout
    }

    func object(_ body: String) async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript("(()=>{\(body)})()")
        return try XCTUnwrap(result as? [String: Any])
    }

    func geometry(selection: Bool) async throws -> [String: Any] {
        try await Task.sleep(nanoseconds: 50_000_000)
        return try await object("""
            const root=window.__ownedBeanShadow;
            const visible=(e)=>e.getClientRects().length && getComputedStyle(e).visibility!=='hidden';
            const rect=(e)=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,right:r.right,bottom:r.bottom};};
            const fit=(r)=>r.x>=-1 && r.y>=-1 && r.right<=innerWidth+1 && r.bottom<=innerHeight+1;
            const cards=[...root.querySelectorAll('.card')].filter(visible);
            const controls=[...root.querySelectorAll('button')].filter(visible);
            const mark=root.querySelector('.assistant img');
            const insideCard=(e)=>{const owner=e.closest('.card');if(!owner)return true;
                const c=rect(owner),r=rect(e);return r.x>=c.x-1 && r.y>=c.y-1 && r.right<=c.right+1 && r.bottom<=c.bottom+1;};
            const group=root.querySelector('.scope');
            return {viewport:{width:innerWidth,height:innerHeight},cards:cards.map(rect),
                cardsFit:cards.length>0 && cards.every(e=>fit(rect(e))),
                controlsFit:controls.every(e=>fit(rect(e))),
                controlsInsideCards:controls.every(insideCard),
                scopeVisibilityMatchesSelection:!group || (!!visible(group)===\(selection ? "false" : "true")),
                clippedControls:controls.filter(e=>!fit(rect(e))).map(e=>({label:e.textContent,rect:rect(e)})),
                protrudingControls:controls.filter(e=>!insideCard(e)).map(e=>({label:e.textContent,rect:rect(e)})),
                officialMarkLoaded:!!mark && mark.complete && mark.naturalWidth===128};
            """)
    }

    func snapshot(to path: URL) async throws {
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            webView.takeSnapshot(with: nil) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: FixtureError.snapshotUnavailable) }
            }
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }

    func close() { webView.stopLoading(); webView.navigationDelegate = nil; window.close() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }
    private enum FixtureError: Error { case loadTimeout, snapshotUnavailable }
}
