const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class FakeElement {
  constructor(id = "") {
    this.id = id;
    this.checked = false;
    this.value = "";
    this.textContent = "";
    this.className = "";
    this.hidden = false;
    this.disabled = false;
    this.children = [];
    this.listeners = {};
    this.statusValue = null;
  }
  addEventListener(type, listener) { this.listeners[type] = listener; }
  appendChild(child) { this.children.push(child); return child; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute(name, value) { this[name] = value; }
  querySelector(selector) { return selector === "span:last-child" ? this.statusValue : null; }
}

const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, new FakeElement(id));
  return elements.get(id);
}
for (const id of ["app-status", "ai-status", "usage-status"]) element(id).statusValue = new FakeElement();

let saved = null;
const messages = [];
let storedSites = ["example.com"];
let storageChangedListener = null;
let mutationFailure = false;
let mutationResponseLost = false;
let registrationUpdated = true;
let deferStatus = false;
let pendingStatusCallback = null;
let nextTimerID = 0;
const timers = new Map();
const readyStatus = {
  ok: true,
  bridgeAvailable: true,
  protocolVersion: 1,
  compatible: true,
  providerConfigured: true,
  webInlineEnabled: true,
  automaticAccountingAvailable: true,
  appVersion: "1.3.0",
  automaticCallsToday: 1,
  dailyAutomaticCallLimit: 20
};
const chrome = {
  storage: {
    local: {
      get: (_keys, callback) => callback({ blockedSites: [...storedSites] }),
      set: (value, callback) => { saved = value; storedSites = [...value.blockedSites]; callback(); }
    },
    onChanged: { addListener: (listener) => { storageChangedListener = listener; } }
  },
  runtime: {
    lastError: null,
    sendMessage: (message, callback) => {
      messages.push(message);
      if (message.type === "getStatus") {
        if (deferStatus) pendingStatusCallback = callback;
        else callback(readyStatus);
      }
      else if (message.type === "mutateBlockedSites") {
        if (mutationFailure) {
          callback({ ok: false, errorCode: "settingsUnavailable" });
          return;
        }
        if (message.operation === "add") {
          storedSites = [...new Set([...storedSites, ...message.hosts])].sort();
        } else if (message.operation === "remove") {
          storedSites = storedSites.filter((site) => !message.hosts.includes(site));
        }
        saved = { blockedSites: [...storedSites] };
        if (mutationResponseLost) {
          callback(undefined);
          return;
        }
        callback({ ok: true, blockedSites: [...storedSites], registrationUpdated });
      }
      else if (callback) callback({ ok: true });
    }
  }
};

const context = {
  chrome,
  document: {
    getElementById: element,
    createElement: () => new FakeElement()
  },
  URL,
  Set,
  Number,
  setTimeout: (callback) => {
    const id = ++nextTimerID;
    timers.set(id, callback);
    return id;
  },
  clearTimeout: (id) => { timers.delete(id); }
};
const source = fs.readFileSync(path.join(__dirname, "..", "options.js"), "utf8");
const html = fs.readFileSync(path.join(__dirname, "..", "options.html"), "utf8");
vm.runInNewContext(source, context);

assert.match(html, /Blocked websites/);
assert.match(html, /Changes save automatically/);
assert.match(html, /id="app-status"/);
assert.match(html, /id="ai-status"/);
assert.match(html, /id="confirm-browser-ai"[^>]*hidden/);
assert.match(html, /\.status-row\[hidden\]\s*\{\s*display:\s*none/, "hidden usage must not be revived by display: contents");
assert.match(html, /src="icon128\.png"/);
assert.match(html, /focus-visible[^}]*outline:\s*3px solid var\(--accent\)/s,
  "keyboard focus uses the opaque brand accent");
assert.doesNotMatch(html, /type="checkbox"|id="useBridge"|Save Changes|Terminal|install_native_messaging_host/);

assert.equal(context.normalizeHost("MAIL.Google.com"), "mail.google.com");
assert.equal(context.normalizeHost("https://app.slack.com/client"), "app.slack.com");
assert.equal(context.normalizeHost(".Example.com"), "example.com",
  "the common leading-dot form canonicalizes to an enforceable host rule");
assert.equal(context.normalizeHost("..example.com"), null);
assert.equal(context.normalizeHost("ftp://example.com"), null);
assert.equal(context.normalizeHost("*.example.com"), null);
assert.deepEqual(
  JSON.parse(JSON.stringify(context.parseSites("app.slack.com\nmail.google.com app.slack.com"))),
  ["app.slack.com", "mail.google.com"]
);

assert.equal(element("app-status").statusValue.textContent, "Connected · Bean 1.3.0");
assert.equal(element("ai-status").statusValue.textContent, "Ready");
assert.equal(element("usage-row").hidden, false);
storedSites = ["example.com", "newly-blocked.test"];
assert.equal(context.addBlockedSites(".mail.google.com"), true);
assert.deepEqual(JSON.parse(JSON.stringify(saved.blockedSites)),
  ["example.com", "mail.google.com", "newly-blocked.test"],
  "the authoritative background mutation preserves a concurrent rule and receives a canonical hostname");
assert.equal(Object.hasOwn(saved, "useBridge"), false, "options must not expose or overwrite the internal bridge flag");
assert.ok(messages.some((message) => message.type === "mutateBlockedSites" && message.operation === "add"));

mutationFailure = true;
const beforeFailedMutation = [...storedSites];
assert.equal(context.addBlockedSites("failure.test"), true);
assert.deepEqual(storedSites, beforeFailedMutation,
  "a failed background mutation never changes the authoritative blocklist");
assert.match(element("notice").textContent, /could not save/i,
  "Options reports mutation failure truthfully");
assert.equal(element("notice").className, "error");
mutationFailure = false;

// Chrome may close the service-worker response channel after the background
// has durably saved a choice but before its dynamic registration refresh
// replies. Options re-reads storage and must not report that successful removal
// as a failure.
storedSites = ["127.0.0.1", "example.com"];
mutationResponseLost = true;
context.removeBlockedSite("127.0.0.1");
assert.deepEqual(storedSites, ["example.com"]);
assert.match(element("notice").textContent, /can use Bean again/i);
assert.equal(element("notice").className, "");
assert.ok(messages.some((message) => message.type === "refreshRegistration"));
mutationResponseLost = false;

registrationUpdated = false;
assert.equal(context.addBlockedSites("registration-retry.test"), true);
assert.match(element("notice").textContent, /Restart your browser/,
  "Options gives the recovery action that actually retries script registration");
registrationUpdated = true;

storageChangedListener({ blockedSites: { newValue: ["external.test"] } }, "local");
assert.equal(element("blocked-list").children[0].children[0].textContent, "external.test",
  "an external blocklist change updates the open Options page");

const consent = context.assessBridgeStatus({
  ok: true, bridgeAvailable: true, protocolVersion: 1, compatible: true,
  providerConfigured: true, webInlineEnabled: true,
  automaticAccountingAvailable: true,
  browserAIConsentRequired: true, browserAIEnabled: false,
  browserAIStatusCode: "browserAIConsentRequired"
});
assert.equal(consent.ai[0], "Waiting for you");
context.renderBridgeResponse({
  ok: true, bridgeAvailable: true, protocolVersion: 1, compatible: true,
  providerConfigured: true, webInlineEnabled: true,
  automaticAccountingAvailable: true,
  browserAIConsentRequired: true, browserAIEnabled: false,
  browserAIStatusCode: "browserAIConsentRequired"
});
assert.equal(element("confirm-browser-ai").hidden, false);
element("confirm-browser-ai").listeners.click();
assert.ok(messages.some((message) => message.type === "confirmBrowserAI"));
assert.equal(element("confirm-browser-ai").hidden, true,
  "one-time confirmation disappears after it is saved");

assert.equal(context.assessBridgeStatus({
  ok: false, errorCode: "nativeHostForbidden", nativeHostInstalled: true
}).app[0], "Connection not authorized");
assert.equal(context.assessBridgeStatus({
  ok: false, errorCode: "notInstalled", nativeHostInstalled: false
}).app[0], "Connection not installed");
assert.equal(context.assessBridgeStatus({
  ok: true, bridgeAvailable: true, protocolVersion: 1, compatible: true,
  providerConfigured: true, webInlineEnabled: true,
  automaticAccountingAvailable: true,
  browserAIConsentRequired: true, browserAIEnabled: false,
  browserAIStatusCode: "settingsUnavailable"
}).ai[0], "Privacy check unavailable");
const accountingUnavailable = context.assessBridgeStatus({
  ok: true, bridgeAvailable: true, protocolVersion: 1, compatible: true,
  providerConfigured: true, webInlineEnabled: true,
  automaticAccountingAvailable: false
});
assert.equal(accountingUnavailable.app[0], "Connected");
assert.equal(accountingUnavailable.ai[0], "Usage safety unavailable");
assert.match(accountingUnavailable.detail, /Local checks still work/);
assert.match(accountingUnavailable.detail, /Check Accounting Again/);
assert.match(accountingUnavailable.detail, /Full Reset in Privacy & Help is a data-erasing last resort/);
assert.match(accountingUnavailable.detail, /contact Support if reset fails/);
assert.doesNotMatch(accountingUnavailable.detail, /clear usage|clear usage\/history/i);

const incompatible = context.assessBridgeStatus({
  ok: true, bridgeAvailable: true, protocolVersion: 2, compatible: false,
  providerConfigured: true, webInlineEnabled: true
});
assert.equal(incompatible.app[0], "Update required");

// A native bridge that never answers must always leave the visible Checking…
// state, re-enable the retry control, and ignore a response that arrives after
// the timeout has already settled the attempt.
deferStatus = true;
pendingStatusCallback = null;
context.checkConnection();
assert.equal(element("app-status").statusValue.textContent, "Checking…");
assert.equal(element("ai-status").statusValue.textContent, "Checking…");
assert.equal(element("check-connection").disabled, true);
const [timeoutID, timeoutCallback] = Array.from(timers.entries()).at(-1);
timers.delete(timeoutID);
timeoutCallback();
assert.equal(element("app-status").statusValue.textContent, "Bean app not connected");
assert.equal(element("ai-status").statusValue.textContent, "Local checks only");
assert.equal(element("check-connection").disabled, false);
pendingStatusCallback(readyStatus);
assert.equal(element("app-status").statusValue.textContent, "Bean app not connected",
  "a response after timeout cannot revive a settled connection attempt");
deferStatus = false;

// The real HTML can be opened on localhost for visual QA without extension APIs.
const previewElements = new Map();
const previewContext = {
  document: {
    getElementById: (id) => {
      if (!previewElements.has(id)) previewElements.set(id, new FakeElement(id));
      return previewElements.get(id);
    },
    createElement: () => new FakeElement()
  },
  URL,
  Set,
  Number,
  setTimeout: () => 1,
  clearTimeout: () => {}
};
assert.doesNotThrow(() => vm.runInNewContext(source, previewContext));
assert.match(previewElements.get("notice").textContent, /Preview mode/);

console.log("Browser extension options tests passed");
