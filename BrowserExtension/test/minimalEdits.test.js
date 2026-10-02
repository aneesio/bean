const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const context = {window:{},document:{},NodeFilter:{SHOW_TEXT:4},Intl};
vm.runInNewContext(fs.readFileSync(path.join(__dirname,"../src/issueMapping.js"),"utf8"),context);
const mapping = context.window.BeanMapping;
assert.equal(mapping.sanitizeProofreadParagraphOutput("👩🏽‍💻 writes می‌نویسد").text,"👩🏽‍💻 writes می‌نویسد",
  "emoji ZWJ and Persian ZWNJ are user content, not disposable artifacts");
assert.equal(mapping.sanitizeProofreadParagraphOutput("keep\u200bthis","keep\u200bthis").text,"keep\u200bthis");
assert.equal(mapping.sanitizeProofreadParagraphOutput('  "Please fix the."  ', '  "Please fix teh."  ').text,'  "Please fix the."  ',
  "original quotation and outside spacing survive the browser's second cleanup");
assert.equal(mapping.sanitizeProofreadParagraphOutput('```\nkeep\n```','```\nkeep\n```').text,'```\nkeep\n```');
for (const [before,after] of [
  ["teh cat and teh dog","the cat and the dog"],
  ["🙂 teh cat\n\nKeep this signature.","🙂 the cat\n\nKeep this signature."],
  ["Café is nice,but late.","Café is nice, but late."],
  ["I recieved teh note.","I received the note."],
  ["one two three", "one three"],
  ["abc def", "abcef"],
  ["", "Hello"], ["Hello", ""], ["same","same"]
]) {
  const plan = mapping.buildMinimalEditPlan(before,after);
  assert.ok(plan,`${before} should form a bounded mechanical plan`);
  assert.equal(plan.replacement,after);
  const inverse = mapping.inverseEditPlan(plan);
  assert.ok(inverse,"every valid mechanical plan has an exact inverse");
  assert.equal(inverse.replacement,before);
  assert.ok(plan.edits.every((edit) => !/[\r\n\u2028\u2029\ufffc]/u.test(edit.original + edit.replacement)));
}
const repeated = mapping.buildMinimalEditPlan("teh cat and teh dog", "the cat and the dog");
assert.equal(repeated.edits.length,2,"separate repeated occurrences are separate edits");
assert.ok(repeated.edits[0].end < 4 && repeated.edits[1].start > 10,"unchanged phrase stays outside edits");
assert.equal(mapping.buildMinimalEditPlan("one\ntwo", "one two"),null,"paragraph structure cannot be removed");
assert.equal(mapping.buildMinimalEditPlan("a\ufffcb", "ab"),null,"attachments cannot be deleted");
assert.equal(mapping.validateEditPlan("🙂 word",[{start:1,end:2,original:"\ude42",replacement:"x"}]),null);
assert.equal(mapping.validateEditPlan("é",[{start:0,end:1,original:"e",replacement:"a"}]),null,"combining characters stay intact");
assert.equal(mapping.validateEditPlan("ab",[{start:0,end:1,original:"a",replacement:"b"},{start:0,end:0,original:"",replacement:"z"}]),null,"same-caret overlapping edits are refused");
assert.equal(mapping.validateEditPlan("word",[{start:0,end:4,original:"other",replacement:"new"}]),null);
assert.equal(mapping.buildMinimalEditPlan("old ".repeat(2500), "new ".repeat(2500)),null,"large transforms hit the hard work bound");
let destinationChecks = 0;
const stale = mapping.applyContentEditableEdits({isConnected:true,isContentEditable:true,textContent:"newer text"},repeated,
  {validateDestination:() => {destinationChecks++; return true;}});
assert.equal(stale.ok,false);
assert.equal(stale.confirmedEdits.length,0);
assert.equal(destinationChecks,1,"stale full snapshots are rejected before a DOM range or edit is made");

const grow = [{start:3,end:6,replacement:"there"},{start:11,end:19,replacement:"received"}];
assert.deepEqual({...mapping.selectionAfterEdits({start:25,end:25,direction:"none"},grow)},
  {start:27,end:27,direction:"none"},"typing caret maps exact UTF-16 deltas after every span");
assert.deepEqual({...mapping.selectionAfterEdits({start:21,end:25,direction:"backward"},grow)},
  {start:23,end:27,direction:"backward"},"unrelated backward selection retains its direction");
assert.equal(mapping.selectionAfterEdits({start:4,end:4},grow),null,"a caret inside a replaced span may collapse into its result");
assert.equal(mapping.selectionAfterEdits({start:3,end:6},grow),null,"explicit selected rewriting does not restore old selection");
assert.deepEqual({...mapping.selectionAfterEdits({start:6,end:6},[{start:6,end:6,replacement:"!"}])},
  {start:7,end:7},"insertion at the typing caret advances after the inserted text");

// Exercise production selection ownership checks with native-like input values
// and synchronous page event callbacks. The real DOM paths are also tested in
// the owned nonpersistent WebKit editor fixture.
class TextControl {
  constructor(value) { this._value=value; this.selectionStart=this.selectionEnd=value.length; this.selectionDirection="none"; this.listeners={}; }
  get value() { return this._value; }
  set value(value) { this._value=value; this.selectionStart=this.selectionEnd=value.length; }
  setSelectionRange(start,end,direction="none") { this.selectionStart=start;this.selectionEnd=end;this.selectionDirection=direction; }
  addEventListener(type,callback) { (this.listeners[type] ||= new Set()).add(callback); }
  removeEventListener(type,callback) { this.listeners[type]?.delete(callback); }
  dispatchEvent(event) { for(const callback of this.listeners[event.type] || []) callback(event); return true; }
}
context.Event = class {constructor(type) {this.type=type;}};
context.document.execCommand = (_command,_ui,replacement) => {
  const el=context.document.activeElement, start=el.selectionStart, end=el.selectionEnd;
  el.value=el.value.slice(0,start)+replacement+el.value.slice(end);
  el.setSelectionRange(start+replacement.length,start+replacement.length);
  el.dispatchEvent(new context.Event("input")); return true;
};
let control = new TextControl("🙂 teh ending"); context.document.activeElement=control;
let applied = mapping.applyTextControlRange(control,3,6,"there");
assert.equal(applied.ok,true); assert.equal(applied.selectionPreserved,true);
assert.equal(control.selectionStart,control.value.length,"accepting an earlier issue keeps typing at the end");
control = new TextControl("🙂 teh ending"); context.document.activeElement=control;
control.setSelectionRange(7,13,"backward");
applied = mapping.applyTextControlRange(control,3,6,"there");
assert.equal(applied.selectionPreserved,true); assert.equal(control.selectionStart,9); assert.equal(control.selectionEnd,15);
assert.equal(control.selectionDirection,"backward");
control = new TextControl("🙂 teh ending"); context.document.activeElement=control;
control.addEventListener("input",()=>control.setSelectionRange(0,0));
applied = mapping.applyTextControlRange(control,3,6,"there");
assert.equal(applied.ok,true); assert.equal(applied.selectionOwned,false); assert.equal(control.selectionStart,0,
  "page caret changes after the edit are never overwritten");
control = new TextControl("🙂 teh ending"); context.document.activeElement=control;
const nextFocus={};control.addEventListener("input",()=>{context.document.activeElement=nextFocus;control.setSelectionRange(0,0);});
applied = mapping.applyTextControlRange(control,3,6,"there");
assert.equal(applied.ok,true); assert.equal(context.document.activeElement,nextFocus); assert.equal(control.selectionStart,0);
control = new TextControl("🙂 teh ending"); context.document.activeElement=control; control.setSelectionRange(3,6);
applied = mapping.applyTextControlRange(control,3,6,"there");
assert.equal(applied.ok,true); assert.equal(applied.selectionPreserved,false); assert.equal(control.selectionStart,8,
  "an explicit selected span collapses at its replacement");
control = new TextControl("🙂 teh ending"); context.document.activeElement=control;
context.document.execCommand=()=>{control.setSelectionRange(0,0);return false;};
applied = mapping.applyTextControlRange(control,3,6,"there");
assert.equal(applied.ok,false); assert.equal(control.value,"🙂 teh ending"); assert.equal(control.selectionStart,0,
  "a failed command with a changed page caret cannot trigger a second replacement fallback");

function attachmentCaretFixture() {
  const text={nodeType:3,nodeValue:"teh suffix",isConnected:true};
  const image={nodeType:1,childNodes:[],textContent:"",isConnected:true};
  const root={nodeType:1,isConnected:true,isContentEditable:true,childNodes:[text,image],listeners:{},
    contains(node){return node===this || this.childNodes.includes(node);},
    addEventListener:TextControl.prototype.addEventListener,removeEventListener:TextControl.prototype.removeEventListener,
    dispatchEvent:TextControl.prototype.dispatchEvent,closest(){return null;}};
  Object.defineProperty(root,"textContent",{get:()=>root.childNodes.map(node=>node.nodeType===3?node.nodeValue:node.textContent).join("")});
  text.parentElement=image.parentElement=root;
  const position=(node,offset)=>node===root
    ? root.childNodes.slice(0,offset).reduce((count,child)=>count+(child.nodeType===3?child.nodeValue.length:child.textContent.length),0)
    : root.childNodes.slice(0,root.childNodes.indexOf(node)).reduce((count,child)=>count+(child.nodeType===3?child.nodeValue.length:child.textContent.length),0)+offset;
  class Range {
    setStart(node,offset){this.startContainer=node;this.startOffset=offset;}
    setEnd(node,offset){this.endContainer=node;this.endOffset=offset;}
    selectNodeContents(node){this.setStart(node,0);this.setEnd(node,node.childNodes.length);}
    collapse(){this.setEnd(this.startContainer,this.startOffset);}
    get collapsed(){return this.startContainer===this.endContainer && this.startOffset===this.endOffset;}
    cloneContents(){return {textContent:root.textContent.slice(position(this.startContainer,this.startOffset),position(this.endContainer,this.endOffset))};}
    toString(){return this.cloneContents().textContent;}
  }
  const selection={rangeCount:0,getRangeAt(){return this.range;},removeAllRanges(){this.rangeCount=0;},
    addRange(range){this.range=range;this.rangeCount=1;this.anchorNode=range.startContainer;this.anchorOffset=range.startOffset;}};
  const setCaret=(node,offset)=>{const range=new Range();range.setStart(node,offset);range.collapse();selection.addRange(range);};
  const document={activeElement:root,createRange:()=>new Range(),createTreeWalker:()=>{
    const texts=root.childNodes.filter(node=>node.nodeType===3);let index=0;return {nextNode:()=>texts[index++] || null};
  },execCommand(_command,_ui,replacement){
    const range=selection.range,start=range.startOffset,end=range.endOffset;
    text.nodeValue=text.nodeValue.slice(0,start)+replacement+text.nodeValue.slice(end);
    setCaret(text,start+replacement.length);root.dispatchEvent(new context.Event("input"));return true;
  }};
  const isolated={window:{getSelection:()=>selection},document,NodeFilter:{SHOW_TEXT:4},Intl,Event:context.Event};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,"../src/issueMapping.js"),"utf8"),isolated);
  return {root,text,image,selection,setCaret,mapping:isolated.window.BeanMapping};
}
for (const boundary of [1,2]) {
  const fixture=attachmentCaretFixture();fixture.setCaret(fixture.root,boundary);
  const range=fixture.mapping.rangeFromOffsets(fixture.root,0,3);
  const result=fixture.mapping.applyContentEditableRange(fixture.root,range,"the","the suffix");
  assert.equal(result.ok,true);assert.equal(result.selectionPreserved,true);
  assert.equal(fixture.selection.anchorNode,fixture.root);assert.equal(fixture.selection.anchorOffset,boundary,
    "the exact element caret stays on its original side of a zero-text attachment");
}
{
  const fixture=attachmentCaretFixture();fixture.setCaret(fixture.root,2);
  fixture.root.addEventListener("input",()=>fixture.setCaret(fixture.root,1));
  const result=fixture.mapping.applyContentEditableRange(fixture.root,fixture.mapping.rangeFromOffsets(fixture.root,0,3),"the","the suffix");
  assert.equal(result.ok,true);assert.equal(result.selectionOwned,false);assert.equal(result.selectionPreserved,false);
  assert.equal(fixture.selection.anchorOffset,1,"page takeover before the attachment survives at the same text offset");
}
{
  const fixture=attachmentCaretFixture();fixture.setCaret(fixture.root,2);
  fixture.root.addEventListener("input",()=>{fixture.root.childNodes.pop();fixture.image.isConnected=false;});
  const result=fixture.mapping.applyContentEditableRange(fixture.root,fixture.mapping.rangeFromOffsets(fixture.root,0,3),"the","the suffix");
  assert.equal(result.ok,true);assert.equal(result.selectionPreserved,false,
    "a removed boundary neighbour cannot be restored through a guessed flat offset");
}
console.log("Bounded browser span plans, Unicode, boundaries, repeated occurrences, inverse Undo and stale guards passed");
