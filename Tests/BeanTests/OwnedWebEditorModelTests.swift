import AppKit
import WebKit
import XCTest
@testable import Bean

/// Real DOM/editor-model coverage using repository production helpers. These
/// fixtures load no network content and never query AX, system-wide focus,
/// another application, the clipboard, or synthesized input.
@MainActor
final class OwnedWebEditorModelTests: XCTestCase {
    func testMinimalProofreadPreservesRealRichNodesAndCanUndoVerifiedSpans() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: Self.richHTML)
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();
            const before=e.textContent, html=e.innerHTML;
            const nodes=['first','list','strong','signature','link','attachment'].map(id=>document.getElementById(id));
            const signature=document.getElementById('signature').outerHTML;
            const corrected=before.replaceAll('teh','the').replace('recieved','received');
            const plan=BeanMapping.buildMinimalEditPlan(before,corrected);
            const started=performance.now();
            const result=BeanMapping.applyContentEditableEdits(e,plan,{validateDestination:()=>document.activeElement===e});
            const duration=performance.now()-started;
            const exact=e.textContent===corrected;
            const identities=nodes.every(node=>document.getElementById(node.id)===node);
            const signatureIntact=document.getElementById('signature').outerHTML===signature;
            const editedBold=document.getElementById('strong').textContent==='received';
            const undo=BeanMapping.applyContentEditableEdits(e,result.undoPlan,{validateDestination:()=>document.activeElement===e});
            const inverseRestored=undo.ok && e.textContent===before && document.getElementById('signature').outerHTML===signature;
            let nativeUndoRestored=null;
            if(result.nativeUndoPreserved && inverseRestored) {
                const again=BeanMapping.applyContentEditableEdits(e,plan);
                for(let i=0;i<plan.edits.length+2 && e.textContent!==before;i++) document.execCommand('undo',false,null);
                nativeUndoRestored=again.ok && e.textContent===before && e.innerHTML===html;
            }
            return {ok:result.ok,exact,identities,signatureIntact,editedBold,inverseRestored,
                nativeUndo:result.nativeUndoPreserved,nativeUndoRestored,changes:result.confirmedEdits.length,duration};
            """)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["exact"] as? Bool, true)
        XCTAssertEqual(result["identities"] as? Bool, true)
        XCTAssertEqual(result["signatureIntact"] as? Bool, true)
        XCTAssertEqual(result["editedBold"] as? Bool, true)
        XCTAssertEqual(result["inverseRestored"] as? Bool, true)
        XCTAssertEqual(result["changes"] as? Int, 3)
        if result["nativeUndo"] as? Bool == true { XCTAssertEqual(result["nativeUndoRestored"] as? Bool, true) }
        print("OWNED_WEB_EDITOR_MODEL_TIMING changes=\(result["changes"] as? Int ?? 0) milliseconds=\(result["duration"] as? Double ?? -1) native_undo=\(result["nativeUndo"] as? Bool == true) AX_transport=excluded")
    }

    func testBatchRefusesStaleSnapshotBeforeTouchingRealDOM() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: Self.richHTML)
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();
            const before=e.textContent,plan=BeanMapping.buildMinimalEditPlan(before,before.replaceAll('teh','the'));
            document.getElementById('first').firstChild.nodeValue+=' newer writing';
            const current=e.textContent,html=e.innerHTML;
            const result=BeanMapping.applyContentEditableEdits(e,plan);
            return {ok:result.ok,untouched:e.textContent===current && e.innerHTML===html,count:result.confirmedEdits.length};
            """)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["untouched"] as? Bool, true)
        XCTAssertEqual(result["count"] as? Int, 0)
    }

    func testBatchPreflightRefusesAtomicAndCrossFormattingSpansWithoutPartialEdits() async throws {
        for html in [
            "<div id='editor' contenteditable='true'><span contenteditable='false'>teh</span> and recieved</div>",
            "<div id='editor' contenteditable='true'><strong>te</strong><em>h</em> and recieved</div>"
        ] {
            let fixture = try OwnedWebEditorModelFixture(html: html)
            try await fixture.load()
            let result = try await fixture.object("""
                const e=document.getElementById('editor');e.focus();const before=e.textContent,html=e.innerHTML;
                const plan=BeanMapping.buildMinimalEditPlan(before,before.replace('teh','the').replace('recieved','received'));
                const result=BeanMapping.applyContentEditableEdits(e,plan);
                return {ok:result.ok,untouched:e.textContent===before && e.innerHTML===html,count:result.confirmedEdits.length};
                """)
            fixture.close()
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["untouched"] as? Bool, true)
            XCTAssertEqual(result["count"] as? Int, 0)
        }
    }

    func testBatchStopsAfterDestinationChangesFollowingFirstVerifiedSpan() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: Self.richHTML + "<input id='other'>")
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();const before=e.textContent;
            const plan=BeanMapping.buildMinimalEditPlan(before,before.replaceAll('teh','the').replace('recieved','received'));
            e.addEventListener('input',()=>document.getElementById('other').focus(),{once:true});
            const result=BeanMapping.applyContentEditableEdits(e,plan,{validateDestination:()=>document.activeElement===e});
            const partialText=e.textContent;
            const safeUndo=!!result.undoPlan && result.undoPlan.original===partialText;
            const focusPreserved=document.activeElement.id==='other';
            e.focus();
            const undo=safeUndo && BeanMapping.applyContentEditableEdits(e,result.undoPlan).ok && e.textContent===before;
            return {ok:result.ok,partial:result.partial,count:result.confirmedEdits.length,
                firstPassageUntouched:document.getElementById('first').textContent==='👩🏽‍💻 teh and teh',
                focusPreserved,safeUndo,undo};
            """)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["partial"] as? Bool, true)
        XCTAssertEqual(result["count"] as? Int, 1)
        XCTAssertEqual(result["firstPassageUntouched"] as? Bool, true)
        XCTAssertEqual(result["focusPreserved"] as? Bool, true)
        XCTAssertEqual(result["safeUndo"] as? Bool, true)
        XCTAssertEqual(result["undo"] as? Bool, true)
    }

    func testExactRepeatedUTF16RangePreservesRichNodesAndNativeUndoWhenAvailable() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: Self.richHTML)
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();
            const before=e.textContent, html=e.innerHTML;
            const nodes=['link','signature','attachment','list','strong'].map(id=>document.getElementById(id));
            const original='teh', start=before.lastIndexOf(original), end=start+original.length;
            const range=BeanMapping.rangeFromOffsets(e,start,end);
            const expected=before.slice(0,start)+'the'+before.slice(end);
            const result=BeanMapping.applyContentEditableRange(e,range,'the',expected);
            const unchanged=nodes.every(node=>document.getElementById(node.id)===node);
            const selected=window.getSelection();
            const selection=selected.rangeCount?BeanMapping.rangeOffsets(e,selected.getRangeAt(0)):null;
            let undoRestored=null;
            if(result.nativeUndoPreserved) {
                document.execCommand('undo',false,null);
                undoRestored=e.textContent===before && e.innerHTML===html;
            }
            return {ok:result.ok,nativeUndo:result.nativeUndoPreserved,unchanged,undoRestored,
                validUTF16:start===before.indexOf('teh')+8,selection};
            """)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["validUTF16"] as? Bool, true)
        XCTAssertEqual(result["unchanged"] as? Bool, true)
        if result["nativeUndo"] as? Bool == true { XCTAssertEqual(result["undoRestored"] as? Bool, true) }
        print("OWNED_WEB_EDITOR_MODEL single_range_native_undo=\(result["nativeUndo"] as? Bool == true) AX_transport=excluded")
    }

    func testRealTextareaDeliversInputChangeAndRetainsNativeUndoWhenAvailable() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: "<textarea id='editor'>🙂 teh and teh</textarea>")
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();
            const before=e.value,start=before.lastIndexOf('teh');
            e.setSelectionRange(start,start+3);
            let input=0,change=0;e.addEventListener('input',()=>input++);e.addEventListener('change',()=>change++);
            const result=BeanMapping.applyTextControlRange(e,start,start+3,'the');
            const exact=e.value==='🙂 teh and the',caret=e.selectionStart===start+3 && e.selectionEnd===start+3;
            let undoRestored=null;if(result.nativeUndoPreserved){document.execCommand('undo',false,null);undoRestored=e.value===before;}
            return {ok:result.ok,nativeUndo:result.nativeUndoPreserved,exact,caret,input,change,undoRestored};
            """)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["exact"] as? Bool, true)
        XCTAssertEqual(result["caret"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(result["input"] as? Int ?? 0, 1)
        XCTAssertGreaterThanOrEqual(result["change"] as? Int ?? 0, 1)
        if result["nativeUndo"] as? Bool == true { XCTAssertEqual(result["undoRestored"] as? Bool, true) }
    }

    func testRealEditorPageMutationIsNeverOverwrittenByPlainDOMFallback() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: Self.richHTML)
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();
            const before=e.textContent,start=before.lastIndexOf('teh');
            const signature=document.getElementById('signature');
            e.addEventListener('input',()=>{signature.appendChild(document.createTextNode(' page update'));},{once:true});
            const range=BeanMapping.rangeFromOffsets(e,start,start+3);
            const expected=before.slice(0,start)+'the'+before.slice(start+3);
            const result=BeanMapping.applyContentEditableRange(e,range,'the',expected);
            return {ok:result.ok,pageStatePreserved:signature.textContent.endsWith(' page update'),
                identity:document.getElementById('signature')===signature};
            """)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["pageStatePreserved"] as? Bool, true)
        XCTAssertEqual(result["identity"] as? Bool, true)
    }

    func testRealTextControlKeepsUnrelatedBackwardSelectionAndNewerPageCaret() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: "<textarea id='editor'>🙂 teh ending</textarea><input id='other'>")
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();
            e.setSelectionRange(7,13,'backward');
            const first=BeanMapping.applyTextControlRange(e,3,6,'there');
            const preserved=first.selectionPreserved && e.selectionStart===9 && e.selectionEnd===15 && e.selectionDirection==='backward';
            e.addEventListener('input',()=>e.setSelectionRange(0,0),{once:true});
            const second=BeanMapping.applyTextControlRange(e,3,8,'the');
            const pageCaret=second.ok && !second.selectionOwned && e.selectionStart===0 && e.selectionEnd===0;
            e.addEventListener('input',()=>{document.getElementById('other').focus();e.setSelectionRange(1,1);},{once:true});
            const third=BeanMapping.applyTextControlRange(e,3,6,'there');
            return {preserved,pageCaret,focus:third.ok && document.activeElement.id==='other',
                caretAfterFocusChange:e.selectionStart===1 && e.selectionEnd===1};
            """)
        XCTAssertEqual(result["preserved"] as? Bool, true)
        XCTAssertEqual(result["pageCaret"] as? Bool, true)
        XCTAssertEqual(result["focus"] as? Bool, true)
        XCTAssertEqual(result["caretAfterFocusChange"] as? Bool, true)
    }

    func testRealRichBatchKeepsTypingCaretAndInverseUndoMapsItBack() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: Self.richHTML.replacingOccurrences(of: "teh and teh", with: "teh and writting"))
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();const before=e.textContent;
            const selection=window.getSelection(),caret=BeanMapping.rangeFromOffsets(e,before.length,before.length);
            selection.removeAllRanges();selection.addRange(caret);
            const corrected=before.replaceAll('teh','the').replace('writting','writing').replace('recieved','received');
            const plan=BeanMapping.buildMinimalEditPlan(before,corrected);
            const first=BeanMapping.applyContentEditableEdits(e,plan);
            const after=BeanMapping.rangeOffsets(e,selection.getRangeAt(0));
            const undo=BeanMapping.applyContentEditableEdits(e,first.undoPlan);
            const restored=BeanMapping.rangeOffsets(e,selection.getRangeAt(0));
            return {ok:first.ok,caret:first.selectionPreserved && after.start===corrected.length && after.end===corrected.length,
                undo:undo.ok && e.textContent===before,undoCaret:undo.selectionPreserved && restored.start===before.length && restored.end===before.length};
            """)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["caret"] as? Bool, true)
        XCTAssertEqual(result["undo"] as? Bool, true)
        XCTAssertEqual(result["undoCaret"] as? Bool, true)
    }

    func testRealRichSingleCorrectionPreservesDirectionAndAllowsExplicitSelectedRewrite() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: "<div id='editor' contenteditable='true'>🙂 teh <strong id='tail'>ending</strong></div>")
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();const selection=window.getSelection(),tail=document.getElementById('tail').firstChild;
            selection.setBaseAndExtent(tail,6,tail,0);
            const range=BeanMapping.rangeFromOffsets(e,3,6);
            const first=BeanMapping.applyContentEditableRange(e,range,'there','🙂 there ending');
            const offsets=BeanMapping.rangeOffsets(e,selection.getRangeAt(0));
            const preserved=first.selectionPreserved && offsets.start===9 && offsets.end===15 && selection.anchorNode===tail && selection.anchorOffset===6;
            const selected=BeanMapping.rangeFromOffsets(e,3,8);selection.removeAllRanges();selection.addRange(selected);
            const rewrite=BeanMapping.applyContentEditableRange(e,selected,'the','🙂 the ending');
            const collapsed=BeanMapping.rangeOffsets(e,selection.getRangeAt(0));
            return {preserved,rewrite:rewrite.ok && !rewrite.selectionPreserved && collapsed.start===6 && collapsed.end===6};
            """)
        XCTAssertEqual(result["preserved"] as? Bool, true)
        XCTAssertEqual(result["rewrite"] as? Bool, true)
    }

    func testRealRichBatchStopsOnNewerCaretAndRetainsOnlyExactPartialUndo() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: "<div id='editor' contenteditable='true'>teh and recieved</div>")
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor');e.focus();const before=e.textContent;
            const plan=BeanMapping.buildMinimalEditPlan(before,'the and received');
            e.addEventListener('input',()=>{const s=window.getSelection(),r=BeanMapping.rangeFromOffsets(e,0,0);s.removeAllRanges();s.addRange(r);},{once:true});
            const partial=BeanMapping.applyContentEditableEdits(e,plan);
            const caret=BeanMapping.rangeOffsets(e,window.getSelection().getRangeAt(0));
            const partialSafe=!partial.ok && partial.partial && partial.confirmedEdits.length===1 && partial.undoPlan &&
                partial.undoPlan.original===e.textContent && partial.undoPlan.replacement===before && caret.start===0 && caret.end===0;
            const undo=BeanMapping.applyContentEditableEdits(e,partial.undoPlan);
            let inputs=0;e.addEventListener('input',()=>{if(++inputs===2)e.appendChild(document.createTextNode(' newer page text'));});
            const drift=BeanMapping.applyContentEditableEdits(e,plan);
            return {partialSafe:!!partialSafe,undo:undo.ok && undo.confirmedText===before,
                drift:!drift.ok && drift.confirmedEdits.length===1 && drift.undoPlan===null && e.textContent.endsWith(' newer page text')};
            """)
        XCTAssertEqual(result["partialSafe"] as? Bool, true)
        XCTAssertEqual(result["undo"] as? Bool, true)
        XCTAssertEqual(result["drift"] as? Bool, true)
    }

    func testRichParagraphBoundaryInsertionNeedsExactScopeAndKeepsBothAffinities() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: "<div id='editor' contenteditable='true'><p id='before'>Earlier</p><p id='target'>New text</p></div>")
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor'),target=document.getElementById('target');e.focus();
            const ambiguous=BeanMapping.rangeFromOffsets(e,7,7)===null;
            const caret=BeanMapping.rangeFromOffsets(e,7,7,{scopeRoot:target}),offsets=BeanMapping.rangeOffsets(e,caret);
            const exact=caret.collapsed && caret.startContainer===target.firstChild && caret.startOffset===0 && offsets.start===7 && offsets.end===7;
            const plan=BeanMapping.validateEditPlan(e.textContent,[{start:7,end:7,original:'',replacement:'!'}]);
            const refused=BeanMapping.applyContentEditableEdits(e,plan);
            const result=BeanMapping.applyContentEditableEdits(e,plan,{scopeRoot:target});
            const paragraphs=document.getElementById('before').textContent==='Earlier' && target.textContent==='!New text';
            const undo=BeanMapping.applyContentEditableEdits(e,result.undoPlan,{scopeRoot:target});
            const prior=document.getElementById('before');
            const endPlan=BeanMapping.validateEditPlan(e.textContent,[{start:7,end:7,original:'',replacement:'.'}]);
            const end=BeanMapping.applyContentEditableEdits(e,endPlan,{scopeRoot:prior});
            return {ambiguous,refused:!refused.ok && refused.confirmedEdits.length===0,exact,ok:result.ok,paragraphs,
                undo:undo.ok,end:end.ok && prior.textContent==='Earlier.' && target.textContent==='New text'};
            """)
        XCTAssertEqual(result["exact"] as? Bool, true)
        XCTAssertEqual(result["ambiguous"] as? Bool, true)
        XCTAssertEqual(result["refused"] as? Bool, true)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["paragraphs"] as? Bool, true)
        XCTAssertEqual(result["undo"] as? Bool, true)
        XCTAssertEqual(result["end"] as? Bool, true)
    }

    func testSameFlatOffsetInAnotherParagraphIsANewerPageCaret() async throws {
        let fixture = try OwnedWebEditorModelFixture(html: "<div id='editor' contenteditable='true'><p id='first'>teh</p><p id='second'>Signature</p></div>")
        defer { fixture.close() }
        try await fixture.load()
        let result = try await fixture.object("""
            const e=document.getElementById('editor'),first=document.getElementById('first'),second=document.getElementById('second');e.focus();
            const s=window.getSelection(),r=document.createRange();r.setStart(first.firstChild,3);r.collapse(true);s.removeAllRanges();s.addRange(r);
            e.addEventListener('input',()=>{const changed=document.createRange();changed.setStart(second.firstChild,0);changed.collapse(true);s.removeAllRanges();s.addRange(changed);},{once:true});
            const range=BeanMapping.rangeFromOffsets(e,0,3),result=BeanMapping.applyContentEditableRange(e,range,'the','theSignature');
            return {ok:result.ok,owned:result.selectionOwned,preserved:result.selectionPreserved,
                pageCaret:s.anchorNode===second.firstChild && s.anchorOffset===0};
            """)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["owned"] as? Bool, false)
        XCTAssertEqual(result["preserved"] as? Bool, false)
        XCTAssertEqual(result["pageCaret"] as? Bool, true)
    }

    func testRealRootAndParagraphCaretsRetainBothSidesOfZeroTextAttachment() async throws {
        for nested in [false, true] {
            for boundary in [1, 2] {
                let content = "teh suffix<img id='attachment' contenteditable='false' alt='synthetic attachment'>"
                let html = nested ? "<div id='editor' contenteditable='true'><p id='scope'>\(content)</p><p>Signature</p></div>"
                    : "<div id='editor' contenteditable='true'>\(content)</div>"
                let fixture = try OwnedWebEditorModelFixture(html: html)
                try await fixture.load()
                let result = try await fixture.object("""
                    const e=document.getElementById('editor'),scope=document.getElementById('scope') || e,attachment=document.getElementById('attachment');e.focus();
                    const s=window.getSelection(),r=document.createRange();r.setStart(scope,\(boundary));r.collapse(true);s.removeAllRanges();s.addRange(r);
                    const before=e.textContent,plan=BeanMapping.validateEditPlan(before,[{start:0,end:3,original:'teh',replacement:'there'}]);
                    const result=BeanMapping.applyContentEditableEdits(e,plan);
                    const forward=result.ok && result.selectionPreserved && s.anchorNode===scope && s.anchorOffset===\(boundary);
                    const undo=BeanMapping.applyContentEditableEdits(e,result.undoPlan);
                    return {forward,undo:undo.ok && undo.selectionPreserved && e.textContent===before && s.anchorNode===scope && s.anchorOffset===\(boundary),
                        attachment:document.getElementById('attachment')===attachment && attachment.parentElement===scope};
                    """)
                fixture.close()
                XCTAssertEqual(result["forward"] as? Bool, true, "nested=\(nested), boundary=\(boundary)")
                XCTAssertEqual(result["undo"] as? Bool, true, "nested=\(nested), boundary=\(boundary)")
                XCTAssertEqual(result["attachment"] as? Bool, true)
            }
        }
    }

    func testRealAttachmentPageCaretTakeoverAndRemovedBoundaryNeverGetGuessedRestoration() async throws {
        for removed in [false, true] {
            let fixture = try OwnedWebEditorModelFixture(html: "<div id='editor' contenteditable='true'><p id='scope'>teh suffix<img id='attachment' contenteditable='false'></p></div>")
            try await fixture.load()
            let result = try await fixture.object("""
                const e=document.getElementById('editor'),scope=document.getElementById('scope'),attachment=document.getElementById('attachment');e.focus();
                const s=window.getSelection(),r=document.createRange();r.setStart(scope,2);r.collapse(true);s.removeAllRanges();s.addRange(r);
                e.addEventListener('input',()=>{
                    if(\(removed ? "true" : "false")) attachment.remove();
                    else {const changed=document.createRange();changed.setStart(scope,1);changed.collapse(true);s.removeAllRanges();s.addRange(changed);}
                },{once:true});
                const range=BeanMapping.rangeFromOffsets(e,0,3),result=BeanMapping.applyContentEditableRange(e,range,'the','the suffix');
                return {ok:result.ok,preserved:result.selectionPreserved,
                    takeover:\(removed ? "true" : "false") ? !attachment.isConnected && s.anchorNode===scope.firstChild && s.anchorOffset===3
                        : !result.selectionOwned && s.anchorNode===scope && s.anchorOffset===1};
                """)
            fixture.close()
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertEqual(result["preserved"] as? Bool, false)
            XCTAssertEqual(result["takeover"] as? Bool, true)
        }
    }

    private static let richHTML = """
        <div id='editor' contenteditable='true' style='white-space:pre-wrap'>
        <p id='first'>👩🏽‍💻 teh and teh</p><ul id='list'><li><strong id='strong'>recieved</strong> files</li></ul><p id='signature'>Regards, <a id='link' href='https://example.invalid'>Example</a><img id='attachment' contenteditable='false' alt='synthetic attachment' src='data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'></p></div>
        """
}

@MainActor
private final class OwnedWebEditorModelFixture: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private let html: String
    private let mapping: String
    private var loaded = false
    private var navigationError: Error?

    init(html: String) throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), configuration: configuration)
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.html = "<!doctype html><html><head><meta charset='utf-8'></head><body>\(html)</body></html>"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        mapping = try String(contentsOf: root.appendingPathComponent("BrowserExtension/src/issueMapping.js"), encoding: .utf8)
        super.init()
        webView.navigationDelegate = self
    }

    func load() async throws {
        webView.loadHTMLString(html, baseURL: nil)
        for _ in 0..<160 {
            if let navigationError { throw navigationError }
            if loaded { _ = try await webView.evaluateJavaScript(mapping); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FixtureError.loadTimeout
    }

    func object(_ body: String) async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript("(()=>{\(body)})()")
        return try XCTUnwrap(result as? [String: Any])
    }

    func close() {
        webView.stopLoading(); webView.navigationDelegate = nil; window.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }

    private enum FixtureError: Error { case loadTimeout }
}
