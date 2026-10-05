const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "src", "overlay.js"), "utf8");
const timers = new Map();
let timerID = 0;
const context = {
  window: {},
  setTimeout: (callback) => { const id = ++timerID; timers.set(id, callback); return id; },
  clearTimeout: (id) => timers.delete(id),
  requestAnimationFrame: (callback) => callback()
};
vm.runInNewContext(source, context);

const overlay = context.window.BeanOverlay;
assert.equal(typeof overlay.render, "function");
assert.equal(typeof overlay.renderGroups, "function");
assert.equal(typeof overlay.reviewParagraph, "function");
assert.equal(typeof overlay.showUndo, "function");
assert.equal(typeof overlay.clearUndo, "function");
assert.equal(typeof overlay.setFieldDisabled, "function");
assert.equal(overlay._test.cap("grammar"), "Grammar");
assert.equal(overlay._test.visibleCorrectionText("  "), "2 spaces");
assert.equal(overlay._test.visibleCorrectionText(" "), "1 space");
assert.equal(overlay._test.visibleCorrectionText("teh"), "teh");

const comparison = overlay._test.paragraphDiff("We recieve teh mail.\nNext line.", "We receive the mail.\nNext line.");
assert.equal(comparison.before.map((part) => part.text).join(""), "We recieve teh mail.\nNext line.");
assert.equal(comparison.after.map((part) => part.text).join(""), "We receive the mail.\nNext line.");
assert.equal(comparison.before.filter((part) => part.changed).map((part) => part.text).join(""), "recieveteh");
assert.equal(comparison.after.filter((part) => part.changed).map((part) => part.text).join(""), "receivethe");
assert.equal(overlay._test.paragraphDiff("same", "same").before.some((part) => part.changed), false);
const punctuationDiff = overlay._test.paragraphDiff("hello,next", "hello, next");
assert.equal(punctuationDiff.after.map((part) => part.text).join(""), "hello, next",
  "comparison preserves even whitespace-only changes exactly");

function fakeControl() {
  const listeners = {};
  return {
    listeners,
    addEventListener: (type, listener) => { listeners[type] = listener; }
  };
}
function fakeEvent(overrides = {}) {
  return {
    detail: 0,
    key: "",
    preventDefault: () => {},
    stopPropagation: () => {},
    ...overrides
  };
}

let activations = 0;
const assistiveControl = fakeControl();
overlay._test.wireActivationControl(assistiveControl, () => { activations += 1; });
assistiveControl.listeners.click(fakeEvent({ detail: 0 }));
assert.equal(activations, 1, "an accessibility click activates a semantic overlay button");

activations = 0;
const pointerControl = fakeControl();
overlay._test.wireActivationControl(pointerControl, () => { activations += 1; });
pointerControl.listeners.mousedown(fakeEvent({ detail: 1 }));
pointerControl.listeners.click(fakeEvent({ detail: 1 }));
assert.equal(activations, 1, "pointer mousedown and click do not activate twice");

activations = 0;
const keyboardControl = fakeControl();
overlay._test.wireActivationControl(keyboardControl, () => { activations += 1; });
keyboardControl.listeners.keydown(fakeEvent({ key: "Enter" }));
assert.equal(activations, 1, "Enter activates the same semantic control path");

activations = 0;
const cardButton = fakeControl();
cardButton.disabled = false;
overlay._test.wireButton(cardButton, () => { activations += 1; });
cardButton.listeners.keydown(fakeEvent({ key: "Enter" }));
assert.equal(activations, 1, "Enter explicitly activates a Shadow DOM card button");

const boundaryControls = [{ id: "first" }, { id: "middle" }, { id: "last" }];
assert.equal(overlay._test.keyboardExitDirection(
  { key: "Tab", shiftKey: true }, boundaryControls, boundaryControls[0]
), -1, "Shift-Tab from the first Bean control returns toward the source editor");
assert.equal(overlay._test.keyboardExitDirection(
  { key: "Tab", shiftKey: false }, boundaryControls, boundaryControls[2]
), 1, "Tab from the last Bean control advances to the next page control");
assert.equal(overlay._test.keyboardExitDirection(
  { key: "Tab", shiftKey: false }, boundaryControls, boundaryControls[1]
), 0, "Tab remains native between Bean controls");
assert.equal(overlay._test.keyboardExitDirection(
  { key: "Enter", shiftKey: false }, boundaryControls, boundaryControls[2]
), 0, "only Tab can leave the Bean control group");
for (const event of [
  { key: "Tab", ctrlKey: true },
  { key: "Tab", metaKey: true },
  { key: "Tab", altKey: true },
  { key: "Tab", isComposing: true },
  { key: "Tab", defaultPrevented: true }
]) {
  assert.equal(overlay._test.keyboardExitDirection(event, boundaryControls, boundaryControls[2]), 0,
    "modified, composing, and already-cancelled Tab events stay native");
}

let focusCount = 0;
overlay._test.queueKeyboardActivationFocus();
overlay._test.focusAfterKeyboardActivation({
  querySelector: () => ({ focus: () => { focusCount += 1; } })
}, "[data-act='apply']");
assert.equal(focusCount, 1, "a synchronous card transition restores keyboard focus");

const geometryField={x:100,y:100,w:200,h:100},geometryViewport={x:0,y:0,w:400,h:400};
const disjoint=(a,b)=>a.x+a.w<=b.x || b.x+b.w<=a.x || a.y+a.h<=b.y || b.y+b.h<=a.y;
const normalized=value=>JSON.parse(JSON.stringify(value));
assert.deepEqual(normalized(overlay._test.assistantPosition(geometryField,geometryViewport)),
  {x:304,y:172,w:28,h:28});
const crowdedControls=[{x:329,y:173,w:2,h:24},{x:272,y:204,w:28,h:28},{x:68,y:172,w:28,h:28}];
const crowdedPosition=overlay._test.assistantPosition(geometryField,geometryViewport,crowdedControls);
assert.deepEqual(normalized(crowdedPosition),{x:304,y:143,w:28,h:28},
  "a thin control excludes the whole target and the nearest free interval is used");
assert.equal(disjoint(crowdedPosition,geometryField),true);
assert.equal(crowdedControls.every(control=>disjoint(crowdedPosition,control)),true);
const firstEdges=[{x:304,y:172,w:28,h:28},{x:272,y:204,w:28,h:28},
  {x:68,y:172,w:28,h:28},{x:272,y:68,w:28,h:28}];
const slide=overlay._test.assistantPosition(geometryField,geometryViewport,firstEdges);
assert.deepEqual(normalized(slide),{x:304,y:142,w:28,h:28},"a blocked corner uses the exact safe edge interval");
assert.equal(disjoint(slide,geometryField),true,"slides never move the target inside the source");
for(const unavailable of [null,{x:0,y:0,w:0,h:100},{x:0,y:0,w:NaN,h:100},
  {x:0,y:500,w:100,h:100},{x:4,y:4,w:392,h:392}]) {
  assert.equal(overlay._test.assistantPosition(unavailable,geometryViewport),null,
    "unknown, offscreen, and viewport-filling fields have no forced inside fallback");
}
assert.equal(overlay._test.assistantPosition(geometryField,geometryViewport,[{x:0,y:0,w:NaN,h:1}]),null);
assert.equal(overlay._test.assistantPosition(geometryField,geometryViewport,[],()=>false),null,
  "unknown foreground content is occupied space");
const bottomEdge=overlay._test.assistantPosition({x:100,y:220,w:296,h:176},geometryViewport);
assert.deepEqual(normalized(bottomEdge),{x:68,y:368,w:28,h:28},"bottom/right viewport edges use an outside left position");
assert.equal(disjoint(bottomEdge,{x:100,y:220,w:296,h:176}),true);
assert.deepEqual(normalized(overlay._test.assistantPosition({x:550,y:700,w:200,h:100},
  {x:500,y:600,w:400,h:400})),{x:754,y:772,w:28,h:28},"page scroll coordinates remain exact");
assert.deepEqual(normalized(overlay._test.freeEdgeIntervals(0,100,[[20,50],[10,30]])),[[50,100],[0,10]],
  "overlapping blocked projections merge before the linear subtraction");
assert.deepEqual(normalized(overlay._test.freeEdgeIntervals(0,40,[[-10,20],[20,40]])),[[40,40],[20,20]],
  "exact gap boundaries retain their valid single origin");
const tallField={x:100,y:100,w:200,h:500};
const tallObstacles=[{x:304,y:300,w:28,h:300},{x:68,y:100,w:28,h:500},
  {x:100,y:604,w:200,h:28},{x:100,y:68,w:200,h:28}];
const farther=overlay._test.assistantPosition(tallField,{x:0,y:0,w:400,h:700},tallObstacles);
assert.deepEqual(normalized(farther),{x:304,y:270,w:28,h:28},
  "a proven free interval more than 96px up a long edge stays discoverable");
assert.equal(tallField.y+tallField.h-28-farther.y>96,true);
assert.equal(tallObstacles.every(control=>disjoint(farther,control)),true);
const wideField={x:100,y:100,w:600,h:100};
const wider=overlay._test.assistantPosition(wideField,{x:0,y:0,w:900,h:400},
  [{x:704,y:100,w:28,h:100},{x:300,y:204,w:400,h:28}]);
assert.deepEqual(normalized(wider),{x:270,y:204,w:28,h:28},"the same free interval proof handles a long horizontal edge");
let boundedProbes=0;
const fragmented=Array.from({length:160},(_,index)=>({x:304,y:100+index*68,w:28,h:1}));
assert.equal(overlay._test.assistantPosition({x:100,y:100,w:200,h:11000},
  {x:0,y:0,w:400,h:12000},fragmented,()=>++boundedProbes%9!==0),null);
assert.equal(boundedProbes<=96*9,true,"opaque free intervals have a hard bound on DOM hit probes");
assert.equal(overlay._test.assistantPosition(geometryField,geometryViewport,[],()=>true,()=>false),null,
  "the capture deadline covers candidate proof as well as traversal");

// A small DOM implementation exercises the actual overlay tree, closed Shadow
// root, node replacement, focus restoration, and keydown boundary listener. It
// intentionally implements only the DOM standards exercised by these paths.
class DOMElement {
  constructor(tagName, ownerDocument) {
    this.tagName = String(tagName || "div").toUpperCase();
    this.ownerDocument = ownerDocument;
    this.parentNode = null;
    this.children = [];
    this.dataset = {};
    this.attributes = new Map();
    this.listeners = {};
    this.style = {};
    this.className = "";
    this.disabled = false;
    this.hidden = false;
    this.offsetWidth = 30;
    this.offsetHeight = 20;
    this.classList = { contains: (name) => this.className.split(/\s+/).includes(name) };
  }
  set innerHTML(markup) {
    this.replaceChildren();
    const stack = [this];
    const tokens = String(markup).matchAll(/<\/?([a-z][\w-]*)([^>]*)>|([^<]+)/gi);
    for (const token of tokens) {
      if (!token[1]) continue;
      const full = token[0];
      const tagName = token[1].toLowerCase();
      if (full.startsWith("</")) { stack.pop(); continue; }
      const element = new DOMElement(tagName, this.ownerDocument);
      const attributes = token[2] || "";
      for (const attribute of attributes.matchAll(/([\w-]+)(?:="([^"]*)")?/g)) {
        const name = attribute[1], value = attribute[2] === undefined ? "" : attribute[2];
        element.setAttribute(name, value);
        if (name === "class") element.className = value;
        if (name === "disabled") element.disabled = true;
        if (name === "hidden") element.hidden = true;
        if (name.startsWith("data-")) {
          const key = name.slice(5).replace(/-([a-z])/g, (_match, letter) => letter.toUpperCase());
          element.dataset[key] = value;
        }
      }
      stack[stack.length - 1].appendChild(element);
      if (!["br", "img", "input", "hr"].includes(tagName) && !full.endsWith("/>")) stack.push(element);
    }
  }
  append(...children) { for (const child of children) this.appendChild(child); }
  appendChild(child) {
    if (child.parentNode) child.remove();
    child.parentNode = this;
    this.children.push(child);
    return child;
  }
  replaceChildren(...children) {
    const root = this.getRootNode();
    if (root && root.activeElement && this.contains(root.activeElement)) {
      root.activeElement = null;
      this.ownerDocument.activeElement = this.ownerDocument.body;
    }
    for (const child of this.children) child.parentNode = null;
    this.children = [];
    this.append(...children);
  }
  remove() {
    if (!this.parentNode) return;
    const root = this.getRootNode();
    if (root && root.activeElement && this.contains(root.activeElement)) {
      root.activeElement = null;
      this.ownerDocument.activeElement = this.ownerDocument.body;
    }
    this.parentNode.children = this.parentNode.children.filter((child) => child !== this);
    this.parentNode = null;
  }
  contains(node) {
    return node === this || this.children.some((child) => child.contains(node));
  }
  get parentElement() { return this.parentNode instanceof DOMElement ? this.parentNode : null; }
  get childNodes() {return this.children;}
  getBoundingClientRect() {
    const x = this.bounds?.x ?? (parseFloat(this.style.left) || 0);
    const y = this.bounds?.y ?? (parseFloat(this.style.top) || 0);
    const width = this.bounds?.w ?? (this.className === "assistant" ? 28 : parseFloat(this.style.width) || this.offsetWidth);
    const height = this.bounds?.h ?? (this.className === "assistant" ? 28 : parseFloat(this.style.height) || this.offsetHeight);
    return {x,y,left:x,top:y,width,height,right:x+width,bottom:y+height};
  }
  matches() {
    return ["BUTTON","INPUT","TEXTAREA","SELECT","LABEL","IFRAME","SUMMARY"].includes(this.tagName) ||
      this.attributes.has("tabindex") || this.attributes.has("role");
  }
  addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  closest(selector) {
    let node = this;
    while (node && node instanceof DOMElement) {
      if (selector === "[hidden]" && (node.hidden || node.attributes.has("hidden"))) return node;
      node = node.parentNode;
    }
    return null;
  }
  querySelectorAll(selector) {
    const matches = [];
    const matchesSelector = (element) => {
      if (selector === "*") return true;
      if (selector === "strong") return element.tagName === "STRONG";
      if (selector === "button") return element.tagName === "BUTTON";
      if (selector === "button:not(:disabled)") return element.tagName === "BUTTON" && !element.disabled;
      if (selector.startsWith(".")) return element.classList.contains(selector.slice(1));
      const attribute = selector.match(/^\[([\w-]+)="([^"]*)"\]$/);
      return !!attribute && element.getAttribute(attribute[1]) === attribute[2];
    };
    const visit = (node) => {
      for (const child of node.children) {
        if (matchesSelector(child)) matches.push(child);
        visit(child);
      }
    };
    visit(this);
    return matches;
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
  getRootNode() {
    let node = this;
    while (node.parentNode) node = node.parentNode;
    return node instanceof DOMShadowRoot ? node : this.ownerDocument;
  }
  focus(options) {
    this.lastFocusOptions = options || null;
    const root = this.getRootNode();
    if (root instanceof DOMShadowRoot) {
      root.activeElement = this;
      this.ownerDocument.activeElement = root.host;
    } else {
      this.ownerDocument.activeElement = this;
    }
  }
  attachShadow(options) {
    const root = new DOMShadowRoot(this.ownerDocument, this);
    this.ownerDocument.lastShadow = root;
    this.ownerDocument.lastShadowMode = options.mode;
    return root;
  }
}
class DOMShadowRoot extends DOMElement {
  constructor(ownerDocument, host) {
    super("#shadow-root", ownerDocument);
    this.host = host;
    this.activeElement = null;
  }
  getRootNode() { return this; }
}
function makeDOMDocument() {
  const document = {
    activeElement: null,
    lastShadow: null,
    lastShadowMode: null,
    layoutControls: [],
    layoutNodes: [],
    querySelectorAll(selector) { return selector === "*" ? document.layoutNodes : document.layoutControls; },
    elementsFromPoint(x,y) {
      if (document.hitTest) return document.hitTest(x,y);
      const hit = [...document.layoutControls].reverse().find(element => {
        const r = element.getBoundingClientRect();return x>=r.left && x<r.right && y>=r.top && y<r.bottom;
      });
      return hit ? [hit,document.body] : [document.body];
    },
    createElement(tagName) { return new DOMElement(tagName, document); }
  };
  document.body = new DOMElement("body", document);
  document.activeElement = document.body;
  document.contains = (node) => document.body.contains(node);
  return document;
}

const domDocument = makeDOMDocument();
const domTimers = new Map();
let domTimerID = 0;
const domContext = {
  window: { scrollX: 0, scrollY: 0, innerWidth: 900, innerHeight: 700 },
  document: domDocument,
  chrome: { runtime: { getURL: (name) => `chrome-extension://bean/${name}` } },
  setTimeout: (callback) => { const id = ++domTimerID; domTimers.set(id, callback); return id; },
  clearTimeout: (id) => domTimers.delete(id),
  requestAnimationFrame: (callback) => callback()
};
domContext.window.getComputedStyle=element=>({display:element.style.display || "block",
  pointerEvents:element.style.pointerEvents || "auto",contain:element.style.contain || "",
  contentVisibility:element.style.contentVisibility || "visible"});
vm.runInNewContext(source, domContext);
const domOverlay = domContext.window.BeanOverlay;
const issue = {
  id: "issue-1",
  issue: { original: "teh", suggestion: "the", type: "spelling" },
  rects: [{ x: 10, y: 20, w: 24, h: 16 }]
};
domOverlay.render([issue], null, null, {});
domOverlay.renderGroups([], null, {});
assert.equal(domDocument.lastShadowMode, "closed", "behavioral harness retains the security boundary");
assert.equal(domOverlay.hasKeyboardControls(), true);
assert.equal(domOverlay.focusFirstControl(), true);
const firstIssueControl = domDocument.lastShadow.activeElement;
assert.equal(firstIssueControl.dataset.beanIssue, "issue-1");
assert.equal(firstIssueControl.style.height, "6px", "underlines only capture the narrow strip below the text");
assert.equal(firstIssueControl.style.top, "30px", "the text body remains available for caret placement");

domOverlay.render([issue], null, null, {});
const rerenderedIssueControl = domDocument.lastShadow.activeElement;
assert.notEqual(rerenderedIssueControl, firstIssueControl, "render replaces the underline DOM node");
assert.equal(rerenderedIssueControl.dataset.beanIssue, "issue-1",
  "async/scroll rerender restores focus to the same semantic suggestion");
assert.equal(rerenderedIssueControl.lastFocusOptions.preventScroll, true,
  "focus restoration does not trigger another scroll/rerender cycle");

const cardHandlers = {
  onClose: () => {}, onIgnore: () => {}, onApply: () => {}, onNext: () => {},
  onDisableField: () => {}, onDisableSite: () => {}
};
domOverlay.render([issue], "issue-1", { index: 0, total: 1 }, cardHandlers);
const applyControl = domOverlay._test.keyboardControls().find((button) => button.dataset.act === "apply");
applyControl.focus();
domOverlay.render([issue], "issue-1", { index: 0, total: 1 }, cardHandlers);
assert.notEqual(domDocument.lastShadow.activeElement, applyControl);
assert.equal(domDocument.lastShadow.activeElement.dataset.act, "apply",
  "an open card preserves the same semantic action across a geometry rerender");
domOverlay.render([issue], null, null, cardHandlers);
assert.equal(domDocument.lastShadow.activeElement.dataset.beanIssue, "issue-1",
  "an async result that closes a card returns focus to that suggestion's trigger");

const replacementIssue = {
  ...issue, id: "issue-2",
  issue: { original: "recieve", suggestion: "receive", type: "spelling" }
};
domOverlay.render([replacementIssue], null, null, {});
assert.equal(domDocument.lastShadow.activeElement.dataset.beanIssue, "issue-2",
  "if a focused finding disappears, focus falls back to a current Bean control");

const group = { id: "group-1", count: 2, anchor: { x: 30, y: 40, h: 18 } };
domOverlay.renderGroups([group], null, {});
const groupControl = domOverlay._test.keyboardControls().find((button) =>
  button.dataset.beanParagraphGroup === "group-1"
);
groupControl.focus();
domOverlay.renderGroups([group], null, {});
assert.notEqual(domDocument.lastShadow.activeElement, groupControl);
assert.equal(domDocument.lastShadow.activeElement.dataset.beanParagraphGroup, "group-1",
  "paragraph-control focus survives geometry rerenders too");

const exitDirections = [];
domOverlay.setKeyboardExitHandler((direction) => { exitDirections.push(direction); });
let prevented = 0, stopped = 0;
const forwardEvent = {
  key: "Tab", shiftKey: false,
  preventDefault: () => { prevented += 1; },
  stopPropagation: () => { stopped += 1; }
};
for (const listener of domDocument.lastShadow.listeners.keydown) listener(forwardEvent);
assert.deepEqual(exitDirections, [1]);
assert.equal(prevented, 0, "forward Tab remains uncancelled for the browser's native focus algorithm");
assert.equal(stopped, 1, "the host page does not receive Bean's internal key event");

domOverlay.focusFirstControl();
const backwardEvent = {
  key: "Tab", shiftKey: true,
  preventDefault: () => { prevented += 1; },
  stopPropagation: () => { stopped += 1; }
};
for (const listener of domDocument.lastShadow.listeners.keydown) listener(backwardEvent);
assert.deepEqual(exitDirections, [1, -1]);
assert.equal(prevented, 1, "Shift-Tab is cancelled only for the explicit source-focus handoff");

const guardedEvent = {
  key: "Tab", ctrlKey: true,
  preventDefault: () => { prevented += 1; },
  stopPropagation: () => { stopped += 1; }
};
for (const listener of domDocument.lastShadow.listeners.keydown) listener(guardedEvent);
assert.deepEqual(exitDirections, [1, -1], "modified Tab never enters Bean's boundary handoff");

const anchoredCard = { offsetWidth:300, offsetHeight:120, style:{} };
domOverlay._test.anchor(anchoredCard, { x:504, y:276, h:16 });
assert.equal(anchoredCard.style.left, "354.5px",
  "paragraph progress/review anchors do not require a fake width");
assert.equal(anchoredCard.style.top, "148px");

domOverlay.clear();
domOverlay.clearAssistant();
const fieldRect = { x:50, y:100, w:400, h:90 };
let assistantReviews = 0;
domOverlay.renderAssistant(fieldRect, 3, "local", { onReview: () => { assistantReviews++; } });
const assistant = domDocument.lastShadow.querySelectorAll("button").find((button) =>
  button.dataset.beanAssistant !== undefined);
assert.ok(assistant, "a single field badge provides a predictable review entry point");
assert.match(assistant.getAttribute("aria-label"), /3 writing suggestions/);
assert.equal(assistant.style.left,"454px");
assert.equal(assistant.style.top,"162px","the entire target sits beside the source text");
assert.equal(assistant.getBoundingClientRect().width,28,"the quiet dot retains a useful hit target");
assert.equal(assistant.children.length,1);
assert.equal(assistant.children[0].className,"assistant-dot");
assert.equal(assistant.children[0].getAttribute("aria-hidden"),"true");
assert.equal(assistant.querySelectorAll("img").length,0,"the field indicator has no Bean logo or numeric pill");
assert.equal(assistant.dataset.hasIssues,"true");
assert.match(assistant.title,/3 writing suggestions/,"hover details retain the useful issue count");
for (const listener of assistant.listeners.click) listener(fakeEvent({ detail:1 }));
const assistantCard = domDocument.lastShadow.querySelector(".card");
assert.equal(assistantCard.getAttribute("aria-label"),"Bean writing assistant");
assert.ok(assistantCard.querySelector('[data-act="proofread"]'),"the same control includes one-action proofreading");
assert.ok(assistantCard.querySelector('[data-act="makeConcise"]'),"the same control includes rewriting");
for (const listener of assistantCard.querySelector('[data-act="review"]').listeners.click) listener(fakeEvent({detail:1}));
assert.equal(assistantReviews, 1);
assistant.focus();
domOverlay.renderAssistant(fieldRect, 0, "checking", {});
assert.equal(domDocument.lastShadow.activeElement.dataset.beanAssistant, "",
  "status updates preserve focus on the field assistant");
assert.match(domDocument.lastShadow.activeElement.getAttribute("aria-label"), /Checking the changed paragraph/);
assert.equal(domDocument.lastShadow.activeElement,assistant,"passive status updates retain the semantic button");
assert.equal(assistant.dataset.hasIssues,"false","no issues uses the brand brown dot");
domOverlay.renderAssistant(fieldRect, 0, "local", {});
assert.match(domDocument.lastShadow.activeElement.getAttribute("aria-label"), /Basic checks only/);
const statusAssistant = domDocument.lastShadow.activeElement;
for (const listener of statusAssistant.listeners.click) listener(fakeEvent({ detail:1 }));
assert.equal(domDocument.lastShadow.querySelector(".card").getAttribute("aria-label"), "Bean writing assistant");
const closeStatus = domDocument.lastShadow.querySelector(".card").querySelector(".x");
for (const listener of closeStatus.listeners.click) listener(fakeEvent({ detail:1 }));
for (const listener of statusAssistant.listeners.click) listener(fakeEvent({ detail:1 }));
assert.ok(domDocument.lastShadow.querySelector(".card"), "the status badge can be reopened after closing");
domOverlay.clearAssistant();
assert.equal(domDocument.lastShadow.querySelector(".assistant"), null);
domOverlay.renderAssistant({ ...fieldRect, y:1000 }, 0, "local", {});
assert.equal(domDocument.lastShadow.querySelector(".assistant"), null,
  "an off-screen editor never leaves a stray floating badge");

// Actual production DOM obstacle probes: controls, labels, unknown wrappers,
// and controls moving independently of the editor all invalidate a target.
const placementEditor=domDocument.createElement("textarea");
placementEditor.bounds={x:100,y:100,w:200,h:100};domDocument.body.appendChild(placementEditor);
const controls=firstEdges.map((bounds,index)=>{
  const button=domDocument.createElement(index===2 ? "label" : "button");
  button.bounds=bounds;return button;
});
domDocument.layoutControls=[placementEditor];
domOverlay.renderAssistant(geometryField,2,"nativeLocal",{}, {source:placementEditor});
const unobstructed=domDocument.lastShadow.querySelector(".assistant");
assert.equal(unobstructed.style.left,"304px");
domDocument.layoutControls.push(...controls);
for(const control of controls) domDocument.body.appendChild(control);
assert.equal(domOverlay.refreshAssistantPlacement(),true);
assert.deepEqual(normalized({x:parseFloat(unobstructed.style.left),y:parseFloat(unobstructed.style.top),w:28,h:28}),
  {x:304,y:142,w:28,h:28},"Send/attachment/label movement repositions the existing target");
assert.equal(domDocument.lastShadow.querySelector(".assistant"),unobstructed);
const unfamiliarWrapper=domDocument.createElement("div");
unfamiliarWrapper.bounds={x:310,y:145,w:1,h:1};
domDocument.body.appendChild(unfamiliarWrapper);
domDocument.layoutNodes=[unfamiliarWrapper];
assert.equal(domOverlay.refreshAssistantPlacement(),true);
assert.notEqual(unobstructed.style.top,"142px",
  "a thin non-semantic sibling between hit samples excludes the entire target");
domDocument.layoutNodes=[];
domDocument.hitTest=()=>[unfamiliarWrapper,domDocument.body];
assert.equal(domOverlay.refreshAssistantPlacement(),false,"an unrelated event wrapper is not proven blank space");
assert.equal(domDocument.lastShadow.querySelector(".assistant"),null);
assert.equal(domOverlay.hasFieldPresentation(),false,"no dot or findings means no field ownership");
domOverlay.render([issue],null,null,{});
assert.equal(domOverlay.hasFieldPresentation(),true,"visible underlines remain owned when the dot must hide");
domOverlay.clear();
assert.equal(domOverlay.hasFieldPresentation(),false,"an unrelated browser toolbar is not field presentation");
delete domDocument.hitTest;
domDocument.layoutControls=[placementEditor];
assert.equal(domOverlay.refreshAssistantPlacement(),true,"a later free slot can restore the dot without a draft reload");
const restoredDot=domDocument.lastShadow.querySelector(".assistant");
domDocument.hitTest=()=>[unfamiliarWrapper,domDocument.body];
for(const listener of restoredDot.listeners.click) listener(fakeEvent({detail:1}));
assert.equal(domDocument.lastShadow.querySelector(".card"),null,
  "a newly obstructed target is rejected again at activation without opening stale actions");
delete domDocument.hitTest;domDocument.layoutControls=[];domOverlay.clearAssistant();
unfamiliarWrapper.remove();placementEditor.remove();for(const control of controls)control.remove();

const visibilityEditor=domDocument.createElement("textarea");visibilityEditor.bounds=geometryField;
domDocument.body.appendChild(visibilityEditor);domDocument.layoutControls=[visibilityEditor];
const visibilityOptions={source:visibilityEditor};
const hiddenBackdrop=domDocument.createElement("div");hiddenBackdrop.bounds={x:0,y:0,w:900,h:700};
hiddenBackdrop.style.pointerEvents="none";domDocument.body.appendChild(hiddenBackdrop);
hiddenBackdrop.getBoundingClientRect=()=>{throw Error("optional untargetable wrapper bounds");};
assert.equal(domOverlay.renderAssistant(geometryField,0,"nativeLocal",{},visibilityOptions),true,
  "a non-targetable empty backdrop does not falsely suppress every field edge");
const escapedButton=domDocument.createElement("button");escapedButton.bounds={x:304,y:172,w:28,h:28};
escapedButton.style.pointerEvents="auto";hiddenBackdrop.appendChild(escapedButton);
domDocument.layoutControls.push(escapedButton);
assert.equal(domOverlay.refreshAssistantPlacement(),true);
let visibleTarget=domDocument.lastShadow.querySelector(".assistant").getBoundingClientRect();
assert.equal(disjoint({x:visibleTarget.x,y:visibleTarget.y,w:28,h:28},escapedButton.bounds),true,
  "a fixed/auto child outside a non-targetable wrapper is still fully excluded");
hiddenBackdrop.remove();domDocument.layoutControls=[visibilityEditor];
const boxlessWrapper=domDocument.createElement("div");boxlessWrapper.style.display="contents";
boxlessWrapper.getBoundingClientRect=undefined;
const boxlessChild=domDocument.createElement("div");boxlessChild.bounds={x:329,y:173,w:1,h:24};
boxlessWrapper.appendChild(boxlessChild);domDocument.body.appendChild(boxlessWrapper);
assert.equal(domOverlay.refreshAssistantPlacement(),true,"a known boxless wrapper needs only its children's complete geometry");
visibleTarget=domDocument.lastShadow.querySelector(".assistant").getBoundingClientRect();
assert.equal(disjoint({x:visibleTarget.x,y:visibleTarget.y,w:28,h:28},boxlessChild.bounds),true);
boxlessWrapper.remove();
const hiddenBranch=domDocument.createElement("div");hiddenBranch.style.display="none";
Object.defineProperty(hiddenBranch,"children",{configurable:true,get:()=>{throw Error("hidden descendants must not be visited");}});
domDocument.body.appendChild(hiddenBranch);
assert.equal(domOverlay.refreshAssistantPlacement(),true,"proven display:none branches are pruned before their children or global counts");
Object.defineProperty(hiddenBranch,"children",{value:[]});hiddenBranch.remove();
const hiddenContentHost=domDocument.createElement("div");hiddenContentHost.style.contentVisibility="hidden";
hiddenContentHost.bounds={x:310,y:177,w:1,h:1};domDocument.body.appendChild(hiddenContentHost);
assert.equal(domOverlay.refreshAssistantPlacement(),true);
visibleTarget=domDocument.lastShadow.querySelector(".assistant").getBoundingClientRect();
assert.equal(disjoint({x:visibleTarget.x,y:visibleTarget.y,w:28,h:28},hiddenContentHost.bounds),true,
  "content-visibility:hidden retains its thin host hit rectangle between the point probes");
hiddenContentHost.remove();
for (const [label,style] of [
  ["non-atomic inline paint",{display:"inline",contain:"paint"}],
  ["positive clip margin",{contain:"paint",overflowClipMargin:"100px"}],
  ["top-layer escape",{contain:"paint"}]
]) {
  const branch=domDocument.createElement("div");Object.assign(branch.style,style);
  branch.bounds={x:0,y:0,w:8,h:100};
  const child=domDocument.createElement("button");child.bounds={x:304,y:172,w:28,h:28};
  branch.appendChild(child);domDocument.body.appendChild(branch);domDocument.layoutControls.push(child);
  assert.equal(domOverlay.refreshAssistantPlacement(),true,label);
  visibleTarget=domDocument.lastShadow.querySelector(".assistant").getBoundingClientRect();
  assert.equal(disjoint({x:visibleTarget.x,y:visibleTarget.y,w:28,h:28},child.bounds),true,
    `${label} still traverses and excludes the complete escaped child`);
  branch.remove();domDocument.layoutControls=[visibilityEditor];
}
const clippedBranch=domDocument.createElement("div");clippedBranch.style.contain="paint";
clippedBranch.bounds={x:0,y:0,w:40,h:700};
for(let index=0;index<8200;index++) {
  const child=domDocument.createElement("button");child.bounds={x:0,y:0,w:0,h:0};clippedBranch.appendChild(child);
}
domDocument.body.appendChild(clippedBranch);
assert.equal(domOverlay.refreshAssistantPlacement(),false,
  "an over-budget contained subtree hides instead of assuming its complete geometry");
clippedBranch.remove();
const containedShadow=domDocument.createElement("bean-control");containedShadow.style.contain="paint";
containedShadow.bounds={x:0,y:0,w:8,h:100};domDocument.body.appendChild(containedShadow);
assert.equal(domOverlay.refreshAssistantPlacement(),false,"containment does not bypass unknown shadow/custom controls");
containedShadow.remove();
assert.equal(domOverlay.refreshAssistantPlacement(),true,"removing unverifiable geometry restores the dot without recapturing writing");
const unknownLeaf=domDocument.createElement("div");unknownLeaf.getBoundingClientRect=undefined;
domDocument.body.appendChild(unknownLeaf);
assert.equal(domOverlay.refreshAssistantPlacement(),false,"an unlocated targetable leaf still refuses unsafe placement");
unknownLeaf.remove();visibilityEditor.remove();domDocument.layoutControls=[];domOverlay.clearAssistant();

domContext.window.visualViewport={offsetLeft:80,offsetTop:90,width:200,height:180};
assert.deepEqual(normalized(domOverlay._test.assistantViewport()),{x:80,y:90,w:200,h:180});
domOverlay.renderAssistant({x:80,y:90,w:200,h:180},0,"nativeLocal",{});
assert.equal(domDocument.lastShadow.querySelector(".assistant"),null,
  "a keyboard/zoom-reduced visible viewport never clamps the hit target over its full-screen editor");
delete domContext.window.visualViewport;

// Production closed-shadow controls expose scope, deterministic Fix All,
// dictionary persistence and cancellation through real keyboard buttons.
let preparedScope=null,fixAllEvents=0;
domOverlay.renderAssistant(fieldRect,2,"nativeLocal",{actionScope:"draft",safeFixCount:2,
  onPrepareActions:(_event,scope) => {preparedScope=scope || "draft";return preparedScope;},
  onFixAll:(event) => {if(event.isTrusted) fixAllEvents++;}});
let badge=domDocument.lastShadow.querySelector(".assistant");
for(const fn of badge.listeners.click) fn(fakeEvent({detail:1,isTrusted:true}));
let unifiedCard=domDocument.lastShadow.querySelector(".card");
const paragraphScope=unifiedCard.querySelector('[data-act="scopeParagraph"]');
for(const fn of paragraphScope.listeners.click) fn(fakeEvent({detail:1,isTrusted:false}));
assert.equal(preparedScope,"draft","synthetic page activation cannot change captured scope");
for(const fn of paragraphScope.listeners.click) fn(fakeEvent({detail:1,isTrusted:true}));
assert.equal(preparedScope,"paragraph");
assert.equal(paragraphScope.getAttribute("aria-pressed"),"true");
assert.match(unifiedCard.querySelector('[data-act="proofread"]').textContent,/current paragraph/);
assert.ok(unifiedCard.querySelector('[data-act="fixAll"]'));
for(const fn of unifiedCard.querySelector('[data-act="fixAll"]').listeners.click) fn(fakeEvent({detail:1,isTrusted:true}));
assert.equal(fixAllEvents,1);
const proofreadFocus=unifiedCard.querySelector('[data-act="proofread"]');
proofreadFocus.focus();
assert.equal(domOverlay._test.keyboardFocusToken().kind,"assistantCard");
assert.equal(domOverlay._test.keyboardFocusToken().action,"proofread");
domOverlay.render([],null,null,{});
domOverlay.renderGroups([],null,{});
let latestAction=null;
domOverlay.renderAssistant({...fieldRect,y:110},0,"localLimited",{actionScope:"draft",safeFixCount:0,
  onWritingAction:(action) => {latestAction=action;}});
assert.equal(domDocument.lastShadow.querySelector(".card"),unifiedCard,
  "passive findings/status updates preserve the same expanded assistant DOM identity");
assert.equal(domDocument.lastShadow.activeElement,proofreadFocus,
  "empty local results cannot strand focus on the page body");
assert.match(unifiedCard.querySelector("strong").textContent,/Basic checks/);
assert.match(proofreadFocus.textContent,/current paragraph/,
  "passive status refresh retains the exact action scope captured within the open assistant");
assert.equal(unifiedCard.querySelector('[data-act="review"]').hidden,true);
assert.equal(unifiedCard.querySelector('[data-part="fixAllGroup"]').hidden,true);
for(const fn of proofreadFocus.listeners.click) fn(fakeEvent({detail:1,isTrusted:true}));
assert.equal(latestAction,"proofread","retained controls invoke the latest source-bound handlers");
const conciseFocus=unifiedCard.querySelector('[data-act="makeConcise"]');conciseFocus.focus();
domOverlay.renderAssistant(fieldRect,2,"nativeLocal",{actionScope:"draft",safeFixCount:1});
assert.equal(domDocument.lastShadow.activeElement,conciseFocus,"rewriting action focus survives updated findings");
assert.equal(unifiedCard.querySelector('[data-act="review"]').hidden,false);
assert.equal(unifiedCard.querySelector('[data-part="fixAllGroup"]').hidden,false);
assert.match(unifiedCard.querySelector('[data-act="fixAll"]').textContent,/Fix 1 obvious issue/);
const scopeFocus=unifiedCard.querySelector('[data-act="scopeParagraph"]');scopeFocus.focus();
domOverlay.render([],null,null,{});domOverlay.renderAssistant(fieldRect,0,"nativeLocal",{});
assert.equal(domDocument.lastShadow.activeElement,scopeFocus,"scope selector focus survives passive rerender");
domOverlay.clear();
assert.equal(domDocument.lastShadow.querySelector(".card"),null,
  "explicit typing/field invalidation removes the retained assistant and its captured scope");
domOverlay.clearAssistant();
domOverlay.renderAssistant(fieldRect,0,"nativeLocal",{actionScope:"selection",onPrepareActions:() => "selection"});
badge=domDocument.lastShadow.querySelector(".assistant");
for(const fn of badge.listeners.click) fn(fakeEvent({detail:1,isTrusted:true}));
unifiedCard=domDocument.lastShadow.querySelector(".card");
assert.equal(unifiedCard.querySelector(".scope").hidden,true,"selected-text scope cannot silently widen to the draft");
assert.match(source,/\.scope\[hidden\]\s*\{\s*display:none\s*;/,
  "selected-text scope must override the author display:flex rule in rendered browsers");
assert.match(unifiedCard.querySelector('[data-act="proofread"]').textContent,/selected text/);
domOverlay.clearAssistant();
let learnedActivations=0;
domOverlay.render([replacementIssue],replacementIssue.id,{index:0,total:1},{learnWordAvailable:true,
  onLearnWord:(id,event) => {assert.equal(id,replacementIssue.id);if(event.isTrusted) learnedActivations++;}});
let learnControl=domDocument.lastShadow.querySelector('[data-act="learn"]');
assert.equal(learnControl.disabled,false);
for(const fn of learnControl.listeners.click) fn(fakeEvent({detail:1,isTrusted:true}));
assert.equal(learnedActivations,1);
domOverlay.render([replacementIssue],replacementIssue.id,{index:0,total:1},{learnWordAvailable:false});
learnControl=domDocument.lastShadow.querySelector('[data-act="learn"]');
assert.equal(learnControl.disabled,true);
assert.match(learnControl.title,/Open Bean/);
assert.match(source,/\.alternatives\s*\{[^}]*flex-wrap:wrap/,
  "spelling choices wrap inside their correction card at narrow viewport widths");
assert.match(source,/\.alternatives button\.b\s*\{[^}]*max-width:100%[^}]*overflow-wrap:anywhere/,
  "a long spelling choice remains bounded by its own card rather than the viewport");
assert.match(source,/\.card\s*\{[^}]*max-height:calc\(100vh - 16px\)[^}]*overflow:auto/,
  "long corrections remain scrollable inside a short viewport");
domOverlay.clear();
let cancellations=0;
domOverlay.showParagraphBusy(fieldRect,"Rewriting…",(event) => {if(event.isTrusted) cancellations++;});
const cancelControl=domOverlay._test.keyboardControls().find((button) => button.dataset.act === "cancel");
assert.ok(cancelControl,"busy writing actions expose an actual reachable Cancel button");
for(const fn of cancelControl.listeners.click) fn(fakeEvent({detail:1,isTrusted:true}));
assert.equal(cancellations,1);
domOverlay.clearParagraphBusy();

assert.match(source, /createElement\("img"\)/, "paragraph controls use the official Bean mark");
assert.match(source, /getURL\("icon128\.png"\)/);
assert.doesNotMatch(source, /icon\.textContent\s*=\s*String/, "the old numbered dot is removed");
assert.match(source, /attachShadow\(\{ mode: "closed" \}\)/,
  "host pages cannot query and programmatically activate Bean controls");
assert.match(source, /setAttribute\("role", "dialog"\)/);
assert.match(source, /setAttribute\("aria-modal", "true"\)/);
assert.match(source, /className = "modal-shield"/, "the modal review blocks background pointer interaction");
assert.match(source, /aria-labelledby", "bean-paragraph-review-title"/);
assert.match(source, /setAttribute\("aria-live", "polite"\)/);
assert.match(source, /event\.key === "Escape"/);
assert.match(source, /event\.stopPropagation\(\)/, "dialog Escape does not also clear every highlight");
assert.match(source, /aria-haspopup="menu"/);
assert.match(source, /Disable on this field/);
assert.match(source, /Disable on this website/);
assert.match(source, /dataset\.beanUndoScope/);
assert.match(source, /Bean is off for this field/);
assert.match(source, /Re-enable/);
assert.match(source, /showParagraphBusy/);
assert.match(source, /clearParagraphBusy/);
assert.match(source, /mousedown.*preventDefault/, "Undo keeps the source field focused on pointer use");
assert.match(source, /prefers-reduced-motion/);
assert.match(source, /forced-colors/);
assert.match(source, /button:focus-visible\s*\{[^}]*outline:3px solid var\(--bean-accent\)/s,
  "focus rings use the opaque high-contrast accent");

const contentSource = fs.readFileSync(path.join(__dirname, "..", "src", "contentScript.js"), "utf8");
assert.match(contentSource, /dataset\.beanKeyboardBridge/, "the active editor gets a keyboard focus bridge");
assert.match(contentSource, /BeanOverlay\.focusFirstControl\(\)/,
  "the bridge transfers focus into the closed Shadow DOM without exposing actions to the page");
assert.match(contentSource, /setKeyboardExitHandler\(exitKeyboardOverlay\)/,
  "overlay boundary Tab returns to the editor or continues through the page");
assert.doesNotMatch(contentSource, /compareDocumentPosition|querySelectorAll\(selector\)/,
  "Bean never hand-reimplements the browser's sequential focus algorithm");
assert.match(contentSource, /removeKeyboardBridge\(\);[\s\S]*restoreFieldFocus\(source\)/,
  "forward exit temporarily removes Bean before handing native Tab back to the source");
assert.match(contentSource, /state\.active\.isContentEditable && keyboardBridgeEl/,
  "capture fallback is limited to rich editors with an actual Bean bridge");
assert.match(contentSource, /!e\.defaultPrevented[\s\S]*!e\.ctrlKey[\s\S]*!e\.isComposing/,
  "rich-editor fallback preserves cancelled, modified, and composing Tab events");

console.log("Browser extension overlay accessibility tests passed");
