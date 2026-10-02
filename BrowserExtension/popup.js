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
  const localMessage = response && response.localCheckAvailable === true
    ? "The Mac spelling connection is ready."
    : "Basic checks only. Update Bean and repair the Mac connection for full spelling checks.";
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
    message: "Open Bean and connect it for full spelling checks. Basic checks remain available."
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
    message: localMessage
  };
  if (!response.webInlineEnabled) return {
    app: ["Connected", "ok"], ai: ["Off in Bean", "neutral"],
    message: `${localMessage} Explicit Proofread and Rewrite remain available.`
  };
  if (response.automaticAccountingAvailable !== true) return {
    app: ["Connected", "ok"], ai: ["Usage safety unavailable", "error"],
    message: "Local checks still work. Open Bean → Settings → AI & Usage and choose Check Accounting Again."
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
let pausedSites = {};
let pauseTimer = null;
let siteChangeOwnsMessage = false;
let siteSettingsAvailable = false;

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
  const pause = byId("site-pause");
  if (pause) { pause.hidden = !currentTab; pause.disabled = true; }
  if (!currentTab) {
    if (name) name.textContent = "Bean is unavailable here";
    if (detail) detail.textContent = "Browser and extension pages do not allow writing helpers.";
    if (state) { state.textContent = "Unavailable"; state.className = "pill"; }
    if (action) { action.disabled = true; action.textContent = "Website controls unavailable"; }
    return;
  }
  if (!siteSettingsAvailable) {
    if (name) name.textContent = currentTab.host;
    if (detail) detail.textContent = "Website preferences are unavailable. Reopen this popup to try again.";
    if (state) { state.textContent = "Unavailable"; state.className = "pill"; }
    if (action) { action.disabled = true; action.textContent = "Website controls unavailable"; }
    return;
  }
  const matches = matchingBlocks(currentTab.host, blockedSites);
  const blocked = matches.length > 0;
  const until = BeanSitePolicy.until(pausedSites,currentTab.host);
  if (pause) { pause.hidden = blocked; pause.disabled = false; pause.textContent = until ? "Resume on this website" : "Pause for 1 hour"; }
  if (pauseTimer) clearTimeout(pauseTimer);
  if (until) pauseTimer = setTimeout(renderSite,Math.max(1,until - Date.now() + 25));
  const coveringRule = blocked
    ? [...matches].sort((left, right) => left.split(".").length - right.split(".").length || left.length - right.length)[0]
    : null;
  const coveredByParent = coveringRule && coveringRule !== currentTab.host;
  if (name) name.textContent = currentTab.host;
  if (detail) detail.textContent = blocked
    ? (coveredByParent
      ? `Blocked by ${coveringRule} and its subdomains.`
      : "Bean stays hidden on this website.")
    : until ? `Paused for ${Math.max(1,Math.ceil((until - Date.now()) / 60000))} more minutes. Your draft stays where it is.`
    : "Bean checks supported writing fields locally.";
  if (state) { state.textContent = blocked ? "Blocked" : until ? "Paused" : "Active"; state.className = `pill ${blocked ? "blocked" : "active"}`; }
  if (action) {
    action.disabled = false;
    action.textContent = blocked
      ? (coveredByParent ? `Enable ${coveringRule} and its subdomains` : "Enable on this website")
      : "Block this website";
    action.className = blocked ? "primary" : "";
  }
}

function toggleSitePause() {
  const api = extensionAPI();
  if (!api || !currentTab || !siteSettingsAvailable) return;
  const button = byId("site-pause");
  if (button) button.disabled = true;
  const resuming = !!BeanSitePolicy.until(pausedSites,currentTab.host);
  siteChangeOwnsMessage = true;
  api.runtime.sendMessage({type:"mutateSitePause",operation:resuming ? "resume" : "pause",host:currentTab.host},(result) => {
    const error = api.runtime.lastError, saved = result && result.ok && BeanSitePolicy.normalize(result.pausedSites);
    if (error || !saved) { showMessage("Could not save this website pause.",true); renderSite(); return; }
    pausedSites = saved; renderSite();
    showMessage(resuming ? "Bean resumed. Your draft stays where it is." : "Paused for one hour. Resume here any time.");
  });
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
    siteSettingsAvailable = true;
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
          ? `Bean enabled for ${coveringRule} and its subdomains. Reload this page when your draft is saved.`
          : "Bean enabled. Reload this page when your draft is saved.")
        : "Bean is off on this website. Your draft stays where it is."));
    renderSite();
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
  api.storage.local.get(["blockedSites","pausedSites"], (settings) => {
    const readError = api.runtime.lastError;
    const sites = settings && settings.blockedSites;
    const pauses = settings && BeanSitePolicy.normalize(settings.pausedSites);
    pausedSites = pauses || {};
    siteSettingsAvailable = !readError && !!settings && !!pauses && (sites === undefined ||
      (Array.isArray(sites) && sites.every((value) => !!normalizeStoredHost(value))));
    blockedSites = siteSettingsAvailable ? normalizeStoredSites(sites) : [];
    if (!api.tabs || typeof api.tabs.query !== "function") { renderSite(); return; }
    api.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      currentTab = normalizeTab(tabs && tabs[0]);
      renderSite();
    });
  });
  if (api.storage.onChanged && typeof api.storage.onChanged.addListener === "function") {
    api.storage.onChanged.addListener((changes, areaName) => {
      if (areaName !== "local" || !changes || (!changes.blockedSites && !changes.pausedSites)) return;
      const sites = changes.blockedSites ? changes.blockedSites.newValue : blockedSites;
      const pauses = changes.pausedSites ? BeanSitePolicy.normalize(changes.pausedSites.newValue) : pausedSites;
      pausedSites = pauses || {};
      siteSettingsAvailable = !!pauses && (sites === undefined ||
        (Array.isArray(sites) && sites.every((value) => !!normalizeStoredHost(value))));
      blockedSites = siteSettingsAvailable ? normalizeStoredSites(sites) : [];
      renderSite();
    });
  }
  checkConnection();
}

const siteAction = byId("site-action");
if (siteAction) siteAction.addEventListener("click", toggleCurrentSite);
const sitePause = byId("site-pause");
if (sitePause) sitePause.addEventListener("click",toggleSitePause);
const settingsButton = byId("open-settings");
if (settingsButton) settingsButton.addEventListener("click", () => {
  const api = extensionAPI();
  if (api && typeof api.runtime.openOptionsPage === "function") api.runtime.openOptionsPage();
});
load();
