const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "background.js"), "utf8");
const EXTENSION_ID = "bean-extension-id";

function contentSender(overrides = {}) {
  return Object.assign({
    id: EXTENSION_ID,
    url: "https://example.com/editor",
    origin: "https://example.com",
    frameId: 0,
    documentId: "document-1",
    tab: { id: 7, url: "https://example.com/editor" }
  }, overrides);
}

function extensionSender() {
  return { id: EXTENSION_ID, url: `chrome-extension://${EXTENSION_ID}/popup.html` };
}

function extensionOptionsTabSender() {
  const url = `chrome-extension://${EXTENSION_ID}/options.html`;
  return { id: EXTENSION_ID, url, tab: { id: 11, url } };
}

function textMessage(id = "detect-1", overrides = {}) {
  const request = Object.assign({
    id,
    type: "detectIssues",
    text: "private page text",
    source: {
      surface: "browserExtension",
      urlHost: "example.com",
      fieldType: "textarea"
    },
    settings: { maxIssues: 8 }
  }, overrides);
  return { type: request.type, request };
}

function makeHarness(initialSettings = {}) {
  let messageListener = null;
  let nextTimerID = 1;
  const timers = new Map();
  const nativeCalls = [];
  const storage = { ...initialSettings };
  let currentTab = { id: 7, url: "https://example.com/editor" };
  let currentDocumentID = "document-1";
  let tabReadError = null;
  let deferTabReads = false;
  const pendingTabReads = [];
  const documentChallenges = [];
  let documentChallengeResponse = null;
  let deferDocumentChallenges = false;
  const pendingDocumentChallenges = [];
  const chrome = {
    runtime: {
      id: EXTENSION_ID,
      onInstalled: { addListener: () => {} },
      onStartup: { addListener: () => {} },
      onMessage: { addListener: (listener) => { messageListener = listener; } },
      openOptionsPage: () => {},
      getManifest: () => ({ version: "0.7.0" }),
      sendNativeMessage: (host, message, callback) => {
        nativeCalls.push({ kind: "oneShot", host, message, callback });
      },
      connectNative: (host) => {
        const messageListeners = [];
        const disconnectListeners = [];
        const call = {
          kind: "port", host, message: null, messageListeners, disconnectListeners, disconnectCount: 0
        };
        return {
          onMessage: { addListener: (listener) => messageListeners.push(listener) },
          onDisconnect: { addListener: (listener) => disconnectListeners.push(listener) },
          postMessage: (message) => {
            call.message = message;
            nativeCalls.push(call);
          },
          disconnect: () => {
            call.disconnectCount += 1;
            for (const listener of disconnectListeners) listener();
          }
        };
      },
      lastError: null
    },
    storage: {
      local: {
        get: (_keys, callback) => callback({ ...storage }),
        set: (value, callback) => {
          Object.assign(storage, value);
          if (callback) callback();
        },
        remove: (keys, callback) => {
          for (const key of keys) delete storage[key];
          if (callback) callback();
        }
      },
      onChanged: { addListener: () => {} }
    },
    tabs: {
      get: (id, callback) => {
        const finish = () => {
          chrome.runtime.lastError = tabReadError ? { message: tabReadError } : null;
          callback(currentTab && currentTab.id === id ? { ...currentTab } : undefined);
          chrome.runtime.lastError = null;
        };
        if (deferTabReads) pendingTabReads.push(finish);
        else finish();
      },
      sendMessage: (id, message, options, callback) => {
        documentChallenges.push({ id, message, options });
        const finish = () => {
          const targetExists = currentTab && currentTab.id === id
            && options && options.frameId === 0
            && options.documentId === currentDocumentID;
          chrome.runtime.lastError = targetExists
            ? null : { message: "The receiving document does not exist." };
          const response = typeof documentChallengeResponse === "function"
            ? documentChallengeResponse(message, options)
            : documentChallengeResponse;
          callback(targetExists
            ? (response || { ok: true, requestId: message.requestId })
            : undefined);
          chrome.runtime.lastError = null;
        };
        if (deferDocumentChallenges) pendingDocumentChallenges.push(finish);
        else finish();
      }
    },
    scripting: {
      unregisterContentScripts: (_filter, callback) => callback(),
      registerContentScripts: (_scripts, callback) => callback()
    }
  };

  vm.runInNewContext(source, {
    chrome, URL, Object, Array, Set, Date, Math, Number, String,
    setTimeout: (callback, delay) => {
      const id = nextTimerID++;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout: (id) => { timers.delete(id); }
  });

  function send(message, sender = contentSender()) {
    const responses = [];
    assert.equal(messageListener(message, sender, (value) => responses.push(value)), true);
    return responses;
  }

  function respond(index, response, runtimeErrorMessage = null) {
    const call = nativeCalls[index];
    assert.ok(call, `native call ${index} exists`);
    chrome.runtime.lastError = runtimeErrorMessage ? { message: runtimeErrorMessage } : null;
    if (call.kind === "oneShot") call.callback(response);
    else for (const listener of call.messageListeners) listener(response);
    chrome.runtime.lastError = null;
  }

  function disconnectNative(index, runtimeErrorMessage = null) {
    const call = nativeCalls[index];
    assert.equal(call.kind, "port");
    chrome.runtime.lastError = runtimeErrorMessage ? { message: runtimeErrorMessage } : null;
    for (const listener of call.disconnectListeners) listener();
    chrome.runtime.lastError = null;
  }

  function fireTimerWithDelay(delay) {
    const entry = [...timers.entries()].find(([, timer]) => timer.delay === delay);
    assert.ok(entry, `a ${delay}ms timer exists`);
    timers.delete(entry[0]);
    entry[1].callback();
  }

  return {
    nativeCalls, documentChallenges, storage, send, respond, disconnectNative, fireTimerWithDelay,
    timerDelays: () => [...timers.values()].map((timer) => timer.delay),
    setCurrentTab: (tab) => { currentTab = tab ? { ...tab } : null; },
    setCurrentDocumentID: (id) => { currentDocumentID = id; },
    setDocumentChallengeResponse: (response) => { documentChallengeResponse = response; },
    setTabReadError: (message) => { tabReadError = message; },
    deferTabReads: () => { deferTabReads = true; },
    resolveTabRead: () => {
      const finish = pendingTabReads.shift();
      assert.ok(finish, "a deferred tab read exists");
      finish();
    },
    deferDocumentChallenges: () => { deferDocumentChallenges = true; },
    resolveDocumentChallenge: () => {
      const finish = pendingDocumentChallenges.shift();
      assert.ok(finish, "a deferred document challenge exists");
      finish();
    }
  };
}

function readyStatus(call, overrides = {}) {
  return Object.assign({
    id: call.message.id,
    ok: true,
    bridgeAvailable: true,
    nativeHostConnected: true,
    protocolVersion: 1,
    extensionProtocolVersion: 1,
    appVersion: "1.6.0",
    appBuild: "8",
    extensionVersion: "0.7.0",
    minimumExtensionVersion: "0.7.0",
    minimumAppVersion: "1.6.0",
    compatible: true,
    compatibilityCode: "compatible",
    providerConfigured: true,
    webInlineEnabled: true,
    automaticAccountingAvailable: true,
    providerTimeoutSeconds: 30,
    automaticCallsToday: 1,
    dailyAutomaticCallLimit: 20
  }, overrides);
}

// Content-free live status and locally-derived migration status.
{
  const harness = makeHarness();
  const responses = harness.send({ type: "getStatus" });
  assert.equal(harness.nativeCalls.length, 1);
  const request = harness.nativeCalls[0].message;
  assert.equal(request.type, "getStatus");
  assert.equal(request.protocolVersion, 1);
  assert.equal(request.extensionVersion, "0.7.0");
  assert.equal(request.minimumAppVersion, "1.6.0");
  assert.equal("text" in request, false, "the live handshake never contains page text");
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(responses.length, 1);
  assert.equal(responses[0].ok, true);
  assert.equal(responses[0].nativeHostInstalled, true);
  assert.equal(responses[0].nativeHostConnected, true);
  assert.equal(responses[0].compatible, true);
  assert.equal(responses[0].providerConfigured, true);
  assert.equal(responses[0].webInlineEnabled, true);
  assert.equal(responses[0].automaticAccountingAvailable, true);
  assert.equal(responses[0].providerTimeoutSeconds, 30);
  assert.equal(responses[0].requestTimeoutSeconds, 30);
  assert.equal(responses[0].requestTimeoutMs, 35000);
  assert.equal(responses[0].browserAIConsentRequired, false);
  assert.equal(responses[0].browserAIEnabled, true);
}

// Status timeout is single-shot and ignores a late native response.
{
  const harness = makeHarness();
  const responses = harness.send({ type: "getStatus" });
  harness.fireTimerWithDelay(3500);
  assert.equal(responses.length, 1);
  assert.equal(responses[0].errorCode, "bridgeTimeout");
  assert.equal(responses[0].nativeHostInstalled, true);
  assert.equal(responses[0].nativeHostConnected, false);
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(responses.length, 1, "a late native reply cannot answer the channel twice");
}

// Rebuild a narrow DTO from the trusted sender; unknown page keys never cross.
{
  const harness = makeHarness();
  const message = textMessage("detect-happy", {
    source: { surface: "browserExtension", urlHost: "example.com:443", fieldType: "textarea", browser: "spoofed" },
    settings: { maxIssues: 4, prompt: "untrusted" },
    protocolVersion: 99,
    extensionVersion: "spoofed",
    extra: "drop me"
  });
  const responses = harness.send(message);
  assert.equal(harness.nativeCalls.length, 1, "only status is initially sent");
  assert.equal(JSON.stringify(harness.nativeCalls[0].message).includes(message.request.text), false);
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(harness.nativeCalls.length, 2, "text follows a ready status");
  assert.equal(harness.documentChallenges.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(harness.documentChallenges[0])), {
    id: 7,
    message: { type: "revalidateTextRequest", requestId: "detect-happy" },
    options: { frameId: 0, documentId: "document-1" }
  });
  assert.equal(JSON.stringify(harness.documentChallenges[0]).includes(message.request.text), false,
    "the exact-document challenge is content-free");
  assert.equal(harness.nativeCalls[1].kind, "port", "text uses a lifecycle-bound native port");
  assert.deepEqual(JSON.parse(JSON.stringify(harness.nativeCalls[1].message)), {
    id: "detect-happy",
    type: "detectIssues",
    text: "private page text",
    settings: { maxIssues: 4 },
    protocolVersion: 1,
    extensionVersion: "0.7.0",
    minimumAppVersion: "1.6.0"
  });
  assert.equal("source" in harness.nativeCalls[1].message, false,
    "validated hostname and field metadata stay extension-local");
  assert.deepEqual(harness.timerDelays(), [35000]);
  harness.respond(1, { id: "detect-happy", ok: true, issues: [] });
  assert.equal(responses[0].ok, true);
  assert.equal(harness.nativeCalls[1].disconnectCount, 1);
}

// Reuse a just-completed status preflight for the immediately following text.
{
  const harness = makeHarness();
  const statusResponses = harness.send({ type: "getStatus" });
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(statusResponses[0].compatible, true);
  const responses = harness.send(textMessage("after-preflight"));
  assert.equal(harness.nativeCalls.length, 2);
  assert.equal(harness.nativeCalls[1].kind, "port");
  harness.respond(1, { id: "after-preflight", ok: true, issues: [] });
  assert.equal(responses[0].ok, true);
}

// Provider/configuration/protocol gates always fail before text forwarding.
for (const [overrides, expectedCode] of [
  [{ providerConfigured: false }, "missingApiKey"],
  [{ webInlineEnabled: false }, "webInlineDisabled"],
  [{ automaticAccountingAvailable: false }, "usageReservationUnavailable"],
  [{ protocolVersion: 2, compatible: false, compatibilityCode: "protocolMismatch" }, "protocolMismatch"]
]) {
  const harness = makeHarness();
  const responses = harness.send(textMessage(`gate-${expectedCode}`));
  harness.respond(0, readyStatus(harness.nativeCalls[0], overrides));
  assert.equal(harness.nativeCalls.length, 1, `${expectedCode} never forwards text`);
  assert.equal(responses[0].errorCode, expectedCode);
  if (expectedCode === "usageReservationUnavailable") {
    assert.match(responses[0].message, /AI & Usage/);
    assert.match(responses[0].message, /Check Accounting Again/);
    assert.match(responses[0].message, /Full Reset is a data-erasing last resort/);
    assert.match(responses[0].message, /contact Support if reset fails/);
    assert.doesNotMatch(responses[0].message, /clear usage|clear usage\/history/i);
  }
}

// Missing and forbidden native-host states are intentionally distinct.
{
  const missing = makeHarness();
  const missingResponses = missing.send({ type: "getStatus" });
  missing.respond(0, undefined, "Specified native messaging host not found.");
  assert.equal(missingResponses[0].errorCode, "notInstalled");
  assert.equal(missingResponses[0].nativeHostInstalled, false);

  const forbidden = makeHarness();
  const forbiddenResponses = forbidden.send({ type: "getStatus" });
  forbidden.respond(0, undefined, "Access to the specified native messaging host is forbidden.");
  assert.equal(forbiddenResponses[0].errorCode, "nativeHostForbidden");
  assert.equal(forbiddenResponses[0].nativeHostInstalled, true);
  assert.equal(forbiddenResponses[0].nativeHostConnected, false);
}

// Sender identity, top-frame URL, tab URL, and origin are bound together.
for (const [sender, expectedCode] of [
  [{}, "unauthorizedSender"],
  [extensionSender(), "unauthorizedSender"],
  [contentSender({ id: "different-extension" }), "unauthorizedSender"],
  [contentSender({ documentId: undefined }), "unauthorizedSender"],
  [contentSender({ url: "ftp://example.com/file", origin: "ftp://example.com" }), "unauthorizedSender"],
  [contentSender({ frameId: 2 }), "unauthorizedSender"],
  [contentSender({ tab: { id: 7, url: "https://other.example/editor" } }), "senderNavigationMismatch"],
  [contentSender({ origin: "https://other.example" }), "senderOriginMismatch"]
]) {
  const harness = makeHarness();
  const responses = harness.send(textMessage("sender-check"), sender);
  assert.equal(responses[0].errorCode, expectedCode);
  assert.equal(harness.nativeCalls.length, 0, `${expectedCode} cannot reach native messaging`);
}

// A same-URL reload creates a new document without changing tabs.get output.
// Targeting the original sender.documentId must fail before native text.
{
  const harness = makeHarness();
  const responses = harness.send(textMessage("same-url-reload"));
  harness.setCurrentDocumentID("document-2");
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(harness.nativeCalls.length, 1);
  assert.equal(harness.documentChallenges.length, 1);
  assert.equal(responses[0].errorCode, "senderDocumentMismatch");
}

// The exact document can remain while the originating field is removed,
// changed, or becomes sensitive. The content script's content-free denial is
// authoritative at the last boundary.
for (const state of ["removed", "changed", "sensitive"]) {
  const harness = makeHarness();
  harness.setDocumentChallengeResponse(() => ({
    ok: false, requestId: `field-${state}`
  }));
  const responses = harness.send(textMessage(`field-${state}`));
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(harness.nativeCalls.length, 1, `${state} field text never reaches native messaging`);
  assert.equal(responses[0].errorCode, "senderDocumentMismatch");
}

// Malformed, mismatched, or oversized DTOs stop before status.
const malformedCases = [
  [textMessage("spoof", { source: { surface: "browserExtension", urlHost: "evil.example", fieldType: "textarea" } }), "sourceHostMismatch"],
  [textMessage("no-source", { source: null }), "invalidSource"],
  [{ type: "detectIssues", request: { ...textMessage("wrong-type").request, type: "proofreadParagraph" } }, "invalidRequestType"],
  [textMessage("bad id with spaces"), "invalidRequestID"],
  [textMessage("bad-field", { source: { surface: "browserExtension", urlHost: "example.com", fieldType: "password" } }), "invalidFieldType"],
  [textMessage("bad-max", { settings: { maxIssues: 9 } }), "invalidSettings"],
  [textMessage("bad-text", { text: { private: true } }), "emptyText"],
  [textMessage("detect-long", { text: "x".repeat(8001) }), "textTooLong"],
  [{ type: "proofreadParagraph", request: { ...textMessage("proof-long", { text: "x".repeat(2001) }).request, type: "proofreadParagraph" } }, "textTooLong"]
];
for (const [message, expectedCode] of malformedCases) {
  const harness = makeHarness();
  const responses = harness.send(message);
  assert.equal(responses[0].errorCode, expectedCode);
  assert.equal(JSON.stringify(responses[0]).includes("private page text"), false);
  assert.equal(harness.nativeCalls.length, 0);
}

// Policy is checked before status and again immediately afterward.
{
  const initiallyBlocked = makeHarness({ blockedSites: ["example.com"] });
  const initialResponses = initiallyBlocked.send(textMessage("blocked-first"));
  assert.equal(initialResponses[0].errorCode, "siteBlocked");
  assert.equal(initiallyBlocked.nativeCalls.length, 0);

  const race = makeHarness({ blockedSites: [] });
  const raceResponses = race.send(textMessage("blocked-during-status"));
  assert.equal(race.nativeCalls.length, 1);
  race.storage.blockedSites = ["example.com"];
  race.respond(0, readyStatus(race.nativeCalls[0]));
  assert.equal(race.nativeCalls.length, 1, "a block added during status prevents native text");
  assert.equal(raceResponses[0].errorCode, "siteBlocked");
}

// A common leading-dot rule is canonicalized consistently. If Options reports
// `.example.com` as saved, both the exact host and its subdomains must really be
// blocked rather than silently surviving registration/runtime validation.
{
  const legacy = makeHarness({ blockedSites: [".example.com"] });
  const legacyResponses = legacy.send(textMessage("leading-dot-existing"));
  assert.equal(legacyResponses[0].errorCode, "siteBlocked");
  assert.equal(legacy.nativeCalls.length, 0);

  const added = makeHarness({ blockedSites: [] });
  const mutation = added.send({
    type: "mutateBlockedSites", operation: "add", hosts: [".example.com"]
  }, extensionSender());
  assert.equal(mutation[0].ok, true);
  assert.deepEqual(JSON.parse(JSON.stringify(mutation[0].blockedSites)), ["example.com"]);
  assert.deepEqual(
    JSON.parse(JSON.stringify(added.storage.blockedSites)),
    ["example.com"]
  );
  const blockedResponses = added.send(textMessage("leading-dot-added"));
  assert.equal(blockedResponses[0].errorCode, "siteBlocked");
  assert.equal(added.nativeCalls.length, 0);
}

// Chrome supplies sender.tab when Options is opened in a normal browser tab.
// The authenticated chrome-extension:// sender must retain settings authority;
// rejecting every tab-bearing sender makes Add and Remove fail in the real UI.
{
  const harness = makeHarness({ blockedSites: [] });
  const added = harness.send({
    type: "mutateBlockedSites", operation: "add", hosts: ["example.com"]
  }, extensionOptionsTabSender());
  assert.equal(added[0].ok, true);
  assert.deepEqual(JSON.parse(JSON.stringify(added[0].blockedSites)), ["example.com"]);

  const removed = harness.send({
    type: "mutateBlockedSites", operation: "remove", hosts: ["example.com"]
  }, extensionOptionsTabSender());
  assert.equal(removed[0].ok, true);
  assert.deepEqual(JSON.parse(JSON.stringify(removed[0].blockedSites)), []);

  const forged = harness.send({
    type: "mutateBlockedSites", operation: "add", hosts: ["attacker.example"]
  }, {
    id: EXTENSION_ID,
    url: `chrome-extension://${EXTENSION_ID}/options.html`,
    tab: { id: 12, url: "https://attacker.example/" }
  });
  assert.equal(forged[0].errorCode, "unauthorizedSender");
}

// The final send boundary re-resolves the originating tab. A navigation,
// navigation already in progress, closed tab, or tab read failure after the
// content-free status handshake must discard the captured text.
for (const [name, change] of [
  ["cross-origin-navigation", (harness) => harness.setCurrentTab({ id: 7, url: "https://other.example/editor" })],
  ["same-origin-navigation", (harness) => harness.setCurrentTab({ id: 7, url: "https://example.com/inbox" })],
  ["pending-navigation", (harness) => harness.setCurrentTab({
    id: 7,
    url: "https://example.com/editor",
    pendingUrl: "https://example.com/inbox"
  })],
  ["closed-tab", (harness) => harness.setCurrentTab(null)],
  ["tab-read-error", (harness) => harness.setTabReadError("The tab was closed.")]
]) {
  const harness = makeHarness();
  const responses = harness.send(textMessage(`tab-${name}`));
  assert.equal(harness.nativeCalls.length, 1, "only the content-free status is sent before revalidation");
  change(harness);
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(harness.nativeCalls.length, 1, `${name} never forwards captured text`);
  assert.equal(responses[0].errorCode, "senderNavigationMismatch");
}

// A site block committed while the final document challenge is pending also
// invalidates the earlier policy snapshot.
{
  const harness = makeHarness({ blockedSites: [] });
  harness.deferDocumentChallenges();
  const textResponses = harness.send(textMessage("policy-during-document-challenge"));
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  const blockResponses = harness.send({
    type: "mutateBlockedSites", operation: "blockCurrentSite"
  }, contentSender());
  assert.equal(blockResponses[0].ok, true);
  harness.resolveDocumentChallenge();
  assert.equal(harness.nativeCalls.length, 1, "the new site block prevents native text");
  assert.equal(textResponses[0].errorCode, "privacySettingsChanged");
}

// A site block that commits while final tab resolution is pending invalidates
// the earlier policy snapshot. No stale snapshot may authorize captured text.
{
  const harness = makeHarness({ blockedSites: [] });
  harness.deferTabReads();
  const textResponses = harness.send(textMessage("policy-during-tab-read"));
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  const blockResponses = harness.send({
    type: "mutateBlockedSites", operation: "blockCurrentSite"
  }, contentSender());
  assert.equal(blockResponses[0].ok, true);
  harness.resolveTabRead();
  assert.equal(harness.nativeCalls.length, 1, "the new site block prevents native text");
  assert.equal(textResponses[0].errorCode, "privacySettingsChanged");
}

// A legacy paid-AI opt-out requires one trusted reconfirmation.
{
  const harness = makeHarness({ legacyAIOptOut: true });
  const statusResponses = harness.send({ type: "getStatus" });
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(statusResponses[0].browserAIConsentRequired, true);
  assert.equal(statusResponses[0].browserAIStatusCode, "browserAIConsentRequired");
  const blockedResponses = harness.send(textMessage("needs-consent"));
  assert.equal(blockedResponses[0].errorCode, "browserAIConsentRequired");
  assert.equal(harness.nativeCalls.length, 1);
  const unauthorized = harness.send({ type: "confirmBrowserAI" }, contentSender());
  assert.equal(unauthorized[0].errorCode, "unauthorizedSender");
  assert.equal(harness.storage.legacyAIOptOut, true);
  const confirmed = harness.send({ type: "confirmBrowserAI" }, extensionSender());
  assert.equal(confirmed[0].ok, true);
  assert.equal("legacyAIOptOut" in harness.storage, false);
}

// If migration could not persist its new marker, the original false controls
// remain authoritative until the user confirms from an extension-owned page.
{
  const harness = makeHarness({ enabled: false, useBridge: false, settingsSchemaVersion: 5 });
  const statusResponses = harness.send({ type: "getStatus" });
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(statusResponses[0].browserAIConsentRequired, true);
  const blockedResponses = harness.send(textMessage("legacy-write-failed"));
  assert.equal(blockedResponses[0].errorCode, "browserAIConsentRequired");
  assert.equal(harness.nativeCalls.length, 1, "legacy false values prevent all text forwarding");
  const confirmed = harness.send({ type: "confirmBrowserAI" }, extensionSender());
  assert.equal(confirmed[0].ok, true);
  assert.equal("enabled" in harness.storage, false);
  assert.equal("useBridge" in harness.storage, false);
}

// Corrupt authorization state is not equivalent to an empty blocklist or an
// affirmative browser-AI choice. No page text may reach even the status
// handshake until the extension can read a known policy shape again.
for (const settings of [
  { blockedSites: "example.com" },
  { blockedSites: ["example.com", null] },
  { blockedSites: [], legacyAIOptOut: "false" }
]) {
  const harness = makeHarness(settings);
  const responses = harness.send(textMessage("corrupt-policy"));
  assert.equal(responses[0].errorCode, "settingsUnavailable");
  assert.equal(harness.nativeCalls.length, 0);
}

// Blocklist registration can be refreshed by verified content and extension
// pages, but never by an unrelated sender.
{
  const harness = makeHarness();
  assert.equal(harness.send({ type: "refreshRegistration" }, contentSender())[0].ok, true);
  assert.equal(harness.send({ type: "refreshRegistration" }, extensionSender())[0].ok, true);
  assert.equal(
    harness.send({ type: "refreshRegistration" }, { id: "other" })[0].errorCode,
    "unauthorizedSender"
  );
}

// Content scripts may block only their own verified top-frame host. Extension
// pages can request explicit add/remove operations, and receive the persisted
// authoritative list rather than trusting a local cache.
{
  const harness = makeHarness({ blockedSites: ["existing.test"] });
  const unauthorized = harness.send({
    type: "mutateBlockedSites", operation: "remove", hosts: ["existing.test"]
  }, contentSender());
  assert.equal(unauthorized[0].errorCode, "unauthorizedSender");
  assert.deepEqual(harness.storage.blockedSites, ["existing.test"]);

  const blocked = harness.send({
    type: "mutateBlockedSites", operation: "blockCurrentSite"
  }, contentSender());
  assert.equal(blocked[0].ok, true);
  assert.deepEqual(
    JSON.parse(JSON.stringify(blocked[0].blockedSites)),
    ["example.com", "existing.test"]
  );
}

// Provider timeout plus headroom replaces the fixed 10-second cutoff.
for (const [reportedTimeout, requestTimeout, expectedTimeout] of [
  [5, undefined, 15000],
  [30, 30, 35000],
  [120, 120, 125000],
  [999, 999, 125000],
  [undefined, undefined, 35000],
  [30, 120, 125000]
]) {
  const harness = makeHarness();
  const responses = harness.send(textMessage(`timeout-${String(reportedTimeout)}-${String(requestTimeout)}`));
  harness.respond(0, readyStatus(harness.nativeCalls[0], {
    providerTimeoutSeconds: reportedTimeout,
    requestTimeoutSeconds: requestTimeout
  }));
  assert.deepEqual(harness.timerDelays(), [expectedTimeout]);
  assert.ok(expectedTimeout > 10000);
  harness.fireTimerWithDelay(expectedTimeout);
  assert.equal(responses[0].errorCode, "bridgeTimeout");
  assert.equal(harness.nativeCalls[1].disconnectCount, 1);
}

// Exactly one request runs at a time. Concurrent work is rejected immediately
// so stale page text can never sit in a paid-provider queue after navigation.
{
  const harness = makeHarness();
  const first = harness.send(textMessage("queue-1"));
  const duplicate = harness.send(textMessage("queue-1"));
  const busy = harness.send(textMessage("queue-2"));
  assert.equal(duplicate[0].errorCode, "duplicateRequest");
  assert.equal(busy[0].errorCode, "bridgeBusy");
  assert.equal(harness.nativeCalls.length, 1);
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  assert.equal(harness.nativeCalls.length, 2);
  harness.respond(1, { id: "queue-1", ok: true, issues: [] });
  assert.equal(first[0].ok, true);
  const retry = harness.send(textMessage("queue-2"));
  assert.equal(harness.nativeCalls.length, 3, "new work may start after the first request finishes");
  assert.equal(harness.nativeCalls[2].message.id, "queue-2");
  harness.respond(2, { id: "queue-2", ok: true, issues: [] });
  assert.equal(retry[0].ok, true);
}

// Forbidden during the port lifecycle is still not misreported as uninstalled.
{
  const harness = makeHarness();
  const responses = harness.send(textMessage("port-forbidden"));
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  harness.disconnectNative(1, "Access to the specified native messaging host is forbidden.");
  assert.equal(responses[0].errorCode, "nativeHostForbidden");
}

// Native replies are bound to the request ID and must be JSON objects. A port
// disconnect without Chrome's special forbidden/not-found errors stays a plain
// connection failure.
for (const [nativeReply, expectedCode] of [
  [{ id: "someone-else", ok: true, issues: [] }, "bridgeResponseMismatch"],
  [[{ id: "array-is-not-a-response" }], "bridgeMalformedResponse"]
]) {
  const harness = makeHarness();
  const responses = harness.send(textMessage(`reply-${expectedCode}`));
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  harness.respond(1, nativeReply);
  assert.equal(responses[0].errorCode, expectedCode);
}

{
  const harness = makeHarness();
  const responses = harness.send(textMessage("plain-disconnect"));
  harness.respond(0, readyStatus(harness.nativeCalls[0]));
  harness.disconnectNative(1);
  assert.equal(responses[0].errorCode, "bridgeDisconnected");
}

// Registration replacement is serialized. A second settings surface that asks
// for refresh mid-cycle triggers one final pass over the newest blocklist; its
// register call cannot race the first call and fail as a duplicate script ID.
{
  let unregisterCallbacks = [];
  const registerCalls = [];
  let blockedSites = ["first.example"];
  const chrome = {
    runtime: {
      id: EXTENSION_ID,
      lastError: null,
      onInstalled: { addListener: () => {} },
      onStartup: { addListener: () => {} },
      onMessage: { addListener: () => {} },
      getManifest: () => ({ version: "0.7.0" }),
      sendNativeMessage: () => {},
      connectNative: () => { throw new Error("not used"); }
    },
    storage: {
      local: {
        get: (_keys, callback) => callback({ blockedSites: [...blockedSites] }),
        set: (_value, callback) => { if (callback) callback(); },
        remove: (_keys, callback) => { if (callback) callback(); }
      }
    },
    scripting: {
      unregisterContentScripts: (_filter, callback) => unregisterCallbacks.push(callback),
      registerContentScripts: (scripts, callback) => registerCalls.push({ scripts, callback })
    }
  };
  const context = {
    chrome, URL, Object, Array, Set, Date, Math, Number, String,
    setTimeout: () => 1, clearTimeout: () => {}
  };
  vm.runInNewContext(source, context);

  assert.deepEqual(
    JSON.parse(JSON.stringify(context.patternsForHosts("corrupt-not-an-array"))),
    [],
    "a corrupt stored blocklist cannot crash persistent script registration"
  );
  assert.deepEqual(
    JSON.parse(JSON.stringify(context.patternsForHosts([
      " Example.COM. ", ".example.com", "example.com", "*.invalid.example", "bad_host", "[::1]", 42
    ]))),
    [
      "http://example.com/*", "https://example.com/*",
      "http://*.example.com/*", "https://*.example.com/*",
      "http://[::1]/*", "https://[::1]/*"
    ],
    "registration normalizes safe hosts and drops values Chrome could reject"
  );
  const results = [];
  context.syncRegisteredContentScript((result) => results.push(["first", result]));
  context.syncRegisteredContentScript((result) => results.push(["second", result]));
  assert.equal(unregisterCallbacks.length, 1, "only one unregister starts while a cycle is active");

  unregisterCallbacks.shift()();
  assert.equal(registerCalls.length, 1);
  assert.ok(registerCalls[0].scripts[0].excludeMatches.includes("https://first.example/*"));
  blockedSites = ["newest.example"];
  registerCalls.shift().callback();
  assert.equal(unregisterCallbacks.length, 1, "a pending request becomes one coalesced final cycle");
  assert.equal(results.length, 0, "callers wait for the final policy to be installed");

  unregisterCallbacks.shift()();
  assert.equal(registerCalls.length, 1);
  assert.ok(registerCalls[0].scripts[0].excludeMatches.includes("https://newest.example/*"));
  assert.equal(registerCalls[0].scripts[0].excludeMatches.includes("https://first.example/*"), false);
  registerCalls.shift().callback();
  assert.equal(results.length, 2);
  assert.equal(results.every(([, result]) => result.ok === true), true);
}

// True interleaving regression: two settings surfaces enqueue mutations before
// the first storage read completes. The service worker must finish add A before
// reading for add B, so neither privacy rule is lost to last-writer-wins.
{
  let messageListener = null;
  let storedSites = ["base.test"];
  const pendingGets = [];
  const chrome = {
    runtime: {
      id: EXTENSION_ID,
      lastError: null,
      onInstalled: { addListener: () => {} },
      onStartup: { addListener: () => {} },
      onMessage: { addListener: (listener) => { messageListener = listener; } },
      getManifest: () => ({ version: "0.7.0" }),
      sendNativeMessage: () => {},
      connectNative: () => { throw new Error("not used"); }
    },
    storage: {
      local: {
        get: (_keys, callback) => pendingGets.push(callback),
        set: (value, callback) => {
          storedSites = [...value.blockedSites];
          callback();
        },
        remove: (_keys, callback) => callback()
      }
    },
    scripting: {
      unregisterContentScripts: (_filter, callback) => callback(),
      registerContentScripts: (_scripts, callback) => callback()
    }
  };
  vm.runInNewContext(source, {
    chrome, URL, Object, Array, Set, Date, Math, Number, String,
    setTimeout: () => 1, clearTimeout: () => {}
  });

  const responsesA = [], responsesB = [];
  assert.equal(messageListener(
    { type: "mutateBlockedSites", operation: "add", hosts: ["a.test"] },
    extensionSender(), (value) => responsesA.push(value)
  ), true);
  assert.equal(messageListener(
    { type: "mutateBlockedSites", operation: "add", hosts: ["b.test"] },
    extensionSender(), (value) => responsesB.push(value)
  ), true);
  assert.equal(pendingGets.length, 1, "the second mutation cannot read a stale snapshot");

  pendingGets.shift()({ blockedSites: [...storedSites] }); // add A read
  pendingGets.shift()({ blockedSites: [...storedSites] }); // add A registration read
  assert.equal(responsesA.length, 1);
  assert.equal(responsesB.length, 0);
  assert.equal(pendingGets.length, 1, "add B reads only after add A is durable");

  pendingGets.shift()({ blockedSites: [...storedSites] }); // add B read
  pendingGets.shift()({ blockedSites: [...storedSites] }); // add B registration read
  assert.deepEqual(storedSites, ["a.test", "b.test", "base.test"]);
  assert.equal(responsesB.length, 1);
  assert.deepEqual(
    JSON.parse(JSON.stringify(responsesB[0].blockedSites)),
    ["a.test", "b.test", "base.test"]
  );
}

console.log("Browser extension background trust, lifecycle, concurrency, and timeout tests passed");
