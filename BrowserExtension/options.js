// Bean options page. Stores settings and exact hostnames only; it never reads
// or stores page text. Site permissions are requested from this user gesture.
const SETTINGS_SCHEMA_VERSION = 3;

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

function originsForSites(sites) {
  return sites.flatMap((site) => [`http://${site}/*`, `https://${site}/*`]);
}

function setStatusCell(id, text, cls) {
  const element = document.getElementById(id);
  element.textContent = text;
  element.className = cls || "";
}

function renderStatus() {
  chrome.storage.local.get(["enabled", "allowedSites", "localFallback"], (settings) => {
    const sites = settings.allowedSites || [];
    setStatusCell("s-enabled", settings.enabled ? "On" : "Off", settings.enabled ? "ok" : "off");
    setStatusCell("s-site", sites.length ? `${sites.length} approved` : "No sites approved", sites.length ? "ok" : "off");
    setStatusCell("s-fallback", settings.localFallback !== false ? "On" : "Off", settings.localFallback !== false ? "ok" : "warn");
    const active = !!settings.enabled;
    setStatusCell("s-gmail", active && sites.includes("mail.google.com") ? "Approved" : "Not approved",
                  active && sites.includes("mail.google.com") ? "ok" : "off");
    setStatusCell("s-slack", active && sites.includes("app.slack.com") ? "Approved" : "Not approved",
                  active && sites.includes("app.slack.com") ? "ok" : "off");
  });
}

function load() {
  chrome.storage.local.get(
    ["enabled", "allowedSites", "useBridge", "localFallback", "settingsSchemaVersion"],
    (settings) => {
      document.getElementById("enabled").checked = !!settings.enabled;
      document.getElementById("sites").value = (settings.allowedSites || []).join("\n");
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
  if (!sites) { showMessage("Enter hostnames only, such as mail.google.com.", true); return; }

  const wantsEnabled = document.getElementById("enabled").checked;
  if (wantsEnabled && !sites.length) {
    showMessage("Add at least one site before enabling Bean.", true);
    return;
  }

  const desiredOrigins = originsForSites(sites);
  const persist = () => {
    chrome.permissions.getAll((current) => {
      const currentOrigins = (current.origins || []).filter((origin) => /^https?:\/\//.test(origin));
      const obsolete = currentOrigins.filter((origin) => !desiredOrigins.includes(origin));
      const finish = () => {
        chrome.storage.local.set({
          enabled: wantsEnabled,
          allowedSites: sites,
          useBridge: document.getElementById("useBridge").checked,
          localFallback: document.getElementById("localFallback").checked,
          settingsSchemaVersion: SETTINGS_SCHEMA_VERSION
        }, () => {
          chrome.runtime.sendMessage({ type: "refreshRegistration" }, () => {
            void chrome.runtime.lastError;
            showMessage("Saved. Reload open pages on newly approved sites.");
            renderStatus();
          });
        });
      };
      if (obsolete.length) chrome.permissions.remove({ origins: obsolete }, finish);
      else finish();
    });
  };

  if (!desiredOrigins.length) { persist(); return; }
  chrome.permissions.request({ origins: desiredOrigins }, (granted) => {
    if (!granted) { showMessage("Site access was not granted; settings were not changed.", true); return; }
    persist();
  });
}

function testBridge() {
  setStatusCell("s-bridge", "Checking…", "off");
  chrome.runtime.sendMessage({ type: "getStatus" }, (response) => {
    if (!response || !response.ok) {
      const code = response && response.errorCode;
      setStatusCell(
        "s-bridge",
        !response || code === "notInstalled" || code === "bridgeUnavailable"
          ? "Not installed — see setup guide"
          : `Error (${code || "unknown"})`,
        "warn"
      );
      return;
    }
    if (Number.isInteger(response.automaticCallsToday) && Number.isInteger(response.dailyAutomaticCallLimit)) {
      setStatusCell("s-budget", `${response.automaticCallsToday} of ${response.dailyAutomaticCallLimit} automatic calls today`,
                    response.automaticCallsToday >= response.dailyAutomaticCallLimit ? "warn" : "ok");
    }
    if (!response.providerConfigured) { setStatusCell("s-bridge", "Connected — add an API key in Bean", "warn"); return; }
    if (!response.webInlineEnabled) { setStatusCell("s-bridge", "Connected — enable Web Inline Support in Bean", "warn"); return; }
    setStatusCell("s-bridge", `Connected to Bean ${response.appVersion || ""}`, "ok");
  });
}

document.getElementById("save").addEventListener("click", save);
document.getElementById("test").addEventListener("click", testBridge);
document.getElementById("copyCmd").addEventListener("click", () => {
  navigator.clipboard.writeText('\"/Applications/Bean.app/Contents/Resources/NativeMessaging/install_native_messaging_host.sh\" <extension-id> \"/Applications/Bean.app\"');
});
load();
