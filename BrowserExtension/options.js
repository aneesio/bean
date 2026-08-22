// Bean options. Local inline help works across ordinary websites by default.
// This page stores only preferences and blocked hostnames—never page text.
const SETTINGS_SCHEMA_VERSION = 4;
const STATUS_TIMEOUT_MS = 7000;

function normalizeHost(value) {
  const raw = value.trim().toLowerCase();
  if (!raw) return null;
  try {
    const url = new URL(raw.includes("://") ? raw : `https://${raw}`);
    if (!["http:", "https:"].includes(url.protocol)) return null;
    if (!url.hostname || url.hostname.includes("*") || url.username || url.password) return null;
    return url.hostname.toLowerCase();
  } catch (_error) {
    return null;
  }
}

function parseSites(text) {
  const sites = text.split(/\s+/).filter(Boolean).map(normalizeHost);
  if (sites.some((site) => !site)) return null;
  return [...new Set(sites)].sort();
}

function setStatusCell(id, text, cls) {
  const element = document.getElementById(id);
  element.textContent = text;
  element.className = cls || "";
}

function renderStatus() {
  chrome.storage.local.get(["enabled", "blockedSites", "localFallback"], (settings) => {
    const sites = settings.blockedSites || [];
    const enabled = settings.enabled !== false;
    setStatusCell("s-enabled", enabled ? "On everywhere" : "Paused", enabled ? "ok" : "off");
    setStatusCell("s-sites", sites.length ? `${sites.length} blocked` : "No blocked websites", "ok");
    setStatusCell("s-fallback", settings.localFallback !== false ? "On — no token cost" : "Off",
                  settings.localFallback !== false ? "ok" : "warn");
  });
}

function load() {
  document.getElementById("extensionID").textContent = chrome.runtime.id || "Unavailable";
  chrome.storage.local.get(
    ["enabled", "blockedSites", "useBridge", "localFallback", "settingsSchemaVersion"],
    (settings) => {
      document.getElementById("enabled").checked = settings.enabled !== false;
      document.getElementById("sites").value = (settings.blockedSites || []).join("\n");
      document.getElementById("useBridge").checked =
        settings.settingsSchemaVersion >= SETTINGS_SCHEMA_VERSION && !!settings.useBridge;
      document.getElementById("localFallback").checked = settings.localFallback !== false;
      renderStatus();
    }
  );
}

function showMessage(text, isError = false) {
  const status = document.getElementById("status");
  status.textContent = text;
  status.className = isError ? "warn" : "muted";
}

function save() {
  const sites = parseSites(document.getElementById("sites").value);
  if (!sites) { showMessage("Enter website names only, such as example.com.", true); return; }

  chrome.storage.local.set({
    enabled: document.getElementById("enabled").checked,
    blockedSites: sites,
    useBridge: document.getElementById("useBridge").checked,
    localFallback: document.getElementById("localFallback").checked,
    settingsSchemaVersion: SETTINGS_SCHEMA_VERSION
  }, () => {
    chrome.runtime.sendMessage({ type: "refreshRegistration" }, () => {
      void chrome.runtime.lastError;
      showMessage("Saved. Reload an open page if you changed its website access.");
      renderStatus();
    });
  });
}

function testBridge() {
  const button = document.getElementById("test");
  button.disabled = true;
  setStatusCell("s-bridge", "Checking…", "off");
  let finished = false;
  let timer;

  const finish = (response, runtimeMessage = "") => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    button.disabled = false;
    if (!response || !response.ok) {
      const code = response && response.errorCode;
      setStatusCell("s-bridge", "Needs attention", "warn");
      showMessage(
        code === "bridgeTimeout"
          ? "Bean did not respond. Open Bean → Settings → Browser and choose Repair Connection."
          : `Open Bean → Settings → Browser and finish the connection.${runtimeMessage ? ` (${runtimeMessage})` : ""}`,
        true
      );
      return;
    }
    if (Number.isInteger(response.automaticCallsToday) && Number.isInteger(response.dailyAutomaticCallLimit)) {
      setStatusCell("s-budget", `${response.automaticCallsToday} of ${response.dailyAutomaticCallLimit} today`,
                    response.automaticCallsToday >= response.dailyAutomaticCallLimit ? "warn" : "ok");
    }
    if (!response.providerConfigured) {
      setStatusCell("s-bridge", "Connected — AI not set up", "warn");
      showMessage("The local checker is ready. Add an API key in Bean only if you want deeper checks.");
      return;
    }
    if (!response.webInlineEnabled) {
      setStatusCell("s-bridge", "Connected — web AI is off", "warn");
      showMessage("The local checker is ready. Turn on Web AI in Bean if you want deeper checks.");
      return;
    }
    setStatusCell("s-bridge", `Connected to Bean ${response.appVersion || ""}`, "ok");
    showMessage("Everything is connected.");
  };

  timer = setTimeout(() => finish({ ok: false, errorCode: "bridgeTimeout" }), STATUS_TIMEOUT_MS);
  chrome.runtime.sendMessage({ type: "getStatus" }, (response) => {
    const runtimeMessage = (chrome.runtime.lastError || {}).message || "";
    finish(response, runtimeMessage);
  });
}

document.getElementById("save").addEventListener("click", save);
document.getElementById("test").addEventListener("click", testBridge);
document.getElementById("copyID").addEventListener("click", () => {
  navigator.clipboard.writeText(chrome.runtime.id || "");
  showMessage("Extension ID copied.");
});
load();
setTimeout(testBridge, 150);
