import AppKit
import WebKit
import XCTest

/// Real production CSS/DOM render in an owned, synthetic, network-free editor.
/// The fixture retains its own closed shadow root solely to measure geometry.
/// It invokes the existing focus helper rather than fabricating trusted input;
/// these renders do not certify a browser's keyboard/accessibility transport.
@MainActor
final class OwnedBrowserOverlayVisualTests: XCTestCase {
    func testIssueDotHasDistinctRedAndExclamationInBothAppearancesAndTargetSizes() async throws {
        for dark in [false, true] {
            for compact in [false, true] {
                let fixture = try OwnedBrowserOverlayFixture(size: NSSize(width: 800, height: 640), dark: dark)
                defer { fixture.close() }
                try await fixture.load()
                let neutral = try await fixture.object("""
                    let editor=document.getElementById('editor');
                    if(\(compact ? "true" : "false")) {
                        const input=document.createElement('input');input.id='editor';editor.replaceWith(input);editor=input;
                        editor.style.cssText='position:fixed;left:32px;top:72px;width:280px;height:24px;box-sizing:border-box;padding:2px;border:1px solid #999;font:12px -apple-system,sans-serif';
                    }
                    editor.value='Short draft';editor.focus();
                    const r=editor.getBoundingClientRect();
                    window.__ownedDotRender=(count)=>BeanOverlay.renderAssistant({x:r.x,y:r.y,w:r.width,h:r.height},count,'nativeLocal',{}, {source:editor});
                    window.__ownedDotMeasure=()=>{
                        const root=window.__ownedBeanShadow,button=root.querySelector('.assistant'),dot=root.querySelector('.assistant-dot');
                        const mark=dot.querySelector('.assistant-issue-mark'),d=dot.getBoundingClientRect(),m=mark.getBoundingClientRect(),b=button.getBoundingClientRect();
                        const style=getComputedStyle(dot),stem=getComputedStyle(mark,'::before'),point=getComputedStyle(mark,'::after');
                        const near=(actual,expected)=>Math.abs(actual-expected)<0.03;
                        return {dark:matchMedia('(prefers-color-scheme:dark)').matches,
                            sourceUntouched:document.activeElement===editor && editor.value==='Short draft',
                            dot10:d.width===10 && d.height===10,targetSize:b.width,targetSquare:b.width===b.height,
                            noLogoOrCount:button.children.length===1 && !button.querySelector('img') && button.textContent==='',
                            background:style.backgroundColor,markHidden:mark.hidden,markDisplay:getComputedStyle(mark).display,
                            markAriaHidden:mark.getAttribute('aria-hidden')==='true',label:button.getAttribute('aria-label'),
                            markInside:m.left>=d.left && m.right<=d.right && m.top>=d.top && m.bottom<=d.bottom,
                            markCentered:near(m.x+m.width/2,d.x+d.width/2) && near(m.y+m.height/2,d.y+d.height/2),
                            markCenterOffset:{x:m.x+m.width/2-d.x-d.width/2,y:m.y+m.height/2-d.y-d.height/2},
                            markSize:near(m.width,1.4) && near(m.height,5.4),
                            stemSize:near(parseFloat(stem.width),1.4) && near(parseFloat(stem.height),3.2),
                            pointSize:near(parseFloat(point.width),1.4) && near(parseFloat(point.height),1.4),
                            markColor:stem.backgroundColor,pointColor:point.backgroundColor,
                            buttonRetained:window.__ownedDotButton===undefined || window.__ownedDotButton===button};
                    };
                    window.__ownedDotRender(0);window.__ownedDotButton=window.__ownedBeanShadow.querySelector('.assistant');
                    return window.__ownedDotMeasure();
                    """)
                XCTAssertEqual(neutral["dark"] as? Bool, dark)
                XCTAssertEqual(neutral["background"] as? String, dark ? "rgb(224, 161, 94)" : "rgb(138, 76, 23)")
                XCTAssertEqual(neutral["markHidden"] as? Bool, true)
                XCTAssertEqual(neutral["markDisplay"] as? String, "none")
                let name = "dot-contrast-\(compact ? "compact" : "regular")-\(dark ? "dark" : "light")"
                if let directory = ProcessInfo.processInfo.environment["BEAN_BROWSER_QA_OUTPUT_DIRECTORY"] {
                    try await fixture.snapshot(to: URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(name + "-neutral.png"))
                }
                let issue = try await fixture.object("""
                    window.__ownedDotRender(2);return window.__ownedDotMeasure();
                    """)
                XCTAssertEqual(issue["background"] as? String, dark ? "rgb(255, 107, 107)" : "rgb(217, 45, 32)")
                XCTAssertNotEqual(issue["background"] as? String, neutral["background"] as? String)
                XCTAssertEqual(issue["markHidden"] as? Bool, false)
                XCTAssertEqual(issue["markDisplay"] as? String, "block")
                XCTAssertEqual(issue["markColor"] as? String, dark ? "rgb(36, 18, 15)" : "rgb(255, 255, 255)")
                XCTAssertEqual(issue["pointColor"] as? String, issue["markColor"] as? String)
                XCTAssertTrue((issue["label"] as? String ?? "").contains("2 writing suggestions"))
                for key in ["sourceUntouched", "dot10", "targetSquare", "noLogoOrCount", "markAriaHidden",
                            "markInside", "markCentered", "markSize", "stemSize", "pointSize", "buttonRetained"] {
                    XCTAssertEqual(issue[key] as? Bool, true, "\(name): \(key) \(issue)")
                }
                XCTAssertEqual(issue["targetSize"] as? Int, compact ? 20 : 28)
                XCTAssertEqual(neutral["targetSize"] as? Int, compact ? 20 : 28)
                if let directory = ProcessInfo.processInfo.environment["BEAN_BROWSER_QA_OUTPUT_DIRECTORY"] {
                    try await fixture.snapshot(to: URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(name + "-issues.png"))
                }
                let cleared = try await fixture.object("""
                    window.__ownedDotRender(0);return window.__ownedDotMeasure();
                    """)
                XCTAssertEqual(cleared["background"] as? String, neutral["background"] as? String)
                XCTAssertEqual(cleared["markHidden"] as? Bool, true)
                XCTAssertEqual(cleared["buttonRetained"] as? Bool, true)
                XCTAssertEqual(cleared["sourceUntouched"] as? Bool, true)
            }
        }
    }

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
                        BeanOverlay.renderAssistant(rect,3,'nativeLocal',handlers,{source:editor});
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
                    XCTAssertEqual(geometry["compactDotMeasured"] as? Bool, true)
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
            BeanOverlay.renderAssistant(rect,0,'nativeLocal',{actionScope:'draft'},{source:e});
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
            BeanOverlay.renderAssistant(rect,1,'nativeLocal',{actionScope:'draft'},{source:e});
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

    func testInsideDotKeepsComposerControlsClickableAndRecoversAcrossViewportChanges() async throws {
        for dark in [false, true] {
            for (name, size) in [("desktop", NSSize(width: 800, height: 640)),
                                  ("narrow", NSSize(width: 320, height: 480))] {
                let fixture = try OwnedBrowserOverlayFixture(size: size, dark: dark)
                defer { fixture.close() }
                try await fixture.load()
                let result = try await fixture.object("""
                    const e=document.getElementById('editor');
                    e.style.cssText=`position:fixed;left:32px;top:72px;width:${Math.min(280,innerWidth-64)}px;height:150px;resize:none`;
                    e.value='Short draft';e.focus();e.setSelectionRange(4,4);
                    const r=e.getBoundingClientRect(),rect={x:r.x,y:r.y,w:r.width,h:r.height};
                    const overlap=(a,c)=>a.left<c.right && a.right>c.left && a.top<c.bottom && a.bottom>c.top;
                    const inside=(a,c)=>a.left>=c.left && a.right<=c.right && a.top>=c.top && a.bottom<=c.bottom;
                    window.__dotControlClicks={};
                    const controls=['Send','Attach','Microphone'].map((label,index)=>{
                        const button=document.createElement('button');button.textContent=label;button.id='owned-'+label;
                        button.style.cssText=`position:fixed;left:${r.right-32-index*36}px;top:${r.bottom-32}px;width:28px;height:28px;padding:0;overflow:hidden`;
                        button.addEventListener('click',()=>window.__dotControlClicks[label]=(window.__dotControlClicks[label]||0)+1);
                        document.body.appendChild(button);return button;
                    });
                    const shown=BeanOverlay.renderAssistant(rect,3,'nativeLocal',{}, {source:e});
                    const root=window.__ownedBeanShadow,button=root.querySelector('.assistant'),dot=root.querySelector('.assistant-dot');
                    const b=button.getBoundingClientRect(),d=dot.getBoundingClientRect();
                    const topRight=Math.abs(b.right-(r.right-4))<0.5 && Math.abs(b.top-(r.top+4))<0.5;
                    const controlsUntouched=controls.every(control=>{
                        const c=control.getBoundingClientRect(),hit=document.elementFromPoint(c.x+c.width/2,c.y+c.height/2);
                        if(hit!==control)return false;
                        hit.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));return window.__dotControlClicks[control.textContent]===1;
                    });
                    const host=document.getElementById('bean-inline-host');
                    const dotOwnsPixels=[1,14,27].every(dx=>[1,14,27].every(dy=>document.elementFromPoint(b.x+dx,b.y+dy)===host));
                    button.dispatchEvent(new MouseEvent('mouseenter',{bubbles:false}));
                    const hoverQuiet=!root.querySelector('.card') && document.activeElement===e && e.selectionStart===4;
                    button.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));
                    const clickOpens=!!root.querySelector('[aria-label="Bean writing assistant"]');
                    root.querySelector('[aria-label="Close writing assistant"]').dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));
                    const thin=document.createElement('button');thin.id='owned-thin-control';
                    thin.style.cssText=`position:fixed;left:${b.x+6}px;top:${b.y+5}px;width:1px;height:1px;padding:0;border:0;background:red`;
                    document.body.appendChild(thin);
                    const moved=BeanOverlay.refreshAssistantPlacement(),after=root.querySelector('.assistant').getBoundingClientRect();
                    const thinExcluded=moved && !overlap(after,thin.getBoundingClientRect()) && inside(after,r);
                    document.querySelectorAll('[id^="owned-"]').forEach(node=>node.remove());
                    e.style.cssText=`position:fixed;left:4px;top:4px;width:${innerWidth-8}px;height:${innerHeight-8}px;resize:none`;
                    const fillsViewportShown=BeanOverlay.refreshAssistantPlacement();
                    e.style.left='1200px';BeanOverlay.refreshAssistantPlacement();const offscreenHidden=!root.querySelector('.assistant');
                    e.style.left='4px';const recovered=BeanOverlay.refreshAssistantPlacement();
                    return {shown,topRight,insideEditor:inside(b,r),paint10:d.width===10 && d.height===10,target28:b.width===28 && b.height===28,
                        noLogoOrCount:button.children.length===1 && !button.querySelector('img'),hasIssues:button.dataset.hasIssues==='true',
                        outsideControls:controls.every(control=>!overlap(b,control.getBoundingClientRect())),controlsUntouched,dotOwnsPixels,
                        hoverQuiet,clickOpens,thinExcluded,fillsViewportShown,offscreenHidden,recovered,
                        sourceUntouched:e.value==='Short draft' && e.selectionStart===4};
                    """)
                for key in ["shown", "topRight", "insideEditor", "paint10", "target28", "noLogoOrCount", "hasIssues",
                            "outsideControls", "controlsUntouched", "dotOwnsPixels", "hoverQuiet", "clickOpens", "thinExcluded",
                            "fillsViewportShown", "offscreenHidden", "recovered", "sourceUntouched"] {
                    XCTAssertEqual(result[key] as? Bool, true, "\(name) \(dark): \(key) \(result)")
                }
                if let directory = ProcessInfo.processInfo.environment["BEAN_BROWSER_QA_OUTPUT_DIRECTORY"] {
                    try await fixture.snapshot(to: URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("dot-inside-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    func testInsideTextGeometryProtectsAlignedRTLPlaceholderScrolledAndCompactInputs() async throws {
        let fixture = try OwnedBrowserOverlayFixture(size: NSSize(width: 800, height: 640), dark: false)
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');let root=null;
            e.style.cssText='position:fixed;left:100px;top:100px;width:260px;height:160px;resize:none;text-align:right';
            e.value='Right aligned';e.focus();e.setSelectionRange(e.value.length,e.value.length);
            const overlap=(a,c)=>a.left<c.x+c.w && a.right>c.x && a.top<c.y+c.h && a.bottom>c.y;
            const safe=()=>{
                const r=e.getBoundingClientRect(),shown=BeanOverlay.renderAssistant({x:r.x,y:r.y,w:r.width,h:r.height},0,'nativeLocal',{}, {source:e});
                root=window.__ownedBeanShadow;const button=root && root.querySelector('.assistant');if(!shown || !button)return false;
                const text=BeanMapping.rectsForRange(e,0,e.value.length),b=button.getBoundingClientRect();
                return b.left>=r.left && b.right<=r.right && b.top>=r.top && b.bottom<=r.bottom && text.every(box=>!overlap(b,box));
            };
            const aligned=safe();
            e.style.direction='rtl';e.value='مرحبا بالعالم';e.setSelectionRange(e.value.length,e.value.length);const rtl=safe();
            e.style.direction='ltr';e.style.textAlign='';
            const externalStyle=document.createElement('style');externalStyle.textContent='#editor{text-align:right;direction:rtl;tab-size:8}';document.head.appendChild(externalStyle);
            e.value='';e.placeholder='Right aligned placeholder';const placeholder=safe();
            const textControl=e.cloneNode(false);textControl.style.visibility='hidden';textControl.value=e.placeholder;document.body.appendChild(textControl);
            const placeholderRects=BeanMapping.rectsForRange(textControl,0,textControl.value.length),placeholderTarget=root.querySelector('.assistant').getBoundingClientRect();
            const placeholderActuallyExcluded=placeholderRects.every(box=>!overlap(placeholderTarget,box));textControl.remove();externalStyle.remove();
            e.placeholder='';e.style.textAlign='left';e.value=('A long line of text filling the first row. ').repeat(40)+'\\nshort\\nshort\\nshort';
            e.scrollTop=e.scrollHeight;e.setSelectionRange(e.value.length,e.value.length);const scrolled=safe();
            e.value='';e.scrollTop=0;const empty=safe();
            const b=root.querySelector('.assistant').getBoundingClientRect(),r=e.getBoundingClientRect();
            const emptyTopRight=Math.abs(b.top-r.top-4)<0.5 && Math.abs(r.right-b.right-4)<0.5;
            const input=document.createElement('input');input.style.cssText='position:fixed;left:100px;top:320px;width:260px;height:24px;box-sizing:border-box;padding:2px;border:1px solid #999;font:12px -apple-system,sans-serif';
            input.value='Short';document.body.appendChild(input);input.focus();input.setSelectionRange(5,5);
            const i=input.getBoundingClientRect(),compactShown=BeanOverlay.renderAssistant({x:i.x,y:i.y,w:i.width,h:i.height},0,'nativeLocal',{}, {source:input});
            const compact=root.querySelector('.assistant').getBoundingClientRect();
            const compact20=compactShown && compact.width===20 && compact.height===20 && compact.top>=i.top && compact.bottom<=i.bottom;
            const brown=getComputedStyle(root.querySelector('.assistant-dot')).backgroundColor===getComputedStyle(root.querySelector('.assistant')).color;
            const valuePreserved=input.value==='Short' && input.selectionStart===5 && e.value==='';
            return {aligned,rtl,placeholder,placeholderActuallyExcluded,scrolled,empty,emptyTopRight,compact20,brown,valuePreserved};
            """)
        for key in ["aligned", "rtl", "placeholder", "placeholderActuallyExcluded", "scrolled", "empty", "emptyTopRight", "compact20", "brown", "valuePreserved"] {
            XCTAssertEqual(result[key] as? Bool, true, "\(key): \(result)")
        }
    }

    func testContentEditableTextRangesAndLocalControlsIgnoreUnrelatedDocumentComplexity() async throws {
        let fixture = try OwnedBrowserOverlayFixture(size: NSSize(width: 800, height: 640), dark: false)
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            document.getElementById('editor').remove();
            const editor=document.createElement('div');editor.contentEditable='true';editor.id='editor';
            editor.style.cssText='position:fixed;left:100px;top:100px;width:300px;height:200px;padding:8px;box-sizing:border-box;border:1px solid #aaa;background:white;font:14px -apple-system,sans-serif';
            editor.innerHTML='<p style="margin:0">The first line contains many words and must wrap.</p><p style="margin:0">Second line.</p>';
            document.body.appendChild(editor);editor.focus();
            const selection=window.getSelection(),caret=document.createRange();caret.selectNodeContents(editor);caret.collapse(false);selection.removeAllRanges();selection.addRange(caret);
            const overlap=(a,c)=>a.left<c.right && a.right>c.left && a.top<c.bottom && a.bottom>c.top;
            const render=()=>{const r=editor.getBoundingClientRect();return BeanOverlay.renderAssistant({x:r.x,y:r.y,w:r.width,h:r.height},0,'nativeLocal',{}, {source:editor});};
            const shown=render(),root=window.__ownedBeanShadow;
            // A range containing paragraph elements includes each block's full
            // layout box. Measure the actual owned text nodes independently so
            // blank space on a short line stays usable without covering glyphs.
            const glyphRects=[...editor.querySelectorAll('p')].flatMap(paragraph=>{
                const range=document.createRange();range.selectNodeContents(paragraph.firstChild);return [...range.getClientRects()];
            });
            const textExcluded=shown && glyphRects.length>0 && glyphRects.every(r=>!overlap(root.querySelector('.assistant').getBoundingClientRect(),r));
            const dot=root.querySelector('.assistant').getBoundingClientRect(),button=document.createElement('button');button.textContent='Send';
            button.style.cssText=`position:fixed;left:${dot.x}px;top:${dot.y}px;width:28px;height:28px;padding:0`;
            editor.appendChild(button);const moved=render();
            const controlExcluded=moved && !overlap(root.querySelector('.assistant').getBoundingClientRect(),button.getBoundingClientRect());
            const unrelated=document.createElement('bean-unrelated-feed');unrelated.style.cssText='position:fixed;left:0;top:0;width:8px;height:8px';
            for(let n=0;n<32;n++){const branch=document.createElement('div');branch.style.cssText='position:fixed;left:0;top:0;width:8px;height:8px';branch.innerHTML='<span>Far feed</span>'.repeat(32);unrelated.appendChild(branch);}
            unrelated.attachShadow({mode:'open'}).innerHTML='<button>Unrelated shadow control</button>';document.body.appendChild(unrelated);
            const unrelatedAllowed=render();
            const blanket=document.createElement('div');blanket.style.cssText='position:fixed;left:100px;top:100px;width:300px;height:200px;background:red;z-index:100';document.body.appendChild(blanket);
            const coveredHidden=!render() && !root.querySelector('.assistant');blanket.remove();const recovered=render();
            const host=document.createElement('div');document.body.appendChild(host);const shadow=host.attachShadow({mode:'open'});
            const inner=document.createElement('textarea');inner.style.cssText='position:fixed;left:450px;top:100px;width:250px;height:100px';shadow.appendChild(inner);
            const r=inner.getBoundingClientRect(),unknownSourceHidden=!BeanOverlay.renderAssistant({x:r.x,y:r.y,w:r.width,h:r.height},0,'nativeLocal',{}, {source:inner});
            return {shown,textExcluded,controlExcluded,unrelatedAllowed,coveredHidden,recovered,unknownSourceHidden,
                sourceUntouched:editor.querySelector('p').textContent==='The first line contains many words and must wrap.'};
            """)
        for key in ["shown", "textExcluded", "controlExcluded", "unrelatedAllowed", "coveredHidden", "recovered", "unknownSourceHidden", "sourceUntouched"] {
            XCTAssertEqual(result[key] as? Bool, true, "\(key): \(result)")
        }
    }

}

@MainActor
private final class OwnedBrowserOverlayFixture: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private let source: String
    private let mappingSource: String
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
        mappingSource = try String(contentsOf: root.appendingPathComponent("BrowserExtension/src/issueMapping.js"), encoding: .utf8)
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
                _ = try await webView.evaluateJavaScript(mappingSource)
                _ = try await webView.evaluateJavaScript(source)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FixtureError.loadTimeout
    }

    func object(_ body: String) async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript("(()=>{try{\(body)}catch(error){return {ownedFixtureJavaScriptError:String(error),ownedFixtureStack:error.stack || ''};}})()")
        let object = try XCTUnwrap(result as? [String: Any])
        if let error = object["ownedFixtureJavaScriptError"] as? String {
            XCTFail("Owned overlay fixture JavaScript: \(error) \(object["ownedFixtureStack"] ?? "")")
            throw FixtureError.javaScript(error)
        }
        return object
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
            const dot=root.querySelector('.assistant-dot'),entry=root.querySelector('.assistant');
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
                compactDotMeasured:!!dot && !!entry && rect(dot).width===10 && rect(dot).height===10 &&
                    rect(entry).width===28 && rect(entry).height===28 && !entry.querySelector('img') && entry.children.length===1};
            """)
    }

    func snapshot(to path: URL) async throws {
        // Every snapshot entry point owns its output directory; alphabetical
        // test order must not depend on the card fixture running first.
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            XCTFail("Owned snapshot output directory: \(path.lastPathComponent): \(error)")
            throw FixtureError.snapshotStage("output directory: \(path.lastPathComponent)", String(describing: error))
        }
        // This fixture is intentionally offscreen, where native RAF callbacks
        // may be suspended. WebKit's snapshot API incorporates pending updates.
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image: NSImage
        do {
            image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
                webView.takeSnapshot(with: configuration) { image, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: FixtureError.snapshotUnavailable) }
                }
            }
        } catch {
            XCTFail("Owned snapshot capture: \(path.lastPathComponent): \(error)")
            throw FixtureError.snapshotStage("capture: \(path.lastPathComponent)", String(describing: error))
        }
        do {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        } catch {
            XCTFail("Owned snapshot PNG export: \(path.lastPathComponent): \(error)")
            throw FixtureError.snapshotStage("PNG export: \(path.lastPathComponent)", String(describing: error))
        }
    }

    func close() { webView.stopLoading(); webView.navigationDelegate = nil; window.close() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }
    private enum FixtureError: Error { case loadTimeout, snapshotUnavailable, javaScript(String), snapshotStage(String, String) }
}
