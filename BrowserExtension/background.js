// Bean extension service worker. Registers the content script only for sites
// the user explicitly grants, and forwards optional provider requests to the
// local Bean native-messaging host. It never stores request text.
const HOST = "com.bean.nativehost";
const SETTINGS_SCHEMA_VERSION = 3;
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
    `https://${host}/*`
  ]))];
}

function syncRegisteredContentScript(done = () => {}) {
  chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] }, () => {
    // A missing previous registration sets runtime.lastError; reading it keeps
    // Chrome from reporting an unchecked error.
    void chrome.runtime.lastError;
    chrome.storage.local.get(["enabled", "allowedSites"], (settings) => {
      const matches = settings.enabled ? patternsForHosts(settings.allowedSites) : [];
      if (!matches.length) { done(); return; }
      chrome.scripting.registerContentScripts([{
        id: SCRIPT_ID,
        matches,
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
        // Version 0.2 switches from blanket page injection to explicit site
        // grants. Do not carry an old "all sites" state across that boundary.
        Object.assign(update, {
          enabled: false,
          allowedSites: [],
          useBridge: false,
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
chrome.permissions.onRemoved.addListener(() => syncRegisteredContentScript());
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
