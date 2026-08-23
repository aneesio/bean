// Toolbar popup: current-site control plus truthful native app/AI readiness.
const BRIDGE_PROTOCOL_VERSION = 1;
const STATUS_TIMEOUT_MS = 4500;

function extensionAPI() {
  return typeof chrome !== "undefined" && chrome.runtime && chrome.storage && chrome.storage.local
    ? chrome
    : null;
}

function normalizeTab(tab) {
  if (!tab || !tab.url) return null;
  try {
    const url = new URL(tab.url);
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname) return null;
    const host = normalizeStoredHost(url.hostname);
    return host ? { id: tab.id, host } : null;
  } catch (_error) {
    return null;
  }
}

function normalizeStoredHost(value) {
  if (typeof value !== "string") return null;
  let host = value.trim().toLowerCase().replace(/\.$/, "");
  if (host.startsWith(".")) {
    host = host.slice(1);
    if (host.startsWith(".")) return null;
  }
  if (!host || host.length > 253 || /[\s/@*]/.test(host)) return null;
  if (host.startsWith("[") && host.endsWith("]")) {
    return /^\[[0-9a-f:.]+\]$/.test(host) ? host : null;
  }
  return host.split(".").every((label) =>
    /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) ? host : null;
}

function hostIsBlocked(currentHost, blockedHost) {
  const normalized = normalizeStoredHost(blockedHost);
  return !!normalized && (currentHost === normalized || currentHost.endsWith(`.${normalized}`));
}

function matchingBlocks(host, sites) {
  return (sites || []).filter((site) => hostIsBlocked(host, site));
}

function normalizeStoredSites(sites) {
  if (!Array.isArray(sites)) return [];
  return [...new Set(sites.map(normalizeStoredHost).filter(Boolean))].sort();
}

function assessBridgeStatus(response) {
  if (response && response.errorCode === "nativeHostForbidden") return {
    app: ["Not authorized", "error"], ai: ["Local checks only", "neutral"],
    message: "Repair this extension's connection in Bean Settings."
  };
  if (response && response.errorCode === "notInstalled") return {
    app: ["Not installed", "error"], ai: ["Local checks only", "neutral"],
    message: "Open Bean Settings to install the connection."
  };
  if (!response || !response.ok) return {
    app: ["Not connected", "error"], ai: ["Local checks only", "neutral"],
    message: "Open the Bean app for optional AI help."
  };
  if (response.compatible === false || response.protocolVersion !== BRIDGE_PROTOCOL_VERSION) return {
    app: ["Update required", "error"], ai: ["Unavailable", "error"],
    message: "Update Bean and the extension."
  };
  if (response.bridgeAvailable !== true) return {
    app: ["Needs attention", "error"], ai: ["Local checks only", "neutral"],
    message: "Repair the connection in Bean Settings."
  };
  if (!response.providerConfigured) return {
    app: ["Connected", "ok"], ai: ["Not set up", "neutral"],
    message: "Local checks are ready."
  };
  if (!response.webInlineEnabled) return {
    app: ["Connected", "ok"], ai: ["Off in Bean", "neutral"],
    message: "Local checks are ready."
  };
  if (response.automaticAccountingAvailable !== true) return {
    app: ["Connected", "ok"], ai: ["Usage safety unavailable", "error"],
    message: "Local checks still work. Open Bean → Settings → AI & Usage and choose Check Accounting Again. If the warning remains after reopening Bean, Full Reset in Privacy & Help is a data-erasing last resort; contact Support if reset fails."
  };
  if (response.browserAIStatusCode === "settingsUnavailable") return {
    app: ["Connected", "ok"], ai: ["Privacy check unavailable", "error"],
    message: "Check again before using browser AI."
  };
  if (response.browserAIConsentRequired === true || response.browserAIEnabled === false) return {
    app: ["Connected", "ok"], ai: ["Confirmation needed", "warn"],
    message: "Your previous AI opt-out is preserved. Confirm once in Settings if you want browser AI."
  };
  return { app: ["Connected", "ok"], ai: ["Ready", "ok"], message: "Bean is ready here." };
}

let currentTab = null;
let blockedSites = [];
let siteChangeOwnsMessage = false;

function byId(id) { return document.getElementById(id); }

function showMessage(text, isError = false) {
  const element = byId("message");
  if (!element) return;
  element.textContent = text;
  element.className = isError ? "error" : "";
}

function setStatus(id, descriptor) {
  const element = byId(id);
  if (!element) return;
  const [text, tone] = descriptor;
  element.className = `value tone-${tone}`;
  const value = element.querySelector ? element.querySelector("span:last-child") : null;
  if (value) value.textContent = text;
  else element.textContent = text;
}

function renderSite() {
  const name = byId("site-name");
  const detail = byId("site-detail");
  const state = byId("site-state");
  const action = byId("site-action");
  if (!currentTab) {
    if (name) name.textContent = "Bean is unavailable here";
    if (detail) detail.textContent = "Browser and extension pages do not allow writing helpers.";
    if (state) { state.textContent = "Unavailable"; state.className = "pill"; }
    if (action) { action.disabled = true; action.textContent = "Website controls unavailable"; }
    return;
  }
  const matches = matchingBlocks(currentTab.host, blockedSites);
  const blocked = matches.length > 0;
  const coveringRule = blocked
    ? [...matches].sort((left, right) => left.split(".").length - right.split(".").length || left.length - right.length)[0]
    : null;
  const coveredByParent = coveringRule && coveringRule !== currentTab.host;
  if (name) name.textContent = currentTab.host;
  if (detail) detail.textContent = blocked
    ? (coveredByParent
      ? `Blocked by ${coveringRule} and its subdomains.`
      : "Bean stays hidden on this website.")
    : "Bean checks supported writing fields locally.";
  if (state) { state.textContent = blocked ? "Blocked" : "Active"; state.className = `pill ${blocked ? "blocked" : "active"}`; }
  if (action) {
    action.disabled = false;
    action.textContent = blocked
      ? (coveredByParent ? `Enable ${coveringRule} and its subdomains` : "Enable on this website")
      : "Block this website";
    action.className = blocked ? "primary" : "";
  }
}

function toggleCurrentSite() {
  const api = extensionAPI();
  if (!api || !currentTab) return;
  const action = byId("site-action");
  if (action) action.disabled = true;
  siteChangeOwnsMessage = true;
  const intendedHost = currentTab.host;
  const enabling = matchingBlocks(intendedHost, blockedSites).length > 0;
  showMessage(enabling ? "Enabling Bean…" : "Blocking Bean…");
  api.runtime.sendMessage({
    type: "mutateBlockedSites",
    operation: enabling ? "allowHost" : "add",
    ...(enabling ? { host: intendedHost } : { hosts: [intendedHost] })
  }, (result) => {
    const runtimeError = api.runtime.lastError;
    if (runtimeError || !result || !result.ok || !Array.isArray(result.blockedSites)) {
      showMessage("Could not save this change.", true);
      renderSite();
      return;
    }
    blockedSites = normalizeStoredSites(result.blockedSites);
    const previousSites = normalizeStoredSites(result.previousBlockedSites);
    const previousMatches = matchingBlocks(intendedHost, previousSites);
    const coveringRule = previousMatches.length
      ? [...previousMatches].sort((left, right) => left.split(".").length - right.split(".").length || left.length - right.length)[0]
      : intendedHost;
    const enablingParent = enabling && coveringRule !== intendedHost;
    showMessage(result.registrationUpdated === false
      ? "Website choice saved. Restart your browser to finish updating Bean."
      : (enabling
        ? (enablingParent
          ? `Bean enabled for ${coveringRule} and its subdomains. Reloading…`
          : "Bean enabled. Reloading…")
        : "Bean blocked. Reloading…"));
    renderSite();
    if (api.tabs && Number.isInteger(currentTab.id)) {
      api.tabs.reload(currentTab.id, () => { void api.runtime.lastError; });
    }
  });
}

function renderBridgeResponse(response) {
  const status = assessBridgeStatus(response);
  setStatus("app-status", status.app);
  setStatus("ai-status", status.ai);
  if (!siteChangeOwnsMessage) showMessage(status.message);
}

function checkConnection() {
  const api = extensionAPI();
  if (!api) { renderBridgeResponse(null); return; }
  let finished = false;
  const finish = (response) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    renderBridgeResponse(response);
  };
  const timer = setTimeout(() => finish(null), STATUS_TIMEOUT_MS);
  try {
    api.runtime.sendMessage({ type: "getStatus" }, (response) => {
      const runtimeError = api.runtime.lastError;
      finish(runtimeError ? null : response);
    });
  }
  catch (_error) { finish(null); }
}

function load() {
  const api = extensionAPI();
  if (!api) {
    renderSite();
    renderBridgeResponse(null);
    showMessage("Preview mode — extension controls are unavailable.");
    return;
  }
  api.storage.local.get(["blockedSites"], (settings) => {
    blockedSites = normalizeStoredSites(settings.blockedSites);
    if (!api.tabs || typeof api.tabs.query !== "function") { renderSite(); return; }
    api.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      currentTab = normalizeTab(tabs && tabs[0]);
      renderSite();
    });
  });
  if (api.storage.onChanged && typeof api.storage.onChanged.addListener === "function") {
    api.storage.onChanged.addListener((changes, areaName) => {
      if (areaName !== "local" || !changes.blockedSites) return;
      blockedSites = normalizeStoredSites(changes.blockedSites.newValue);
      renderSite();
    });
  }
  checkConnection();
}

const siteAction = byId("site-action");
if (siteAction) siteAction.addEventListener("click", toggleCurrentSite);
const settingsButton = byId("open-settings");
if (settingsButton) settingsButton.addEventListener("click", () => {
  const api = extensionAPI();
  if (api && typeof api.runtime.openOptionsPage === "function") api.runtime.openOptionsPage();
});
load();
