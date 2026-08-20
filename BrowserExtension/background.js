// Bean extension service worker. Bridges the content script to the Bean Mac app
// via Chrome Native Messaging (the Bean binary runs as the host). Content
// scripts can't use nativeMessaging directly, so they message the background.
//
// Stores no text. Forwards request text to the local Bean host only.
const HOST = "com.bean.nativehost";
const SETTINGS_SCHEMA_VERSION = 2;

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get(["enabled", "settingsSchemaVersion"], (s) => {
    const update = {};
    if (s.enabled === undefined) {
      // Provider-backed checks are opt-in separately because they can create an
      // API call after each typing pause. The offline detector remains available.
      Object.assign(update, { enabled: false, allowlist: [], blocklist: [], localFallback: true });
    }
    // Old extension versions defaulted the paid native bridge on. Disable it
    // once on upgrade; a later explicit opt-in is preserved by this version key.
    if ((s.settingsSchemaVersion || 0) < SETTINGS_SCHEMA_VERSION) {
      update.useBridge = false;
      update.settingsSchemaVersion = SETTINGS_SCHEMA_VERSION;
    }
    if (Object.keys(update).length) chrome.storage.local.set(update);
  });
});

chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());

function sendNative(message, sendResponse, notInstalledCode) {
  try {
    chrome.runtime.sendNativeMessage(HOST, message, (resp) => {
      if (chrome.runtime.lastError || !resp) {
        sendResponse({ ok: false, errorCode: notInstalledCode, message: (chrome.runtime.lastError || {}).message || "" });
        return;
      }
      sendResponse(resp);
    });
  } catch (e) {
    sendResponse({ ok: false, errorCode: notInstalledCode, message: String(e) });
  }
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "detectIssues") {
    sendNative(msg.request, sendResponse, "bridgeUnavailable");
    return true; // async
  }
  if (msg && msg.type === "proofreadParagraph") {
    sendNative(msg.request, sendResponse, "bridgeUnavailable");
    return true; // async
  }
  if (msg && msg.type === "getStatus") {
    sendNative({ id: "status", type: "getStatus" }, sendResponse, "notInstalled");
    return true;
  }
  return false;
});
