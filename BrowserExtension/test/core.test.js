const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function load(relativePath, overrides = {}) {
  const source = fs.readFileSync(path.join(__dirname, "..", relativePath), "utf8");
  const context = {
    window: { scrollX: 0, scrollY: 0 },
    document: {},
    NodeFilter: { SHOW_TEXT: 4 },
    ...overrides
  };
  vm.runInNewContext(source, context);
  return context.window;
}

const detector = load("src/localDetector.js").BeanDetector;
const detectorIssues = detector.detect("i  recieve teh teh note");
assert.ok(detectorIssues.some((issue) => issue.original.includes("  ") && issue.type === "spacing"));
assert.ok(detectorIssues.some((issue) => issue.original === "recieve" && issue.suggestion === "receive"));
assert.ok(detectorIssues.some((issue) => issue.original === "teh teh" && issue.type === "grammar"));
assert.ok(detectorIssues.length <= 8);
assert.equal(
  detector.fixObvious("teh result works,tommorow.\n\nleave this paragraf ."),
  "the result works, tomorrow.\n\nleave this paragraf .",
  "overlapping local fixes compose without dropping line breaks or touching unsupported text"
);

const mapping = load("src/issueMapping.js").BeanMapping;
assert.deepEqual(
  JSON.parse(JSON.stringify(mapping.uniqueOffset("hello world", "world"))),
  { start: 6, end: 11 }
);
assert.equal(mapping.uniqueOffset("word word", "word"), null, "ambiguous text must not map");
assert.equal(mapping.replaceRangePreservingBoundaries("one\ntwo", 4, 7, "three"), "one\nthree");
assert.equal(mapping.replaceRangePreservingBoundaries("one two", 4, 7, "t\nwo"), null,
  "a localized suggestion cannot introduce a line break");
assert.equal(mapping.replaceRangePreservingBoundaries("one\ntwo", 0, 7, "one two"), null,
  "a replacement cannot remove an existing line break");
assert.equal(mapping.replaceRangePreservingBoundaries("one\r\ntwo", 0, 8, "ONE\r\nTWO"), "ONE\r\nTWO",
  "a replacement with the exact same CRLF structure remains valid");
assert.equal(mapping.replaceRangePreservingBoundaries("one\r\ntwo", 0, 8, "ONE\nTWO"), null,
  "changing a CRLF boundary into LF is refused");
assert.equal(mapping.replaceRangePreservingBoundaries("short", -1, 2, "x"), null);

function FakeEvent(type) { this.type = type; }
const editDocument = { activeElement: null, execCommand: () => false };
const editMapping = load("src/issueMapping.js", {
  document: editDocument,
  Event: FakeEvent,
  InputEvent: undefined
}).BeanMapping;
const listeners = { input: [], change: [] };
let ownSetterCalls = 0, nativeSetterCalls = 0;
const nativeControl = {};
Object.defineProperty(nativeControl, "value", {
  configurable: true,
  get() { return this._value; },
  set(value) { nativeSetterCalls++; this._value = value; }
});
const controlled = Object.create(nativeControl);
controlled._value = "the old text";
Object.defineProperty(controlled, "value", {
  configurable: true,
  get() { return this._value; },
  set(value) { ownSetterCalls++; this._value = value; }
});
controlled.addEventListener = (type, fn) => listeners[type].push(fn);
controlled.removeEventListener = (type, fn) => {
  listeners[type] = listeners[type].filter((candidate) => candidate !== fn);
};
controlled.dispatchEvent = (event) => {
  for (const fn of [...(listeners[event.type] || [])]) fn(event);
  return true;
};
controlled.setSelectionRange = (start, end) => { controlled.selectionStart = start; controlled.selectionEnd = end; };

const controlledResult = editMapping.applyTextControlRange(controlled, 4, 7, "new");
assert.equal(controlledResult.ok, true, "controlled input replacement is verified after events");
assert.equal(controlled.value, "the new text");
assert.equal(nativeSetterCalls, 1, "React's own value tracker is bypassed through the native setter");
assert.equal(ownSetterCalls, 0, "the React-controlled own setter is not used");
assert.equal(controlledResult.inputEventVerified, true);
assert.equal(controlledResult.changeEventVerified, true);
assert.equal(controlledResult.nativeUndoPreserved, false);
assert.equal(controlled.selectionStart, 7);

controlled._value = "undo works";
editDocument.activeElement = controlled;
editDocument.execCommand = (_command, _showUI, replacement) => {
  nativeControl.__lookupSetter__("value").call(controlled, replacement + " works");
  controlled.dispatchEvent(new FakeEvent("input"));
  return true;
};
const nativeUndoResult = editMapping.applyTextControlRange(controlled, 0, 4, "redo");
assert.equal(nativeUndoResult.ok, true);
assert.equal(nativeUndoResult.nativeUndoPreserved, true, "focused edits retain Chromium's native Undo entry");
assert.equal(controlled.value, "redo works");

controlled._value = "page owns this";
const settersBeforeUnexpectedMutation = nativeSetterCalls;
editDocument.execCommand = () => {
  controlled._value = "page changed something else";
  controlled.dispatchEvent(new FakeEvent("input"));
  return false;
};
const unexpectedMutationResult = editMapping.applyTextControlRange(controlled, 0, 4, "Bean");
assert.equal(unexpectedMutationResult.ok, false,
  "an unexpected synchronous page edit is never reported as Bean's replacement");
assert.equal(controlled.value, "page changed something else",
  "the whole-value fallback never overwrites newer page state");
assert.equal(nativeSetterCalls, settersBeforeUnexpectedMutation,
  "the native setter is skipped after an unexpected page mutation");

const sanitized = mapping.sanitizeProofreadParagraphOutput("```\n\u200BFixed.\n```");
assert.equal(sanitized.text, "Fixed.");
assert.equal(sanitized.zeroWidthStripped, 1);

const trust = load("src/trustPolicy.js").BeanTrustPolicy;
const local = [
  { original: "teh", suggestion: "the", type: "spelling" },
  { original: "double  space", suggestion: "double space", type: "spacing" }
];
const ai = [
  { original: "teh", suggestion: "that", type: "grammar" },
  { original: "alot", suggestion: "a lot", type: "spelling" },
  { original: "unchanged", suggestion: "unchanged", type: "grammar" }
];
const merged = trust.mergeIssues(local, ai, 8);
assert.deepEqual(JSON.parse(JSON.stringify(merged)), [local[0], local[1], ai[1]],
  "provider findings augment local findings without duplicates or unchanged output");
assert.deepEqual(JSON.parse(JSON.stringify(trust.mergeIssues([], ai, 1))), [ai[0]],
  "merged findings obey the request limit");
assert.equal(trust.isMeaningfulEdit("same", "same"), false);
assert.equal(trust.isMeaningfulEdit("same", "\u200Bsame"), false, "zero-width artifacts are not edits");
assert.equal(trust.isMeaningfulEdit("teh", "the"), true);

const readyStatus = {
  ok: true,
  bridgeAvailable: true,
  protocolVersion: 1,
  compatible: true,
  providerConfigured: true,
  webInlineEnabled: true,
  automaticAccountingAvailable: true
};
assert.deepEqual(JSON.parse(JSON.stringify(trust.bridgeReadiness(readyStatus))), {
  ready: true, code: "bridgeReady"
});
assert.equal(trust.bridgeReadiness(null).ready, false);
assert.equal(trust.bridgeReadiness({ ...readyStatus, bridgeAvailable: false }).code, "bridgeDisconnected");
assert.equal(trust.bridgeReadiness({ ...readyStatus, protocolVersion: undefined }).code, "bridgeProtocolIncompatible");
assert.equal(trust.bridgeReadiness({ ...readyStatus, protocolVersion: 2 }).code, "bridgeProtocolIncompatible");
assert.equal(trust.bridgeReadiness({ ...readyStatus, compatible: false }).code, "bridgeProtocolIncompatible");
assert.equal(trust.bridgeReadiness({ ...readyStatus, providerConfigured: false }).code, "bridgeProviderNotConfigured");
assert.equal(trust.bridgeReadiness({ ...readyStatus, webInlineEnabled: false }).code, "bridgeWebInlineDisabled");
assert.equal(trust.bridgeReadiness({ ...readyStatus, automaticAccountingAvailable: false }).code,
  "bridgeAccountingUnavailable");
assert.equal(trust.bridgeReadiness({ ...readyStatus, automaticAccountingAvailable: undefined }).code,
  "bridgeAccountingUnavailable");
assert.equal(trust.bridgeReadiness({ ...readyStatus, browserAIConsentRequired: true }).code, "bridgeConsentRequired");
assert.equal(trust.bridgeReadiness({ ...readyStatus, browserAIEnabled: false }).code, "bridgeConsentRequired");

const plainTextBlock = { childNodes: [{ nodeType: 3 }, { nodeType: 3 }] };
const lineBreakBlock = { childNodes: [{ nodeType: 3 }, { nodeType: 1, tagName: "BR" }, { nodeType: 3 }] };
const markedUpBlock = { childNodes: [{ nodeType: 3 }, { nodeType: 1, tagName: "SPAN" }] };
assert.equal(trust.isPlainTextContentEditableBlock(plainTextBlock), true);
assert.equal(trust.isPlainTextContentEditableBlock(lineBreakBlock), false,
  "a <br> block is rejected before paragraph AI because innerText and textContent offsets differ");
assert.equal(trust.isPlainTextContentEditableBlock(markedUpBlock), false,
  "whole-block replacement never destroys contenteditable markup");

const paragraph = trust.boundedChangedBlock("first paragraph\nchanged paragraph\nlast paragraph", 24, 2000);
assert.deepEqual(JSON.parse(JSON.stringify(paragraph)), {
  text: "changed paragraph", start: 16, end: 33
});
const completedLine = trust.boundedChangedBlock("completed line\n", 15, 2000);
assert.equal(completedLine.text, "completed line", "Enter checks the line that was just completed");
const longLine = "word ".repeat(1000);
const bounded = trust.boundedChangedBlock(longLine, 2500, 2000);
assert.ok(bounded.text.length <= 2000, "AI block payload stays bounded");
assert.equal(longLine.slice(bounded.start, bounded.end), bounded.text, "bounded offsets verify exact source text");
assert.equal(trust.boundedChangedBlock("\n\n", 1, 2000), null, "empty blocks never leave the page");

console.log("Browser extension detector and mapping tests passed");
