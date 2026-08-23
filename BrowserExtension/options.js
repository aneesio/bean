// Bean options: an autosaving blocklist and truthful app/AI readiness.
// This page stores hostnames only. It never receives or stores writing.
const BRIDGE_PROTOCOL_VERSION = 1;
const STATUS_TIMEOUT_MS = 5000;

function extensionAPI() {
  return typeof chrome !== "undefined" && chrome.runtime && chrome.storage && chrome.storage.local
    ? chrome
    : null;
}

function normalizeHost(value) {
  const raw = String(value || "").trim().toLowerCase();
  if (!raw) return null;
  try {
    const url = new URL(raw.includes("://") ? raw : `https://${raw}`);
    if (!["http:", "https:"].includes(url.protocol)) return null;
    if (!url.hostname || url.hostname.includes("*") || url.username || url.password) return null;
    let host = url.hostname.toLowerCase().replace(/\.$/, "");
    // `.example.com` is a common shorthand for a domain and its subdomains.
    // Bean already applies that scope to every rule, so store the enforceable
    // canonical hostname rather than a misleading leading-dot rule.
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
  } catch (_error) {
    return null;
  }
}

function parseSites(text) {
  const sites = String(text || "").split(/[\s,]+/).filter(Boolean).map(normalizeHost);
  if (sites.some((site) => !site)) return null;
  return [...new Set(sites)].sort();
}

function normalizeStoredSites(sites) {
  if (!Array.isArray(sites)) return [];
  return [...new Set(sites.map(normalizeHost).filter(Boolean))].sort();
}

function assessBridgeStatus(response) {
  if (response && response.errorCode === "nativeHostForbidden") {
    return {
      app: ["Connection not authorized", "error"],
      ai: ["Local checks only", "neutral"],
      detail: "Open Bean → Settings → Browser and repair the connection for this extension."
    };
  }
  if (response && response.errorCode === "notInstalled") {
    return {
      app: ["Connection not installed", "error"],
      ai: ["Local checks only", "neutral"],
      detail: "Open Bean → Settings → Browser to install the connection automatically."
    };
  }
  if (!response || !response.ok) {
    return {
      app: ["Bean app not connected", "error"],
      ai: ["Local checks only", "neutral"],
      detail: "Open Bean, then use Bean → Settings → Browser if the connection needs repair."
    };
  }
  if (response.compatible === false || response.protocolVersion !== BRIDGE_PROTOCOL_VERSION) {
    return {
      app: ["Update required", "error"],
      ai: ["Unavailable until updated", "error"],
      detail: "Bean and this extension use different connection versions. Update both, then check again."
    };
  }
  if (response.bridgeAvailable !== true) {
    return {
      app: ["Connection needs attention", "error"],
      ai: ["Local checks only", "neutral"],
      detail: "Open Bean → Settings → Browser and repair the browser connection."
    };
  }
  if (!response.providerConfigured) {
    return {
      app: [`Connected${response.appVersion ? ` · Bean ${response.appVersion}` : ""}`, "ok"],
      ai: ["Not set up", "neutral"],
      detail: "Local checks are ready. Add an AI provider in Bean only if you want deeper suggestions."
    };
  }
  if (!response.webInlineEnabled) {
    return {
      app: [`Connected${response.appVersion ? ` · Bean ${response.appVersion}` : ""}`, "ok"],
      ai: ["Off in Bean", "neutral"],
      detail: "Local checks are ready. Turn on browser AI in the Bean app for deeper suggestions."
    };
  }
  if (response.automaticAccountingAvailable !== true) {
    return {
      app: [`Connected${response.appVersion ? ` · Bean ${response.appVersion}` : ""}`, "ok"],
      ai: ["Usage safety unavailable", "error"],
      detail: "Local checks still work. Open Bean → Settings → AI & Usage and choose Check Accounting Again. If the warning remains after reopening Bean, Full Reset in Privacy & Help is a data-erasing last resort; contact Support if reset fails."
    };
  }
  if (response.browserAIStatusCode === "settingsUnavailable") {
    return {
      app: [`Connected${response.appVersion ? ` · Bean ${response.appVersion}` : ""}`, "ok"],
      ai: ["Privacy check unavailable", "error"],
      detail: "Bean could not verify extension privacy settings. Check again before using browser AI."
    };
  }
  if (response.browserAIConsentRequired === true || response.browserAIEnabled === false) {
    return {
      app: [`Connected${response.appVersion ? ` · Bean ${response.appVersion}` : ""}`, "ok"],
      ai: ["Waiting for you", "warn"],
      detail: "Local checks are ready. Your previous browser-AI opt-out is preserved; allow it only if you want deeper suggestions."
    };
  }
  return {
    app: [`Connected${response.appVersion ? ` · Bean ${response.appVersion}` : ""}`, "ok"],
    ai: ["Ready", "ok"],
    detail: "Local checks are free. Deeper suggestions use your connected provider and its API tokens."
  };
}

let blockedSites = [];

function byId(id) { return document.getElementById(id); }

function announce(message, isError = false) {
  const notice = byId("notice");
  if (!notice) return;
  notice.textContent = message;
  notice.className = isError ? "error" : "";
}

function setStatus(id, descriptor) {
  const element = byId(id);
  if (!element) return;
  const [text, tone] = descriptor;
  element.className = `status-value tone-${tone}`;
  const value = element.querySelector ? element.querySelector("span:last-child") : null;
  if (value) value.textContent = text;
  else element.textContent = text;
}

function renderBlockedSites() {
  const list = byId("blocked-list");
  if (!list || typeof document.createElement !== "function") return;
  list.replaceChildren();
  if (!blockedSites.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "No blocked websites";
    list.appendChild(empty);
    return;
  }
  for (const host of blockedSites) {
    const row = document.createElement("div");
    row.className = "site-item";
    const label = document.createElement("span");
    label.className = "site-host";
    label.textContent = host;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "remove";
    remove.textContent = "Remove";
    remove.setAttribute("aria-label", `Allow Bean on ${host}`);
    remove.addEventListener("click", () => removeBlockedSite(host));
    row.append(label, remove);
    list.appendChild(row);
  }
}

function persistBlockedSites(operation, hosts, message) {
  const api = extensionAPI();
  if (!api) { announce("Extension controls are available after Bean is installed in Chrome.", true); return; }
  announce("Saving website choice…");
  // All blocklist mutations are serialized by the service worker. Its returned
  // list is authoritative, so two open settings surfaces cannot overwrite one
  // another with stale snapshots.
  api.runtime.sendMessage({ type: "mutateBlockedSites", operation, hosts }, (result) => {
    const runtimeError = api.runtime.lastError;
    if (runtimeError || !result || !result.ok || !Array.isArray(result.blockedSites)) {
      // The service worker persists the privacy choice before it refreshes
      // Chrome's dynamic content-script registration. Chrome can suspend or
      // restart that worker during the refresh and close this response channel
      // even though storage already contains the requested change. Re-read the
      // authoritative local value before reporting a false failure.
      api.storage.local.get(["blockedSites"], (settings) => {
        const readError = api.runtime.lastError;
        const savedSites = !readError && settings
          ? normalizeStoredSites(settings.blockedSites)
          : null;
        const applied = savedSites && (operation === "remove"
          ? hosts.every((host) => !savedSites.includes(host))
          : operation === "add"
            ? hosts.every((host) => savedSites.includes(host))
            : false);
        if (!applied) {
          announce("Bean could not save that change. Try again.", true);
          return;
        }
        blockedSites = savedSites;
        renderBlockedSites();
        // Ask the worker to finish the visibility-layer refresh. Storage is
        // already authoritative, so a lost refresh response cannot undo the
        // user's choice.
        api.runtime.sendMessage({ type: "refreshRegistration" }, () => {
          void api.runtime.lastError;
        });
        announce(message || "Saved automatically. Reload an open page to apply the change.");
      });
      return;
    }
    blockedSites = normalizeStoredSites(result.blockedSites);
    renderBlockedSites();
    announce(result.registrationUpdated === false
      ? "Website choice saved. Restart your browser to finish updating Bean."
      : (message || "Saved automatically. Reload an open page to apply the change."));
  });
}

function addBlockedSites(value) {
  const additions = parseSites(value);
  if (!additions || !additions.length) {
    announce("Enter a website such as example.com.", true);
    return false;
  }
  persistBlockedSites("add", additions,
    `${additions.length === 1 ? additions[0] : `${additions.length} websites`} blocked.`);
  return true;
}

function removeBlockedSite(host) {
  persistBlockedSites("remove", [host],
    `${host} can use Bean again.`);
}

function renderBridgeResponse(response) {
  const status = assessBridgeStatus(response);
  setStatus("app-status", status.app);
  setStatus("ai-status", status.ai);
  const detail = byId("connection-detail");
  if (detail) detail.textContent = status.detail;
  const confirmation = byId("confirm-browser-ai");
  if (confirmation) {
    confirmation.hidden = !(response &&
      response.browserAIStatusCode === "browserAIConsentRequired" &&
      response.browserAIConsentRequired === true);
    confirmation.disabled = false;
  }
  const usageRow = byId("usage-row");
  if (usageRow) {
    const hasUsage = Number.isInteger(response && response.automaticCallsToday)
      && Number.isInteger(response && response.dailyAutomaticCallLimit);
    usageRow.hidden = !hasUsage;
    if (hasUsage) {
      const atLimit = response.automaticCallsToday >= response.dailyAutomaticCallLimit;
      setStatus("usage-status", [
        `${response.automaticCallsToday} of ${response.dailyAutomaticCallLimit}`,
        atLimit ? "warn" : "ok"
      ]);
    }
  }
}

function confirmBrowserAI() {
  const api = extensionAPI();
  const button = byId("confirm-browser-ai");
  if (!api || !button) return;
  button.disabled = true;
  announce("Saving your browser AI choice…");
  api.runtime.sendMessage({ type: "confirmBrowserAI" }, (response) => {
    const runtimeError = api.runtime.lastError;
    if (runtimeError || !response || !response.ok) {
      button.disabled = false;
      announce("Bean could not save that choice. Try again.", true);
      return;
    }
    button.hidden = true;
    announce("Browser AI is allowed. Local checks remain available without it.");
    checkConnection();
  });
}

function checkConnection() {
  const api = extensionAPI();
  const button = byId("check-connection");
  if (button) button.disabled = true;
  setStatus("app-status", ["Checking…", "neutral"]);
  setStatus("ai-status", ["Checking…", "neutral"]);
  if (!api) {
    renderBridgeResponse(null);
    if (button) button.disabled = false;
    return;
  }
  let finished = false;
  const finish = (response) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    if (button) button.disabled = false;
    renderBridgeResponse(response);
  };
  const timer = setTimeout(() => finish(null), STATUS_TIMEOUT_MS);
  try {
    api.runtime.sendMessage({ type: "getStatus" }, (response) => {
      const runtimeError = api.runtime.lastError;
      finish(runtimeError ? null : response);
    });
  } catch (_error) {
    finish(null);
  }
}

function load() {
  const api = extensionAPI();
  if (!api) {
    blockedSites = [];
    renderBlockedSites();
    renderBridgeResponse(null);
    announce("Preview mode — extension controls are unavailable on this page.");
    return;
  }
  api.storage.local.get(["blockedSites"], (settings) => {
    blockedSites = normalizeStoredSites(settings.blockedSites);
    renderBlockedSites();
  });
  if (api.storage.onChanged && typeof api.storage.onChanged.addListener === "function") {
    api.storage.onChanged.addListener((changes, areaName) => {
      if (areaName !== "local" || !changes.blockedSites) return;
      blockedSites = normalizeStoredSites(changes.blockedSites.newValue);
      renderBlockedSites();
    });
  }
  checkConnection();
}

const form = byId("add-site-form");
if (form) form.addEventListener("submit", (event) => {
  event.preventDefault();
  const input = byId("site-input");
  if (input && addBlockedSites(input.value)) input.value = "";
});
const checkButton = byId("check-connection");
if (checkButton) checkButton.addEventListener("click", checkConnection);
const confirmButton = byId("confirm-browser-ai");
if (confirmButton) confirmButton.addEventListener("click", confirmBrowserAI);
load();
