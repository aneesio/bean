const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class FakeElement {
  constructor(id = "") {
    this.id = id;
    this.textContent = "";
    this.className = "";
    this.disabled = false;
    this.listeners = {};
    this.statusValue = null;
  }
  addEventListener(type, listener) { this.listeners[type] = listener; }
  querySelector(selector) { return selector === "span:last-child" ? this.statusValue : null; }
}

const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, new FakeElement(id));
  return elements.get(id);
}
for (const id of ["app-status", "ai-status"]) element(id).statusValue = new FakeElement();

let saved = null;
const mutationMessages = [];
let reloadedTab = null;
let optionsOpened = false;
let statusCallback = null;
let storedSites = ["example.com"];
let storageChangedListener = null;
let mutationFailure = false;
let registrationUpdated = true;
let nextTimerID = 0;
const timers = new Map();
const readyStatus = {
  ok: true,
  bridgeAvailable: true,
  protocolVersion: 1,
  compatible: true,
  providerConfigured: true,
  webInlineEnabled: true,
  automaticAccountingAvailable: true
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
      if (message.type === "getStatus") statusCallback = callback;
      else if (message.type === "mutateBlockedSites") {
        mutationMessages.push(message);
        if (mutationFailure) {
          callback({ ok: false, errorCode: "settingsUnavailable" });
          return;
        }
        const previousBlockedSites = [...storedSites];
        if (message.operation === "allowHost") {
          storedSites = storedSites.filter((site) =>
            !(message.host === site || message.host.endsWith(`.${site}`)));
        } else if (message.operation === "add") {
          storedSites = [...new Set([...storedSites, ...message.hosts])].sort();
        }
        saved = { blockedSites: [...storedSites] };
        callback({
          ok: true,
          blockedSites: [...storedSites],
          previousBlockedSites,
          registrationUpdated
        });
      }
      else if (callback) callback({ ok: true });
    },
    openOptionsPage: () => { optionsOpened = true; }
  },
  tabs: {
    query: (_query, callback) => callback([{ id: 42, url: "https://mail.example.com/compose" }]),
    reload: (id, callback) => { reloadedTab = id; callback(); }
  }
};

const source = fs.readFileSync(path.join(__dirname, "..", "popup.js"), "utf8");
const html = fs.readFileSync(path.join(__dirname, "..", "popup.html"), "utf8");
const context = {
  chrome,
  document: { getElementById: element },
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
vm.runInNewContext(source, context);

assert.match(html, /id="site-state"/);
assert.match(html, /id="app-status"/);
assert.match(html, /id="ai-status"/);
assert.match(html, /Settings…/);
assert.match(html, /focus-visible[^}]*outline:3px solid var\(--accent\)/s,
  "toolbar controls use a high-contrast focus ring");
assert.equal(element("site-name").textContent, "mail.example.com");
assert.equal(element("site-state").textContent, "Blocked");
assert.equal(element("site-detail").textContent, "Blocked by example.com and its subdomains.");
assert.equal(element("site-action").textContent, "Enable example.com and its subdomains");

// Another Bean surface blocks a different site after this popup loaded. The
// click must mutate a fresh storage snapshot instead of erasing that new rule.
storedSites = ["example.com", "newly-blocked.test"];
element("site-action").listeners.click();
assert.deepEqual(JSON.parse(JSON.stringify(saved.blockedSites)), ["newly-blocked.test"],
  "the authoritative background mutation preserves a concurrent rule");
assert.equal(mutationMessages.at(-1).operation, "allowHost");
assert.equal(mutationMessages.at(-1).host, "mail.example.com");
assert.equal(reloadedTab, 42);
assert.match(element("message").textContent, /enabled for example\.com and its subdomains/);

statusCallback(readyStatus);
assert.equal(element("app-status").statusValue.textContent, "Connected");
assert.equal(element("ai-status").statusValue.textContent, "Ready");
assert.match(element("message").textContent, /enabled for example\.com and its subdomains/,
  "a late readiness response must not overwrite the site-change confirmation");

mutationFailure = true;
const beforeFailedMutation = [...storedSites];
element("site-action").listeners.click();
assert.deepEqual(storedSites, beforeFailedMutation,
  "a failed background mutation never changes the authoritative blocklist");
assert.match(element("message").textContent, /Could not save/, "popup reports mutation failure truthfully");
mutationFailure = false;

registrationUpdated = false;
storedSites = [];
storageChangedListener({ blockedSites: { newValue: [] } }, "local");
element("site-action").listeners.click();
assert.match(element("message").textContent, /Restart your browser/,
  "popup gives the recovery action that actually retries script registration");
registrationUpdated = true;

storageChangedListener({ blockedSites: { newValue: ["mail.example.com"] } }, "local");
assert.equal(element("site-state").textContent, "Blocked",
  "an external blocklist change updates the open popup");

element("open-settings").listeners.click();
assert.equal(optionsOpened, true);
assert.equal(context.normalizeTab({ id: 1, url: "chrome://extensions" }), null);
assert.deepEqual(
  JSON.parse(JSON.stringify(context.matchingBlocks("mail.example.com", ["example.com", "other.com"]))),
  ["example.com"]
);
assert.deepEqual(
  JSON.parse(JSON.stringify(context.normalizeStoredSites([".Example.com", "example.com", "..invalid.test"]))),
  ["example.com"],
  "toolbar status canonicalizes legacy leading-dot rules instead of claiming Bean is active"
);
assert.deepEqual(
  JSON.parse(JSON.stringify(context.matchingBlocks("mail.example.com", [".example.com"]))),
  [".example.com"]
);
assert.equal(context.assessBridgeStatus({
  ok: true, bridgeAvailable: true, protocolVersion: 2, compatible: false,
  providerConfigured: true, webInlineEnabled: true
}).app[0], "Update required");
assert.equal(context.assessBridgeStatus({
  ok: true, bridgeAvailable: true, protocolVersion: 1, compatible: true,
  providerConfigured: true, webInlineEnabled: true,
  automaticAccountingAvailable: true,
  browserAIConsentRequired: true, browserAIEnabled: false,
  browserAIStatusCode: "browserAIConsentRequired"
}).ai[0], "Confirmation needed");
const accountingUnavailable = context.assessBridgeStatus({
  ok: true, bridgeAvailable: true, protocolVersion: 1, compatible: true,
  providerConfigured: true, webInlineEnabled: true,
  automaticAccountingAvailable: false
});
assert.equal(accountingUnavailable.app[0], "Connected");
assert.equal(accountingUnavailable.ai[0], "Usage safety unavailable");
assert.match(accountingUnavailable.message, /Local checks still work/);
assert.match(accountingUnavailable.message, /Check Accounting Again/);
assert.match(accountingUnavailable.message, /Full Reset in Privacy & Help is a data-erasing last resort/);
assert.match(accountingUnavailable.message, /contact Support if reset fails/);
assert.doesNotMatch(accountingUnavailable.message, /clear usage|clear usage\/history/i);
assert.equal(context.assessBridgeStatus({
  ok: false, errorCode: "nativeHostForbidden", nativeHostInstalled: true
}).app[0], "Not authorized");
assert.equal(context.assessBridgeStatus({
  ok: false, errorCode: "notInstalled", nativeHostInstalled: false
}).app[0], "Not installed");

// A native bridge that never answers must settle instead of leaving the
// toolbar status indefinitely ambiguous. A response arriving after the
// timeout belongs to the expired attempt and must not revive it.
context.checkConnection();
const lateStatusCallback = statusCallback;
const [timeoutID, timeoutCallback] = Array.from(timers.entries()).at(-1);
timers.delete(timeoutID);
timeoutCallback();
assert.equal(element("app-status").statusValue.textContent, "Not connected");
assert.equal(element("ai-status").statusValue.textContent, "Local checks only");
lateStatusCallback(readyStatus);
assert.equal(element("app-status").statusValue.textContent, "Not connected",
  "a response after timeout cannot revive a settled connection attempt");

const previewElements = new Map();
const previewContext = {
  document: { getElementById: (id) => {
    if (!previewElements.has(id)) previewElements.set(id, new FakeElement(id));
    return previewElements.get(id);
  } },
  URL,
  Set,
  Number,
  setTimeout: () => 1,
  clearTimeout: () => {}
};
assert.doesNotThrow(() => vm.runInNewContext(source, previewContext));
assert.match(previewElements.get("message").textContent, /Preview mode/);

console.log("Browser extension popup tests passed");
