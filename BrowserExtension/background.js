// Bean extension service worker. Registers the content script on ordinary web
// pages except sites the user blocks, and forwards optional provider requests
// to the local Bean native-messaging host. It never stores request text.
const HOST = "com.bean.nativehost";
const SETTINGS_SCHEMA_VERSION = 4;
const NATIVE_MESSAGE_TIMEOUT_MS = 5000;
const SCRIPT_ID = "bean-inline";
const SCRIPT_FILES = [
  "src/localDetector.js",
  "src/issueMapping.js",
  "src/overlay.js",
  "src/contentScript.js"
];

function patternsForHosts(hosts) {
  return [...new Set((hosts || []).flatMap((host) => [
    `http://${host}/*`,
    `https://${host}/*`,
    `http://*.${host}/*`,
    `https://*.${host}/*`
  ]))];
}

function syncRegisteredContentScript(done = () => {}) {
  chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] }, () => {
    // A missing previous registration sets runtime.lastError; reading it keeps
    // Chrome from reporting an unchecked error.
    void chrome.runtime.lastError;
    chrome.storage.local.get(["enabled", "blockedSites"], (settings) => {
      if (settings.enabled === false) { done(); return; }
      chrome.scripting.registerContentScripts([{
        id: SCRIPT_ID,
        matches: ["http://*/*", "https://*/*"],
        excludeMatches: patternsForHosts(settings.blockedSites),
        js: SCRIPT_FILES,
        runAt: "document_idle",
        persistAcrossSessions: true
      }], () => {
        void chrome.runtime.lastError;
        done();
      });
    });
  });
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get(
    ["enabled", "useBridge", "localFallback", "settingsSchemaVersion"],
    (settings) => {
      const update = {};
      if ((settings.settingsSchemaVersion || 0) < SETTINGS_SCHEMA_VERSION) {
        // Version 0.5 makes local inline help available everywhere and replaces
        // the allowlist with an opt-out blocklist. Provider-backed checks keep
        // their previous choice and remain off on a truly fresh installation.
        Object.assign(update, {
          enabled: true,
          blockedSites: [],
          useBridge: settings.settingsSchemaVersion ? !!settings.useBridge : false,
          localFallback: settings.localFallback !== false,
          settingsSchemaVersion: SETTINGS_SCHEMA_VERSION
        });
      }
      const finish = () => syncRegisteredContentScript();
      if (Object.keys(update).length) chrome.storage.local.set(update, finish);
      else finish();
    }
  );
});

chrome.runtime.onStartup.addListener(() => syncRegisteredContentScript());
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());

function sendNative(message, sendResponse, notInstalledCode) {
  let finished = false;
  const finish = (response) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    sendResponse(response);
  };
  const timer = setTimeout(() => {
    finish({
      ok: false,
      errorCode: "bridgeTimeout",
      message: "Bean did not respond in time."
    });
  }, NATIVE_MESSAGE_TIMEOUT_MS);
  try {
    chrome.runtime.sendNativeMessage(HOST, message, (response) => {
      if (chrome.runtime.lastError || !response) {
        finish({
          ok: false,
          errorCode: notInstalledCode,
          message: (chrome.runtime.lastError || {}).message || ""
        });
        return;
      }
      finish(response);
    });
  } catch (error) {
    finish({ ok: false, errorCode: notInstalledCode, message: String(error) });
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message && message.type === "refreshRegistration") {
    syncRegisteredContentScript(() => sendResponse({ ok: true }));
    return true;
  }
  if (message && message.type === "detectIssues") {
    sendNative(message.request, sendResponse, "bridgeUnavailable");
    return true;
  }
  if (message && message.type === "proofreadParagraph") {
    sendNative(message.request, sendResponse, "bridgeUnavailable");
    return true;
  }
  if (message && message.type === "getStatus") {
    sendNative({ id: "status", type: "getStatus" }, sendResponse, "notInstalled");
    return true;
  }
  return false;
});
