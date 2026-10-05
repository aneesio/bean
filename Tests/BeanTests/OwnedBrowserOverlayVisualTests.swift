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

    func testCompactDotKeepsCrowdedComposerControlsClickableAndHidesWithoutSafeSpace() async throws {
        for dark in [false, true] {
            for (name, size) in [("desktop", NSSize(width: 800, height: 640)),
                                  ("narrow", NSSize(width: 320, height: 480))] {
                let fixture = try OwnedBrowserOverlayFixture(size: size, dark: dark)
                defer { fixture.close() }
                try await fixture.load()
                let crowded = try await fixture.object("""
                    const e=document.getElementById('editor');
                    e.style.cssText=`position:fixed;left:48px;top:72px;width:${Math.min(280,innerWidth-96)}px;height:110px;resize:none`;
                    e.focus();e.setSelectionRange(8,8);
                    const r=e.getBoundingClientRect(),rect={x:r.x,y:r.y,w:r.width,h:r.height};
                    const placements=[{x:r.right+4,y:r.bottom-28},{x:r.right-28,y:r.bottom+4},
                        {x:r.left-32,y:r.bottom-28}];
                    window.__dotControlClicks={};
                    const controls=['Send','Attach','Microphone'].map((label,index)=>{
                        const button=document.createElement('button');button.textContent=label;
                        button.setAttribute('aria-label',label);button.id='owned-'+label;
                        button.style.cssText=`position:fixed;left:${placements[index].x}px;top:${placements[index].y}px;width:28px;height:28px;padding:0;overflow:hidden`;
                        button.addEventListener('click',()=>window.__dotControlClicks[label]=(window.__dotControlClicks[label]||0)+1);
                        document.body.appendChild(button);return button;
                    });
                    const shown=BeanOverlay.renderAssistant(rect,3,'nativeLocal',{actionScope:'draft'},{source:e});
                    const root=window.__ownedBeanShadow,button=root.querySelector('.assistant'),dot=root.querySelector('.assistant-dot');
                    const b=button.getBoundingClientRect(),d=dot.getBoundingClientRect();
                    const overlap=(a,c)=>a.left<c.right && a.right>c.left && a.top<c.bottom && a.bottom>c.top;
                    const controlsUntouched=controls.every(control=>{
                        const c=control.getBoundingClientRect(),hit=document.elementFromPoint(c.x+c.width/2,c.y+c.height/2);
                        if(hit!==control)return false;
                        hit.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));return window.__dotControlClicks[control.textContent]===1;
                    });
                    // Hover gives details through the semantic title. It does
                    // not expand a card or move the editor's selection.
                    button.dispatchEvent(new MouseEvent('mouseenter',{bubbles:false}));
                    const hoverQuiet=!root.querySelector('.card') && document.activeElement===e && e.selectionStart===8;
                    const titleUseful=/Bean: 3 writing suggestions/.test(button.title);
                    // document hit testing retargets a closed-shadow control
                    // to its host. ShadowRoot.elementFromPoint is nonstandard
                    // and is not needed to prove this target owns the pixels.
                    const host=document.getElementById('bean-inline-host');
                    const hitSamples=[1,14,27].flatMap(dx=>[1,14,27].map(dy=>{
                        const hit=document.elementFromPoint(b.x+dx,b.y+dy);
                        return {dx,dy,owned:hit===host,tag:hit && hit.tagName,id:hit && hit.id};
                    }));
                    const dotHit=hitSamples.every(sample=>sample.owned);
                    button.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));
                    const clickOpens=!!root.querySelector('[aria-label="Bean writing assistant"]');
                    root.querySelector('[aria-label="Close writing assistant"]').dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));
                    // A one-pixel unknown sibling between the original hit
                    // samples still occupies the full invisible target.
                    const thin=document.createElement('div');thin.id='owned-thin-control';
                    thin.style.cssText=`position:fixed;left:${b.x+6}px;top:${b.y+5}px;width:1px;height:1px;background:red`;
                    document.body.appendChild(thin);
                    const moved=BeanOverlay.refreshAssistantPlacement();
                    const after=root.querySelector('.assistant').getBoundingClientRect();
                    return {shown,paint10:d.width===10 && d.height===10,target28:b.width===28 && b.height===28,
                        noLogoOrCount:button.children.length===1 && !button.querySelector('img'),amber:button.dataset.hasIssues==='true',
                        outsideEditor:!overlap(b,r),outsideControls:controls.every(control=>!overlap(b,control.getBoundingClientRect())),
                        controlsUntouched,hoverQuiet,titleUseful,dotHit,hitSamples,clickOpens,
                        movedAwayFromThin:moved && !overlap(after,thin.getBoundingClientRect()),
                        sourceUntouched:e.value==='Synthetic draft with teh spelling issue.' && e.selectionStart===8};
                    """)
                for key in ["shown", "paint10", "target28", "noLogoOrCount", "amber", "outsideEditor",
                            "outsideControls", "controlsUntouched", "hoverQuiet", "titleUseful", "dotHit", "clickOpens",
                            "movedAwayFromThin", "sourceUntouched"] {
                    XCTAssertEqual(crowded[key] as? Bool, true, "\(name) \(dark): \(key) \(crowded)")
                }
                if let directory = ProcessInfo.processInfo.environment["BEAN_BROWSER_QA_OUTPUT_DIRECTORY"] {
                    try await fixture.snapshot(to: URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("dot-crowded-\(name)-\(dark ? "dark" : "light").png"))
                }
                let unavailable = try await fixture.object("""
                    const e=document.getElementById('editor'),root=window.__ownedBeanShadow;
                    document.querySelectorAll('[id^="owned-"]').forEach(node=>node.remove());
                    e.style.cssText=`position:fixed;left:4px;top:4px;width:${innerWidth-8}px;height:${innerHeight-8}px;resize:none`;
                    const r=e.getBoundingClientRect(),rect={x:r.x,y:r.y,w:r.width,h:r.height};
                    const hidden=BeanOverlay.renderAssistant(rect,0,'nativeLocal',{}, {source:e})===false && !root.querySelector('.assistant');
                    BeanOverlay.render([{id:'owned-issue',rects:[{x:16,y:30,w:35,h:18}],
                        issue:{original:'teh',suggestion:'the',type:'spelling',source:'local'}}],null,null,{});
                    const underlineOwned=BeanOverlay.hasFieldPresentation() && !!root.querySelector('.ul');
                    BeanOverlay.clear();const noFalseOwnership=!BeanOverlay.hasFieldPresentation();
                    e.style.cssText='position:fixed;left:48px;top:72px;width:180px;height:110px;resize:none';
                    const restored=BeanOverlay.refreshAssistantPlacement();
                    const brandBrown=root.querySelector('.assistant').dataset.hasIssues==='false' &&
                        getComputedStyle(root.querySelector('.assistant-dot')).backgroundColor===getComputedStyle(root.querySelector('.assistant')).color &&
                        getComputedStyle(root.querySelector('.assistant-dot')).backgroundColor!=='rgba(0, 0, 0, 0)';
                    e.style.left='1200px';BeanOverlay.refreshAssistantPlacement();
                    const offscreenHidden=!root.querySelector('.assistant');
                    e.style.left='48px';const recovered=BeanOverlay.refreshAssistantPlacement();
                    const host=document.createElement('div');document.body.appendChild(host);
                    const shadow=host.attachShadow({mode:'open'}),shadowEditor=document.createElement('textarea');
                    shadowEditor.style.cssText='position:fixed;left:48px;top:72px;width:180px;height:110px';
                    shadow.appendChild(shadowEditor);
                    const shadowSend=document.createElement('button');shadowSend.textContent='Send';
                    shadowSend.style.cssText='position:fixed;left:232px;top:154px;width:28px;height:28px';shadow.appendChild(shadowSend);
                    const s=shadowEditor.getBoundingClientRect();
                    const unknownShadowHidden=BeanOverlay.renderAssistant({x:s.x,y:s.y,w:s.width,h:s.height},1,'nativeLocal',{},
                        {source:shadowEditor})===false && !root.querySelector('.assistant');
                    return {hidden,underlineOwned,noFalseOwnership,restored,brandBrown,offscreenHidden,recovered,unknownShadowHidden,
                        sourceUntouched:e.value==='Synthetic draft with teh spelling issue.'};
                    """)
                for key in ["hidden", "underlineOwned", "noFalseOwnership", "restored", "brandBrown",
                            "offscreenHidden", "recovered", "unknownShadowHidden", "sourceUntouched"] {
                    XCTAssertEqual(unavailable[key] as? Bool, true, "\(name) \(dark): \(key) \(unavailable)")
                }
            }
        }
    }

    func testFullEditorEdgeAndBoundedWrapperTraversal() async throws {
        for dark in [false, true] {
            for (name, size) in [("desktop", NSSize(width: 800, height: 640)),
                                  ("narrow", NSSize(width: 320, height: 640))] {
                let fixture = try OwnedBrowserOverlayFixture(size: size, dark: dark)
                defer { fixture.close() }
                try await fixture.load()
                let result = try await fixture.object("""
                    const e=document.getElementById('editor');
                    e.style.cssText=`position:fixed;left:48px;top:72px;width:${Math.min(280,innerWidth-96)}px;height:440px;resize:none`;
                    e.focus();e.setSelectionRange(8,8);
                    const r=e.getBoundingClientRect(),rect={x:r.x,y:r.y,w:r.width,h:r.height};
                    const obstacles=[{x:r.right+4,y:200,w:28,h:r.bottom-200},
                        {x:r.left-32,y:r.top,w:28,h:r.height},{x:r.left,y:r.bottom+4,w:r.width,h:28},
                        {x:r.left,y:r.top-32,w:r.width,h:28}].map((bounds,index)=>{
                        const button=document.createElement('button');button.textContent=index===0?'Send':'Toolbar';
                        button.style.cssText=`position:fixed;left:${bounds.x}px;top:${bounds.y}px;width:${bounds.w}px;height:${bounds.h}px;padding:0;overflow:hidden`;
                        document.body.appendChild(button);return button;
                    });
                    const shown=BeanOverlay.renderAssistant(rect,0,'nativeLocal',{}, {source:e});
                    const root=window.__ownedBeanShadow,entry=root.querySelector('.assistant');
                    const b=entry.getBoundingClientRect(),dot=root.querySelector('.assistant-dot');
                    const overlap=(a,c)=>a.left<c.right && a.right>c.left && a.top<c.bottom && a.bottom>c.top;
                    const clearBeyond96=r.bottom-28-b.y>96 && !overlap(b,r) &&
                        obstacles.every(control=>!overlap(b,control.getBoundingClientRect()));
                    const brandPaint=getComputedStyle(dot).backgroundColor===getComputedStyle(entry).color &&
                        getComputedStyle(dot).backgroundColor!=='rgba(0, 0, 0, 0)' && dot.getBoundingClientRect().width===10;
                    const backdrop=document.createElement('div');backdrop.style.cssText='position:fixed;inset:0;pointer-events:none';
                    const hidden=document.createElement('div');hidden.style.display='none';
                    hidden.innerHTML='<span></span>'.repeat(10000);backdrop.appendChild(hidden);document.body.appendChild(backdrop);
                    const backdropAllowed=BeanOverlay.refreshAssistantPlacement();
                    // pointer-events:none is not a child clipping guarantee.
                    // The child's own fixed box, beyond its wrapper's tiny box,
                    // remains an exclusion after pointer-events:auto overrides.
                    backdrop.style.cssText='position:fixed;left:0;top:0;width:1px;height:1px;pointer-events:none';
                    const escaped=document.createElement('button');escaped.textContent='Upload';
                    escaped.style.cssText=`position:fixed;left:${b.x}px;top:${b.y}px;width:28px;height:28px;pointer-events:auto`;
                    backdrop.appendChild(escaped);
                    const escapedChecked=BeanOverlay.refreshAssistantPlacement();
                    const after=root.querySelector('.assistant').getBoundingClientRect();
                    const escapedExcluded=escapedChecked && !overlap(after,escaped.getBoundingClientRect());
                    const boxless=document.createElement('div');boxless.style.display='contents';
                    const boxlessControl=document.createElement('button');boxlessControl.textContent='Voice';
                    boxlessControl.style.cssText=`position:fixed;left:${after.x}px;top:${after.y}px;width:28px;height:28px`;
                    boxless.appendChild(boxlessControl);document.body.appendChild(boxless);
                    const boxlessChecked=BeanOverlay.refreshAssistantPlacement();
                    const afterBoxless=root.querySelector('.assistant').getBoundingClientRect();
                    const boxlessExcluded=boxlessChecked && !overlap(afterBoxless,boxlessControl.getBoundingClientRect());
                    const contained=document.createElement('div');
                    contained.style.cssText='position:fixed;left:0;top:0;width:8px;height:640px;contain:paint';
                    contained.innerHTML='<span></span>'.repeat(10000);
                    const clippedChild=document.createElement('button');clippedChild.textContent='Clipped control';
                    clippedChild.style.cssText=`position:fixed;left:${afterBoxless.x}px;top:${afterBoxless.y}px;width:28px;height:28px`;
                    contained.appendChild(clippedChild);document.body.appendChild(contained);
                    const containedOverBudgetHidden=!BeanOverlay.refreshAssistantPlacement() && !root.querySelector('.assistant');
                    const c=clippedChild.getBoundingClientRect();
                    const clippedCannotHit=document.elementFromPoint(c.x+c.width/2,c.y+c.height/2)!==clippedChild;
                    contained.remove();
                    const restoredAfterLimit=BeanOverlay.refreshAssistantPlacement();
                    return {shown,clearBeyond96,brandPaint,backdropAllowed,escapedExcluded,boxlessExcluded,containedOverBudgetHidden,clippedCannotHit,restoredAfterLimit,
                        sourceUntouched:e.value==='Synthetic draft with teh spelling issue.' && e.selectionStart===8};
                    """)
                for key in ["shown", "clearBeyond96", "brandPaint", "backdropAllowed", "escapedExcluded",
                            "boxlessExcluded", "containedOverBudgetHidden", "clippedCannotHit", "restoredAfterLimit", "sourceUntouched"] {
                    XCTAssertEqual(result[key] as? Bool, true, "\(name) \(dark): \(key) \(result)")
                }
                if let directory = ProcessInfo.processInfo.environment["BEAN_BROWSER_QA_OUTPUT_DIRECTORY"] {
                    try await fixture.snapshot(to: URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("dot-full-edge-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    func testClippingDeclarationsDoNotHideEscapedControlGeometry() async throws {
        for dark in [false, true] {
            let fixture = try OwnedBrowserOverlayFixture(size: NSSize(width: 800, height: 480), dark: dark)
            defer { fixture.close() }
            try await fixture.load()
            let result = try await fixture.object("""
                const e=document.getElementById('editor');
                e.style.cssText='position:fixed;left:100px;top:100px;width:200px;height:160px;resize:none';
                e.focus();e.setSelectionRange(8,8);
                const r=e.getBoundingClientRect(),rect={x:r.x,y:r.y,w:r.width,h:r.height};
                BeanOverlay.renderAssistant(rect,0,'nativeLocal',{}, {source:e});
                const root=window.__ownedBeanShadow;
                const overlap=(a,c)=>a.left<c.right && a.right>c.left && a.top<c.bottom && a.bottom>c.top;
                const fresh=()=>{
                    const shown=BeanOverlay.renderAssistant(rect,0,'nativeLocal',{}, {source:e});
                    const target=root.querySelector('.assistant');
                    if(!shown || !target)throw Error('Expected owned free-edge target');
                    const bounds=target.getBoundingClientRect();BeanOverlay.clearAssistant();return bounds;
                };
                const safeAfter=(control)=>{
                    const shown=BeanOverlay.renderAssistant(rect,0,'nativeLocal',{}, {source:e});
                    const target=root.querySelector('.assistant');
                    return !!shown && !!target && !overlap(target.getBoundingClientRect(),control.getBoundingClientRect());
                };
                // Hidden contents do not hide a host's own border/background or
                // hit box. Place it strictly between the nine point probes.
                let b=fresh();const hiddenHost=document.createElement('div');
                hiddenHost.style.cssText=`position:fixed;left:${b.x+6}px;top:${b.y+5}px;width:1px;height:1px;content-visibility:hidden;background:red`;
                hiddenHost.innerHTML='<button>Hidden child</button>';document.body.appendChild(hiddenHost);
                const h=hiddenHost.getBoundingClientRect();
                const hiddenHostReallyHits=document.elementFromPoint(h.x+0.5,h.y+0.5)===hiddenHost;
                const hiddenHostExcluded=safeAfter(hiddenHost);hiddenHost.remove();
                // Paint containment does not apply to a non-atomic inline span.
                b=fresh();const inlineParent=document.createElement('span');inlineParent.textContent='Inline box';
                inlineParent.style.cssText='display:inline;contain:paint';document.body.appendChild(inlineParent);
                const inlineControl=document.createElement('button');inlineControl.textContent='Send';
                inlineControl.style.cssText=`position:fixed;left:${b.x}px;top:${b.y}px;width:28px;height:28px;padding:0`;
                inlineParent.appendChild(inlineControl);
                const i=inlineControl.getBoundingClientRect();
                const inlineActuallyEscapes=getComputedStyle(inlineParent).display==='inline' &&
                    !overlap(i,inlineParent.getBoundingClientRect()) &&
                    document.elementFromPoint(i.x+i.width/2,i.y+i.height/2)===inlineControl;
                const inlineExcluded=safeAfter(inlineControl);inlineParent.remove();
                // A positive overflow clip margin can paint past the host box.
                // The child rectangle is still collected on engines where the
                // property has not shipped; that support is reported separately.
                b=fresh();const marginParent=document.createElement('div');
                marginParent.style.cssText=`position:fixed;left:${b.x-40}px;top:${b.y}px;width:8px;height:28px;contain:paint;overflow-clip-margin:100px`;
                const marginControl=document.createElement('button');marginControl.textContent='Upload';
                marginControl.style.cssText='position:absolute;left:40px;top:0;width:28px;height:28px;padding:0';
                marginParent.appendChild(marginControl);document.body.appendChild(marginParent);
                const m=marginControl.getBoundingClientRect();
                const marginSupported=CSS.supports('overflow-clip-margin','100px');
                const marginOutsideHost=!overlap(m,marginParent.getBoundingClientRect());
                const marginActuallyEscapes=document.elementFromPoint(m.x+m.width/2,m.y+m.height/2)===marginControl;
                const marginExcluded=safeAfter(marginControl);marginParent.remove();
                // A top-layer popover ignores its paint-contained ancestor's
                // clip. A light-DOM descendant must still get its own exclusion.
                b=fresh();const contained=document.createElement('div');
                contained.style.cssText='position:fixed;left:0;top:0;width:8px;height:8px;contain:paint';
                const popover=document.createElement('button');popover.textContent='Voice';popover.setAttribute('popover','manual');
                popover.style.cssText=`position:fixed;left:${b.x}px;top:${b.y}px;right:auto;bottom:auto;margin:0;width:28px;height:28px;padding:0`;
                contained.appendChild(popover);document.body.appendChild(contained);
                const popoverSupported=typeof popover.showPopover==='function';
                if(popoverSupported)popover.showPopover();
                const p=popover.getBoundingClientRect();
                const popoverActuallyEscapes=popoverSupported && !overlap(p,contained.getBoundingClientRect()) &&
                    document.elementFromPoint(p.x+p.width/2,p.y+p.height/2)===popover;
                const popoverExcluded=popoverSupported && safeAfter(popover);
                if(popoverSupported)popover.hidePopover();contained.remove();
                // An open shadow/custom host cannot become certified geometry
                // just by declaring containment on its small host rectangle.
                const shadowHost=document.createElement('bean-owned-control');
                shadowHost.style.cssText='position:fixed;left:0;top:0;width:8px;height:8px;contain:paint';
                shadowHost.attachShadow({mode:'open'}).innerHTML='<button>Unlocated control</button>';
                document.body.appendChild(shadowHost);
                const shadowStillHidden=!BeanOverlay.renderAssistant(rect,0,'nativeLocal',{}, {source:e}) && !root.querySelector('.assistant');
                shadowHost.remove();
                const recovered=BeanOverlay.renderAssistant(rect,0,'nativeLocal',{}, {source:e});
                return {hiddenHostReallyHits,hiddenHostExcluded,inlineActuallyEscapes,inlineExcluded,
                    marginSupported,marginOutsideHost,marginActuallyEscapes,marginExcluded,
                    popoverSupported,popoverActuallyEscapes,popoverExcluded,shadowStillHidden,recovered,
                    sourceUntouched:e.value==='Synthetic draft with teh spelling issue.' && e.selectionStart===8 && document.activeElement===e};
                """)
            for key in ["hiddenHostReallyHits", "hiddenHostExcluded", "inlineActuallyEscapes", "inlineExcluded",
                        "marginOutsideHost", "marginExcluded", "shadowStillHidden", "recovered", "sourceUntouched"] {
                XCTAssertEqual(result[key] as? Bool, true, "\(dark): \(key) \(result)")
            }
            if result["marginSupported"] as? Bool == true {
                XCTAssertEqual(result["marginActuallyEscapes"] as? Bool, true, "\(dark): \(result)")
            }
            XCTAssertEqual(result["popoverSupported"] as? Bool, true, "Owned WebKit top-layer fixture requires native popover support")
            XCTAssertEqual(result["popoverActuallyEscapes"] as? Bool, true, "\(dark): \(result)")
            XCTAssertEqual(result["popoverExcluded"] as? Bool, true, "\(dark): \(result)")
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
