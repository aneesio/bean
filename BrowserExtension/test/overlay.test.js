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
