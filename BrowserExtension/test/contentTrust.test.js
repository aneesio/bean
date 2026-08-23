const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "src", "contentScript.js"), "utf8");

// Source-level lifecycle contract: an ineligible contenteditable block returns
// before the text-bearing paragraph bridge call, and paragraphTarget repeats the
// same eligibility guard before replacement. Combined with the behavioral
// trust-policy test for <br>, this proves no paid request or whole-block write is
// attempted for a coordinate-mismatched block.
const fixParagraphSource = source.slice(
  source.indexOf("async function fixParagraph"),
  source.indexOf("function flashAt")
);
assert.ok(fixParagraphSource.indexOf("if (!g.canFix)") >= 0);
assert.ok(fixParagraphSource.indexOf("if (!g.canFix)") < fixParagraphSource.indexOf("bridgeProofreadParagraph(sent"),
  "contenteditable eligibility is enforced before a paragraph provider call");
const paragraphTargetSource = source.slice(
  source.indexOf("function paragraphTarget"),
  source.indexOf("function rememberCorrected")
);
assert.ok(paragraphTargetSource.includes("!ceBlockReplaceable(block)"),
  "contenteditable eligibility is rechecked at the replacement boundary");

async function run() {
  const documentListeners = {};
  const elementListeners = {};
  const timers = new Map();
  const bridgeMessages = [];
  const localChecks = [];
  const extraFields = new Set();
  const savedSettings = { blockedSites: [] };
  const flashMessages = [];
  const busyEvents = [];
  let timerID = 0;
  let storageGetFailure = false;
  let storageSetFailure = false;
  let storageChangedListener = null;
  let delayProofread = false;
  let pendingProofreadCallback = null;
  let delayDetect = false;
  let pendingDetectCallback = null;
  let delayStatus = false;
  let pendingStatusCallback = null;
  let runtimeMessageListener = null;
  let bridgeDetectedIssues = [];
  let automaticAccountingAvailable = true;
  let fieldPresent = true;
  let now = 1_000_000;
  const domNodes = new Set();
  const fieldParent = {
    children: [],
    insertBefore(node, reference) {
      if (node.parentNode && typeof node.remove === "function") node.remove();
      const index = reference ? this.children.indexOf(reference) : -1;
      if (index >= 0) this.children.splice(index, 0, node);
      else this.children.push(node);
      node.parentNode = this;
      domNodes.add(node);
      return node;
    }
  };

  const field = {
    nodeType: 1,
    tagName: "TEXTAREA",
    type: "textarea",
    value: "first old\nsecond old\nthird old",
    selectionStart: 0,
    isContentEditable: false,
    disabled: false,
    readOnly: false,
    tabIndex: 0,
    offsetParent: {},
    parentNode: fieldParent,
    closest: () => null,
    contains: () => false,
    getAttribute: () => null,
    getBoundingClientRect: () => ({ left: 10, top: 10, width: 400, height: 120 }),
    addEventListener: (name, listener) => { elementListeners[name] = listener; },
    removeEventListener: (name) => { delete elementListeners[name]; },
    dispatchEvent: (event) => { if (elementListeners[event.type]) elementListeners[event.type](event); },
    setSelectionRange: (start, end) => { field.selectionStart = start; field.selectionEnd = end; },
    focus: () => { document.activeElement = field; }
  };
  fieldParent.children.push(field);
  Object.defineProperty(field, "nextSibling", {
    configurable: true,
    get: () => {
      const index = fieldParent.children.indexOf(field);
      return index >= 0 ? fieldParent.children[index + 1] || null : null;
    }
  });

  const document = {
    documentElement: { dataset: {} },
    activeElement: field,
    addEventListener: (name, listener) => { documentListeners[name] = listener; },
    removeEventListener: () => {},
    contains: (node) => (node === field && fieldPresent) || extraFields.has(node) || domNodes.has(node),
    createElement: (tagName) => {
      const listeners = {};
      const node = {
        nodeType: 1,
        tagName: String(tagName).toUpperCase(),
        tabIndex: -1,
        dataset: {},
        style: {},
        parentNode: null,
        attributes: new Map(),
        addEventListener: (name, listener) => { listeners[name] = listener; },
        setAttribute: (name, value) => { node.attributes.set(name, String(value)); },
        getAttribute: (name) => node.attributes.get(name) || null,
        focus: () => {
          document.activeElement = node;
          if (listeners.focus) listeners.focus({ target: node });
        },
        remove: () => {
          if (node.parentNode) {
            node.parentNode.children = node.parentNode.children.filter((child) => child !== node);
          }
          node.parentNode = null;
          domNodes.delete(node);
        }
      };
      return node;
    }
  };
  const window = {
    scrollX: 0,
    scrollY: 0,
    addEventListener: () => {}
  };
  const chrome = {
    storage: {
      local: {
        get: (_keys, callback) => {
          if (storageGetFailure) {
            chrome.runtime.lastError = { message: "simulated storage read failure" };
            callback({});
            chrome.runtime.lastError = null;
            return;
          }
          callback({
            // A retired global bridge switch must not disable local checks.
            ...savedSettings, useBridge: false, settingsSchemaVersion: 1
          });
        },
        set: (values, callback) => {
          if (storageSetFailure) {
            chrome.runtime.lastError = { message: "simulated storage failure" };
            callback();
            chrome.runtime.lastError = null;
            return;
          }
          Object.assign(savedSettings, values);
          callback();
        }
      },
      onChanged: { addListener: (listener) => { storageChangedListener = listener; } }
    },
    runtime: {
      id: "bean-extension-id",
      onMessage: { addListener: (listener) => { runtimeMessageListener = listener; } },
      sendMessage: (message, callback) => {
        bridgeMessages.push(message);
        if (message.type === "getStatus" && delayStatus) {
          pendingStatusCallback = callback;
        } else if (message.type === "getStatus") {
          callback({
            ok: true,
            bridgeAvailable: true,
            protocolVersion: 1,
            compatible: true,
            providerConfigured: true,
            webInlineEnabled: true,
            automaticAccountingAvailable
          });
        } else if (message.type === "proofreadParagraph" && delayProofread) {
          pendingProofreadCallback = callback;
        } else if (message.type === "proofreadParagraph") {
          callback({ ok: true, text: message.request.text, reviewRequired: false });
        } else if (message.type === "detectIssues" && delayDetect) {
          pendingDetectCallback = callback;
        } else if (message.type === "mutateBlockedSites") {
          if (storageSetFailure) {
            callback({ ok: false, errorCode: "settingsUnavailable" });
          } else {
            savedSettings.blockedSites = [...new Set([
              ...savedSettings.blockedSites,
              location.hostname
            ])].sort();
            callback({
              ok: true,
              blockedSites: [...savedSettings.blockedSites],
              registrationUpdated: true
            });
          }
        } else if (message.type === "refreshRegistration") {
          callback({ ok: true });
        } else {
          callback({ ok: true, issues: bridgeDetectedIssues });
        }
      },
      lastError: null
    }
  };
  let detectedIssues = [];
  const BeanDetector = {
    detect: (text) => { localChecks.push(text); return detectedIssues; },
    fixObvious: (text) => text
  };
  const BeanTrustPolicy = {
    boundedChangedBlock: (text, caret, limit) => {
      const start = text.lastIndexOf("\n", Math.max(0, caret - 1)) + 1;
      let end = text.indexOf("\n", caret);
      if (end < 0) end = text.length;
      const scoped = text.slice(start, Math.min(end, start + limit));
      return scoped.trim() ? { text: scoped, start, end: start + scoped.length } : null;
    },
    mergeIssues: (local, provider) => [...local, ...provider],
    isMeaningfulEdit: (before, after) => before !== after,
    BRIDGE_PROTOCOL_VERSION: 1,
    bridgeReadiness: (status) => ({
      ready: !!status && status.ok === true && status.bridgeAvailable === true &&
        status.protocolVersion === 1 && status.compatible !== false &&
        status.providerConfigured === true && status.webInlineEnabled === true &&
        status.automaticAccountingAvailable === true,
      code: status && status.ok === true && status.bridgeAvailable === true &&
        status.protocolVersion === 1 && status.compatible !== false &&
        status.providerConfigured === true && status.webInlineEnabled === true &&
        status.automaticAccountingAvailable === true
        ? "bridgeReady" : "bridgeProtocolIncompatible"
    })
  };
  const BeanMapping = {
    uniqueOffset: (text, original) => {
      const start = text.indexOf(original);
      return start >= 0 && text.indexOf(original, start + 1) < 0
        ? { start, end: start + original.length } : null;
    },
    rectsForRange: () => [{ x: 10, y: 10, w: 40, h: 16 }],
    hasMatchingLineBreakStructure: (original, replacement) => {
      const signature = (value) => value.match(/\r\n|[\r\n\u2028\u2029]/g) || [];
      const before = signature(original), after = signature(replacement);
      return before.length === after.length && before.every((value, index) => value === after[index]);
    },
    replaceRangePreservingBoundaries: (text, start, end, replacement) => {
      if (start < 0 || end < start || end > text.length ||
          !BeanMapping.hasMatchingLineBreakStructure(text.slice(start, end), replacement)) return null;
      return text.slice(0, start) + replacement + text.slice(end);
    },
    applyTextControlRange: (el, start, end, replacement) => {
      el.value = el.value.slice(0, start) + replacement + el.value.slice(end);
      el.dispatchEvent({ type: "input", isTrusted: false, isComposing: false });
      el.dispatchEvent({ type: "change", isTrusted: false, isComposing: false });
      return { ok: true, nativeUndoPreserved: false, inputEventVerified: true, changeEventVerified: true };
    },
    sanitizeProofreadParagraphOutput: (text) => ({ text, zeroWidthStripped: 0 })
  };
  let renderHandlers = null;
  let groupHandlers = null;
  let undoOffer = null;
  let disabledFieldOptions = null;
  let paragraphBusy = false;
  let reviewResult = false;
  let renderedEntries = [];
  let keyboardExitHandler = null;
  let overlayFocusCount = 0;
  const reviewCalls = [];
  const BeanOverlay = {
    clear: () => { paragraphBusy = false; renderedEntries = []; },
    clearUndo: () => {},
    render: (entries, _selected, _position, handlers) => {
      renderedEntries = entries;
      renderHandlers = handlers;
    },
    renderGroups: (_groups, _selected, handlers) => { groupHandlers = handlers; },
    flash: (_rect, message) => { flashMessages.push(message); },
    showParagraphBusy: (_rect, message) => {
      paragraphBusy = true;
      busyEvents.push(["show", message]);
    },
    clearParagraphBusy: () => {
      paragraphBusy = false;
      busyEvents.push(["clear"]);
    },
    showUndo: (options, handler) => { undoOffer = { options, handler }; },
    setFieldDisabled: (disabled, options) => { disabledFieldOptions = disabled ? options : null; },
    reviewParagraph: async (...args) => { reviewCalls.push(args); return reviewResult; },
    hasKeyboardControls: () => renderedEntries.length > 0,
    focusFirstControl: () => {
      if (!renderedEntries.length) return false;
      overlayFocusCount += 1;
      document.activeElement = { id: "bean-inline-host", dataset: { bean: "overlay" } };
      return true;
    },
    setKeyboardExitHandler: (handler) => { keyboardExitHandler = handler; }
  };
  const setTimeout = (callback) => { const id = ++timerID; timers.set(id, callback); return id; };
  const clearTimeout = (id) => timers.delete(id);
  const runTimers = () => {
    const pending = Array.from(timers.values());
    timers.clear();
    for (const callback of pending) callback();
  };
  const settle = async () => {
    for (let i = 0; i < 6; i++) await Promise.resolve();
  };
  const challenge = (requestId, sender = { id: "bean-extension-id" }) => {
    let response = null;
    const result = runtimeMessageListener(
      { type: "revalidateTextRequest", requestId }, sender,
      (value) => { response = value; }
    );
    assert.equal(result, false, "the content-free challenge responds synchronously");
    return response;
  };
  const restoreEligibleField = () => {
    fieldPresent = true;
    field.nodeType = 1;
    field.tagName = "TEXTAREA";
    field.type = "textarea";
    field.isContentEditable = false;
    field.disabled = false;
    field.readOnly = false;
    field.offsetParent = {};
    field.closest = () => null;
    field.getAttribute = () => null;
  };
  const ineligibleMutations = [
    ["disabled", () => { field.disabled = true; }],
    ["read-only", () => { field.readOnly = true; }],
    ["password", () => { field.tagName = "INPUT"; field.type = "password"; }],
    ["one-time code", () => {
      field.tagName = "INPUT";
      field.type = "text";
      field.getAttribute = (name) => name === "autocomplete" ? "one-time-code" : null;
    }],
    ["contenteditable=false", () => {
      field.tagName = "DIV";
      field.type = "";
      field.isContentEditable = false;
      field.getAttribute = (name) => name === "contenteditable" ? "false" : null;
    }]
  ];

  const context = {
    window, document, chrome, BeanDetector, BeanTrustPolicy, BeanMapping, BeanOverlay,
    Node: { ELEMENT_NODE: 1 }, location: { hostname: "example.com", host: "example.com", pathname: "/" },
    Event: function Event() {}, Date: { now: () => now }, Math, Promise, Set, WeakSet, Map, Object, Array,
    setTimeout, clearTimeout
  };
  window.window = window;
  vm.runInNewContext(source, context);

  runTimers();
  await settle();
  assert.deepEqual(localChecks, [field.value], "an already-autofocused field runs the offline detector");
  assert.equal(bridgeMessages.length, 0, "focus with existing text never sends page text");

  documentListeners.focusout({ target: { id: "bean-inline-host" }, relatedTarget: null });
  assert.equal(typeof elementListeners.input, "function",
    "focus leaving a temporary Bean control does not deactivate the writing field");
  documentListeners.focusout({
    target: field,
    relatedTarget: { getRootNode: () => ({ host: { id: "bean-inline-host" } }) }
  });
  assert.equal(typeof elementListeners.input, "function",
    "focus entering a control inside Bean's shadow root preserves the source field");
  document.activeElement = { id: "bean-inline-host" };
  documentListeners.focusin({
    target: { id: "bean-inline-host" },
    composedPath: () => [{ id: "bean-inline-host", dataset: { bean: "overlay" } }]
  });
  assert.equal(typeof elementListeners.input, "function",
    "focus entering Bean UI is not mistaken for an unsupported page field");
  documentListeners.focusout({ target: field, relatedTarget: null });
  runTimers();
  assert.equal(typeof elementListeners.input, "function",
    "a null relatedTarget is rechecked after shadow focus settles");
  document.activeElement = field;

  field.value = "first old\nsecond edited\nthird old";
  field.selectionStart = field.value.indexOf("\nthird old");
  elementListeners.input({ isTrusted: true, isComposing: false });
  runTimers();
  await settle();
  assert.equal(bridgeMessages.length, 2, "a trusted edit performs a content-free status check before AI");
  assert.equal(bridgeMessages[0].type, "getStatus");
  assert.equal(Object.hasOwn(bridgeMessages[0], "request"), false, "status handshake contains no page text");
  assert.equal(bridgeMessages[1].type, "detectIssues");
  assert.equal(bridgeMessages[1].request.text, "second edited", "only the changed line crosses the bridge");
  assert.equal(bridgeMessages[1].request.settings.maxIssues, 8,
    "AI may fill the full visible budget when local detection found nothing");
  assert.notEqual(bridgeMessages[1].request.text, field.value, "the whole field is never sent");

  // Broken accounting blocks only paid provider work. Offline detection still
  // runs and its local result remains visible without forwarding text.
  now += 16000;
  automaticAccountingAvailable = false;
  detectedIssues = [
    { original: "localword", suggestion: "local word", type: "spacing" }
  ];
  field.value = "localword changed while accounting is unavailable";
  field.selectionStart = field.value.length;
  const localChecksBeforeAccountingFailure = localChecks.length;
  const providerRequestsBeforeAccountingFailure = bridgeMessages
    .filter((message) => message.type === "detectIssues").length;
  elementListeners.input({ isTrusted: true, isComposing: false });
  runTimers();
  await settle();
  assert.equal(localChecks.length, localChecksBeforeAccountingFailure + 1,
    "accounting failure never disables the offline detector");
  assert.equal(bridgeMessages.filter((message) => message.type === "detectIssues").length,
    providerRequestsBeforeAccountingFailure,
    "accounting failure blocks page text before the provider request");
  assert.equal(renderedEntries.some((entry) => entry.issue.original === "localword"), true,
    "the local suggestion remains visible when provider accounting is unavailable");
  automaticAccountingAvailable = true;
  detectedIssues = [];
  now += 300001;

  const messagesBeforeSyntheticInput = bridgeMessages.length;
  field.value = "first old\nscript changed\nthird old";
  field.selectionStart = field.value.indexOf("\nthird old");
  elementListeners.input({ isTrusted: false, isComposing: false });
  runTimers();
  await settle();
  assert.equal(bridgeMessages.length, messagesBeforeSyntheticInput,
    "synthetic page input resets AI eligibility");

  // A page may change field semantics while the content-free status handshake
  // is running. Revalidate immediately before constructing the text request.
  now += 16000;
  delayStatus = true;
  field.value = "ordinary prose changed";
  field.selectionStart = field.value.length;
  elementListeners.input({ isTrusted: true, isComposing: false });
  runTimers();
  await settle();
  assert.equal(typeof pendingStatusCallback, "function");
  const messagesAtDelayedStatus = bridgeMessages.length;
  field.getAttribute = (name) => name === "autocomplete" ? "one-time-code" : null;
  pendingStatusCallback({
    ok: true,
    bridgeAvailable: true,
    protocolVersion: 1,
    compatible: true,
    providerConfigured: true,
    webInlineEnabled: true,
    automaticAccountingAvailable: true
  });
  await settle();
  assert.equal(bridgeMessages.length, messagesAtDelayedStatus,
    "a field that becomes sensitive during status never sends its captured text");
  delayStatus = false;
  pendingStatusCallback = null;
  field.getAttribute = () => null;
  document.activeElement = field;
  documentListeners.focusin({ target: field, composedPath: () => [field] });

  // OTP widgets may add sensitive semantics only after focus. The next input
  // must re-evaluate the field before even the offline detector reads it.
  const checksBeforeDynamicOTP = localChecks.length;
  const messagesBeforeDynamicOTP = bridgeMessages.length;
  const activeInputBeforeDynamicOTP = elementListeners.input;
  field.getAttribute = (name) => name === "autocomplete" ? "one-time-code" : null;
  field.value = "123456";
  activeInputBeforeDynamicOTP({ isTrusted: true, isComposing: false });
  runTimers();
  await settle();
  assert.equal(localChecks.length, checksBeforeDynamicOTP,
    "a field that becomes an OTP control is dropped before local inspection");
  assert.equal(bridgeMessages.length, messagesBeforeDynamicOTP,
    "a field that becomes an OTP control never crosses the bridge");
  field.getAttribute = () => null;

  async function beginDelayedDetection(value, localIssues = []) {
    restoreEligibleField();
    fieldPresent = true;
    document.activeElement = field;
    documentListeners.focusin({ target: field, composedPath: () => [field] });
    detectedIssues = localIssues;
    bridgeDetectedIssues = [];
    delayDetect = true;
    pendingDetectCallback = null;
    now += 16000;
    field.value = value;
    field.selectionStart = value.length;
    elementListeners.input({ isTrusted: true, isComposing: false });
    runTimers();
    await settle();
    assert.equal(typeof pendingDetectCallback, "function", "the provider issue callback is pending");
    const request = bridgeMessages.filter((message) => message.type === "detectIssues").at(-1).request;
    return { request, callback: pendingDetectCallback };
  }

  // The background's last pre-native step is a content-free challenge targeted
  // to this exact document. It is single-use and re-proves the same active field,
  // generation, changed block, and text without echoing any text in its response.
  let delayed = await beginDelayedDetection("exact document challenge text");
  const acceptedChallenge = challenge(delayed.request.id);
  assert.equal(acceptedChallenge.ok, true);
  assert.equal(acceptedChallenge.requestId, delayed.request.id);
  const replayedChallenge = challenge(delayed.request.id);
  assert.equal(replayedChallenge.ok, false, "a text authorization cannot be replayed");
  assert.equal(replayedChallenge.requestId, delayed.request.id);
  delayed.callback({ ok: true, issues: [] });
  await settle();

  delayed = await beginDelayedDetection("text changes before native send");
  field.value += "!";
  assert.equal(challenge(delayed.request.id).ok, false,
    "changed field text invalidates the final authorization");
  delayed.callback({ ok: false, errorCode: "sourceNoLongerCurrent" });
  await settle();

  delayed = await beginDelayedDetection("field disappears before native send");
  fieldPresent = false;
  assert.equal(challenge(delayed.request.id).ok, false,
    "a removed source field cannot authorize captured text");
  delayed.callback({ ok: false, errorCode: "sourceNoLongerCurrent" });
  await settle();
  fieldPresent = true;

  delayed = await beginDelayedDetection("field becomes a one time code");
  field.tagName = "INPUT";
  field.type = "text";
  field.getAttribute = (name) => name === "autocomplete" ? "one-time-code" : null;
  assert.equal(challenge(delayed.request.id).ok, false,
    "a newly sensitive source field cannot authorize captured text");
  delayed.callback({ ok: false, errorCode: "sourceNoLongerCurrent" });
  await settle();

  delayed = await beginDelayedDetection("input invalidates pending authorization");
  elementListeners.input({ isTrusted: false, isComposing: false });
  assert.equal(challenge(delayed.request.id).ok, false,
    "any newer input invalidates the pending authorization");
  delayed.callback({ ok: false, errorCode: "sourceNoLongerCurrent" });
  await settle();

  delayed = await beginDelayedDetection("authorization expires before challenge");
  now += 10001;
  assert.equal(challenge(delayed.request.id).ok, false,
    "an expired authorization fails closed");
  delayed.callback({ ok: false, errorCode: "sourceNoLongerCurrent" });
  await settle();
  delayDetect = false;
  pendingDetectCallback = null;

  // Even if a compromised/older background returned a delayed provider result
  // without the final challenge, a newly sensitive field is torn down instead of
  // receiving provider highlights.
  delayed = await beginDelayedDetection("localword providerword", [
    { original: "localword", suggestion: "local word", type: "spacing" }
  ]);
  assert.equal(renderedEntries.length, 1, "the eligible local issue is visible while AI is pending");
  field.getAttribute = (name) => name === "autocomplete" ? "one-time-code" : null;
  delayed.callback({
    ok: true,
    issues: [{ original: "providerword", suggestion: "provider word", type: "spacing" }]
  });
  await settle();
  assert.equal(renderedEntries.length, 0,
    "a delayed issue result cannot render after the field becomes sensitive");
  delayDetect = false;
  pendingDetectCallback = null;
  restoreEligibleField();

  const checksBeforeStaticExclusions = localChecks.length;
  for (const excluded of [
    { ...field, tagName: "INPUT", type: "search", value: "private search" },
    { ...field, closest: (selector) => selector.includes("[role='searchbox']") ? {} : null,
      value: "semantic private search" },
    { ...field, tagName: "INPUT", type: "text", value: "123456",
      getAttribute: (name) => name === "autocomplete" ? "one-time-code" : null },
    { ...field, tagName: "INPUT", type: "text", value: "4111111111111111",
      getAttribute: (name) => name === "autocomplete" ? "section-checkout shipping cc-number" : null },
    { ...field, tagName: "INPUT", type: "text", value: "123456",
      getAttribute: (name) => name === "inputmode" ? "numeric" : null },
    { ...field, tagName: "INPUT", type: "text", value: "123456",
      getAttribute: (name) => name === "pattern" ? "[0-9]{6}" : null },
    { ...field, tagName: "INPUT", type: "text", value: "123456",
      getAttribute: (name) => name === "aria-label" ? "Verification code" : null },
    { ...field, readOnly: true, value: "fixed text" },
    { ...field, closest: (selector) => selector.includes(".CodeMirror") ? {} : null, value: "const teh = 1" }
  ]) {
    documentListeners.focusin({ target: excluded });
    runTimers();
    await settle();
  }
  assert.equal(localChecks.length, checksBeforeStaticExclusions,
    "search, credential/card/code semantics, read-only text, and code editors never run a check");

  // AI receives only the unused visible slots, unsafe provider line breaks are
  // discarded, and a full local result never incurs a provider request.
  now += 16000;
  field.value = "localone localtwo target text";
  field.selectionStart = field.value.length;
  detectedIssues = [
    { original: "localone", suggestion: "local one", type: "spacing" },
    { original: "localtwo", suggestion: "local two", type: "spacing" }
  ];
  bridgeDetectedIssues = [
    { original: "target", suggestion: "target\nleak", type: "grammar" }
  ];
  document.activeElement = field;
  documentListeners.focusin({ target: field, composedPath: () => [field] });
  field.value += "!";
  field.selectionStart = field.value.length;
  elementListeners.input({ isTrusted: true, isComposing: false });
  runTimers();
  await settle();
  const remainingSlotsRequest = bridgeMessages.filter((message) => message.type === "detectIssues").at(-1);
  assert.equal(remainingSlotsRequest.request.settings.maxIssues, 6,
    "provider issue count is capped to the slots not already used locally");
  assert.equal(renderedEntries.length, 2,
    "a provider suggestion that introduces a line break is never rendered or applicable");

  // DOM-level keyboard contract. Text controls keep native Tab, whose next stop
  // is the adjacent bridge. Only rich contenteditables use the capture fallback;
  // modified/composing/cancelled keys stay with the page. Forward exit removes
  // the bridge just long enough for the browser to choose its own next target.
  now += 16000;
  restoreEligibleField();
  field.tabIndex = 7;
  field.value = "please recieve now";
  field.selectionStart = field.value.length;
  detectedIssues = [{ original: "recieve", suggestion: "receive", type: "spelling" }];
  bridgeDetectedIssues = [];
  document.activeElement = field;
  documentListeners.focusin({ target: field, composedPath: () => [field] });
  elementListeners.input({ isTrusted: false, isComposing: false });
  runTimers();
  await settle();
  const currentKeyboardBridge = () => fieldParent.children.find((node) =>
    node.dataset && Object.hasOwn(node.dataset, "beanKeyboardBridge")
  ) || null;
  let keyboardBridge = currentKeyboardBridge();
  assert.ok(keyboardBridge, "a rendered suggestion inserts a real adjacent focus bridge");
  assert.equal(fieldParent.children.indexOf(keyboardBridge), fieldParent.children.indexOf(field) + 1,
    "the bridge occupies the native sequential position immediately after its editor");
  assert.equal(keyboardBridge.tabIndex, 7,
    "positive tabindex is mirrored only for native ordering; Bean never computes the next target");

  const keyEvent = (overrides = {}) => {
    const record = { prevented: 0, stopped: 0 };
    return {
      event: {
        key: "Tab", target: field, shiftKey: false, ctrlKey: false, metaKey: false,
        altKey: false, isComposing: false, defaultPrevented: false,
        composedPath: () => [field],
        preventDefault: () => { record.prevented += 1; },
        stopPropagation: () => { record.stopped += 1; },
        ...overrides
      },
      record
    };
  };

  const overlayFocusBeforeTextTab = overlayFocusCount;
  const nativeTextTab = keyEvent();
  documentListeners.keydown(nativeTextTab.event);
  assert.equal(overlayFocusCount, overlayFocusBeforeTextTab,
    "textarea Tab is never captured before the browser reaches the bridge");
  assert.deepEqual(nativeTextTab.record, { prevented: 0, stopped: 0 });
  keyboardBridge.focus();
  assert.equal(overlayFocusCount, overlayFocusBeforeTextTab + 1,
    "native focus on the adjacent bridge transfers into Bean's closed controls");

  field.focus();
  field.isContentEditable = true;
  for (const override of [
    { defaultPrevented: true }, { ctrlKey: true }, { metaKey: true },
    { altKey: true }, { isComposing: true }
  ]) {
    const guarded = keyEvent(override);
    const before = overlayFocusCount;
    documentListeners.keydown(guarded.event);
    assert.equal(overlayFocusCount, before,
      "cancelled, modified, and composing rich-editor Tab stays with the website");
    assert.deepEqual(guarded.record, { prevented: 0, stopped: 0 });
  }
  const richEditorTab = keyEvent();
  documentListeners.keydown(richEditorTab.event);
  assert.equal(overlayFocusCount, overlayFocusBeforeTextTab + 2,
    "plain Tab has a scoped fallback for a rich editor that would consume it");
  assert.deepEqual(richEditorTab.record, { prevented: 1, stopped: 1 });
  field.isContentEditable = false;

  assert.equal(typeof keyboardExitHandler, "function");
  keyboardExitHandler(1);
  assert.equal(document.activeElement, field,
    "forward boundary first returns focus to the source for native Tab default handling");
  assert.equal(currentKeyboardBridge(), null,
    "forward boundary temporarily removes Bean instead of guessing the next page control");
  const nativeNextControl = { id: "native-next-control" };
  extraFields.add(nativeNextControl);
  document.activeElement = nativeNextControl; // the browser's synchronous Tab default action
  runTimers();
  assert.equal(document.activeElement, nativeNextControl,
    "Bean never overwrites the browser-selected positive/radio/shadow/focus-proxy target");
  assert.equal(currentKeyboardBridge(), null,
    "a successful native move cannot be followed by a stale bridge reinsertion");
  extraFields.delete(nativeNextControl);

  field.focus();
  elementListeners.input({ isTrusted: false, isComposing: false });
  assert.equal(currentKeyboardBridge(), null, "typing synchronously removes the stale bridge");
  runTimers();
  await settle();
  keyboardBridge = currentKeyboardBridge();
  assert.ok(keyboardBridge, "fresh findings recreate one bridge after typing settles");
  keyboardExitHandler(-1);
  assert.equal(document.activeElement, field, "Shift-Tab returns to the source editor");
  assert.equal(currentKeyboardBridge(), keyboardBridge, "backward exit keeps the native entry bridge intact");
  field.tabIndex = 0;

  now += 16000;
  field.value = "aa bb cc dd ee ff gg hh changed";
  field.selectionStart = field.value.length;
  detectedIssues = [
    ["aa", "aaa"], ["bb", "bbb"], ["cc", "ccc"], ["dd", "ddd"],
    ["ee", "eee"], ["ff", "fff"], ["gg", "ggg"], ["hh", "hhh"]
  ].map(([original, suggestion]) => ({ original, suggestion, type: "grammar" }));
  bridgeDetectedIssues = [];
  const bridgeCountAtLocalCap = bridgeMessages.length;
  elementListeners.input({ isTrusted: true, isComposing: false });
  runTimers();
  await settle();
  assert.equal(bridgeMessages.length, bridgeCountAtLocalCap,
    "eight visible local findings skip both the status handshake and paid AI request");
  documentListeners.focusin({ target: { ...field, readOnly: true } });

  // A suggestion card is only a preview. Re-check hard field eligibility at the
  // actual write boundary because sites can change semantics while the card is
  // open without dispatching another input event.
  for (const [label, makeIneligible] of ineligibleMutations) {
    restoreEligibleField();
    field.value = "please recieve now";
    field.selectionStart = field.value.length;
    document.activeElement = field;
    detectedIssues = [{ original: "recieve", suggestion: "receive", type: "spelling" }];
    documentListeners.focusin({ target: field, composedPath: () => [field] });
    runTimers();
    await settle();
    const handlers = renderHandlers;
    assert.ok(handlers, `${label}: an eligible issue rendered before the state change`);
    makeIneligible();
    handlers.onApply("i0");
    assert.equal(field.value, "please recieve now",
      `${label}: Apply cannot write after the field becomes ineligible`);
  }
  restoreEligibleField();

  // Undo is another write, not an exemption from the same boundary. Generate a
  // fresh verified record for every dynamic field state and prove the old text is
  // never restored into a now-disabled, secret, or non-editable surface.
  for (const [label, makeIneligible] of ineligibleMutations) {
    restoreEligibleField();
    field.value = "please recieve now";
    field.selectionStart = field.value.length;
    document.activeElement = field;
    detectedIssues = [{ original: "recieve", suggestion: "receive", type: "spelling" }];
    documentListeners.focusin({ target: field, composedPath: () => [field] });
    runTimers();
    await settle();
    renderHandlers.onApply("i0");
    assert.equal(field.value, "please receive now", `${label}: setup Apply succeeded`);
    const undo = undoOffer.handler;
    makeIneligible();
    assert.equal(undo(), false, `${label}: Undo refuses the newly ineligible field`);
    assert.equal(field.value, "please receive now",
      `${label}: failed Undo leaves the corrected value untouched`);
    runTimers();
    await settle();
  }
  restoreEligibleField();

  // End-to-end content wiring: verified Apply creates a scope-specific custom
  // Undo, and temporary per-field opt-outs stay bound to their own DOM fields.
  field.value = "please recieve now";
  field.selectionStart = field.value.length;
  document.activeElement = field;
  detectedIssues = [{ original: "recieve", suggestion: "receive", type: "spelling" }];
  document.activeElement = { id: "keyboard-activated-bean-control" };
  documentListeners.focusin({ target: field });
  runTimers();
  await settle();
  assert.ok(renderHandlers, "eligible local issue renders interaction handlers");
  renderHandlers.onApply("i0");
  assert.equal(field.value, "please receive now");
  assert.equal(document.activeElement, field, "Apply restores keyboard focus to the source field");
  assert.equal(undoOffer.options.scope, "issue");
  assert.equal(typeof undoOffer.handler, "function");
  assert.equal(undoOffer.handler(), true, "Undo restores the exact captured issue scope");
  assert.equal(field.value, "please recieve now");

  runTimers();
  await settle();
  document.activeElement = { id: "keyboard-disable-field-menu-item" };
  renderHandlers.onDisableField();
  assert.equal(document.activeElement, field,
    "disabling from the keyboard returns focus to the still-editable source field");
  const enableFirstField = disabledFieldOptions.onEnable;
  assert.equal(typeof enableFirstField, "function", "disabled field exposes a re-enable callback");

  const secondField = {
    ...field,
    id: "second-field",
    value: "please recieve later",
    selectionStart: 0,
    focus: () => { document.activeElement = secondField; }
  };
  extraFields.add(secondField);
  document.activeElement = secondField;
  documentListeners.focusin({ target: secondField, composedPath: () => [secondField] });
  runTimers();
  await settle();
  renderHandlers.onDisableField();
  const enableSecondField = disabledFieldOptions.onEnable;
  assert.notEqual(enableSecondField, enableFirstField,
    "each disabled field gets a control bound to that exact field");

  document.activeElement = field;
  documentListeners.focusin({ target: field, composedPath: () => [field] });
  assert.notEqual(disabledFieldOptions.onEnable, enableSecondField,
    "returning to an earlier disabled field replaces the global control with that field's recovery action");
  assert.equal(disabledFieldOptions.onEnable(), true);
  assert.equal(document.activeElement, field, "re-enabling the first field never jumps to the second field");

  document.activeElement = secondField;
  documentListeners.focusin({ target: secondField, composedPath: () => [secondField] });
  assert.equal(disabledFieldOptions.onEnable(), true);
  assert.equal(document.activeElement, secondField, "the second field remains independently reversible");
  runTimers();
  await settle();
  assert.ok(localChecks.includes("please recieve now"), "re-enabled fields resume local checking");

  // A failed persistent website block must not tear down the active field or
  // claim the privacy choice succeeded.
  storageSetFailure = true;
  const activeInputListener = elementListeners.input;
  renderHandlers.onDisableSite();
  assert.equal(elementListeners.input, activeInputListener,
    "failed website blocking leaves Bean's current field state intact");
  assert.equal(savedSettings.blockedSites.length, 0, "a failed write does not mutate the saved blocklist");
  assert.equal(flashMessages.at(-1), "Couldn’t block this website");
  storageSetFailure = false;

  // Whole-paragraph AI returns asynchronously and normally applies in one step.
  // Every hard exclusion is therefore checked again after the provider response,
  // immediately before that delayed write.
  for (const [label, makeIneligible] of ineligibleMutations) {
    restoreEligibleField();
    document.activeElement = field;
    documentListeners.focusin({ target: field, composedPath: () => [field] });
    field.value = "we recieve teh parcel";
    field.selectionStart = field.value.length;
    detectedIssues = [
      { original: "recieve", suggestion: "receive", type: "spelling" },
      { original: "teh", suggestion: "the", type: "spelling" }
    ];
    bridgeDetectedIssues = [];
    now += 16000;
    elementListeners.input({ isTrusted: true, isComposing: false });
    runTimers();
    await settle();
    delayProofread = true;
    pendingProofreadCallback = null;
    groupHandlers.onFixParagraph("g0");
    await settle();
    assert.equal(typeof pendingProofreadCallback, "function",
      `${label}: paragraph provider response is pending`);
    makeIneligible();
    pendingProofreadCallback({
      ok: true,
      text: "we receive the parcel",
      reviewRequired: false
    });
    await settle();
    assert.equal(field.value, "we recieve teh parcel",
      `${label}: delayed paragraph result cannot write into an ineligible field`);
    assert.equal(paragraphBusy, false, `${label}: the busy state is cleared on refusal`);
    delayProofread = false;
  }
  restoreEligibleField();

  // An AI paragraph request replaces the actionable group card with a durable
  // busy state, clears it before safety review, and restores source focus when
  // the user cancels that review.
  document.activeElement = field;
  documentListeners.focusin({ target: field, composedPath: () => [field] });
  field.value = "we recieve teh parcel";
  field.selectionStart = field.value.length;
  detectedIssues = [
    { original: "recieve", suggestion: "receive", type: "spelling" },
    { original: "teh", suggestion: "the", type: "spelling" }
  ];
  elementListeners.input({ isTrusted: true, isComposing: false });
  runTimers();
  await settle();
  assert.equal(typeof groupHandlers.onFixParagraph, "function");
  delayProofread = true;
  groupHandlers.onFixParagraph("g0");
  await settle();
  assert.equal(paragraphBusy, true, "the paragraph request exposes a durable busy state");
  assert.equal(typeof pendingProofreadCallback, "function");
  pendingProofreadCallback({
    ok: true,
    text: "we receive the parcel",
    reviewRequired: true,
    message: "Review the changed shape."
  });
  await settle();
  assert.equal(paragraphBusy, false, "busy state clears before the safety review");
  assert.equal(reviewCalls.length, 1, "review-required output opens one before/after review");
  assert.equal(field.value, "we recieve teh parcel", "cancelling review leaves text untouched");
  assert.equal(document.activeElement, field, "cancelling review restores the source field");
  assert.deepEqual(busyEvents.map((event) => event[0]).slice(-2), ["show", "clear"]);

  // Legacy/common leading-dot block rules canonicalize to the actual hostname;
  // malformed DNS shapes are authorization corruption and fail closed.
  savedSettings.blockedSites = [".example.com"];
  storageChangedListener({ blockedSites: { newValue: [".example.com"] } }, "local");
  assert.equal(typeof elementListeners.input, "undefined",
    "a leading-dot domain rule disables Bean on the intended website");

  savedSettings.blockedSites = [];
  storageChangedListener({ blockedSites: { newValue: [] } }, "local");
  assert.equal(typeof elementListeners.input, "function", "clearing the block rule restores the field");

  savedSettings.blockedSites = ["example..com"];
  storageChangedListener({ blockedSites: { newValue: ["example..com"] } }, "local");
  assert.equal(typeof elementListeners.input, "undefined",
    "a malformed persisted hostname fails closed instead of becoming an inert rule");

  savedSettings.blockedSites = [];
  storageChangedListener({ blockedSites: { newValue: [] } }, "local");

  // A temporary inability to read the site blocklist is an authorization
  // failure, not permission to keep running on a possibly blocked website.
  storageGetFailure = true;
  const messagesBeforeSettingsFailure = bridgeMessages.length;
  storageChangedListener({}, "local");
  runTimers();
  await settle();
  assert.equal(typeof elementListeners.input, "undefined",
    "blocklist read failure tears down the active field until settings recover");
  documentListeners.focusin({ target: field, composedPath: () => [field] });
  runTimers();
  await settle();
  assert.equal(bridgeMessages.length, messagesBeforeSettingsFailure,
    "no page text or status request is sent while the blocklist is unavailable");
}

run().then(() => console.log("Browser extension content trust tests passed"));
