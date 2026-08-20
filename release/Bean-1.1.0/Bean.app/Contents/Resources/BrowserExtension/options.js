// Bean options page logic. Reads/writes the small local settings the content
// script uses, renders a status summary, and tests the native bridge. Stores no
// text and shows no user content.
function parseList(text) {
  return text.split(/\s+/).map((s) => s.trim()).filter(Boolean);
}

function setStatusCell(id, text, cls) {
  const el = document.getElementById(id);
  el.textContent = text;
  el.className = cls || "";
}

function renderStatus() {
  chrome.storage.local.get(["enabled", "allowlist", "blocklist", "useBridge", "localFallback"], (s) => {
    setStatusCell("s-enabled", s.enabled ? "On" : "Off", s.enabled ? "ok" : "off");
    const allow = s.allowlist || [], block = s.blocklist || [];
    const siteText = block.length || allow.length
      ? `${allow.length ? "allowlist (" + allow.length + ")" : "all sites"}${block.length ? ", blocklist (" + block.length + ")" : ""}`
      : "all sites";
    setStatusCell("s-site", siteText, "");
    setStatusCell("s-fallback", s.localFallback !== false ? "On" : "Off", s.localFallback !== false ? "ok" : "warn");
  });
}

function load() {
  chrome.storage.local.get(["enabled", "allowlist", "blocklist", "useBridge", "localFallback"], (s) => {
    document.getElementById("enabled").checked = !!s.enabled;
    document.getElementById("allowlist").value = (s.allowlist || []).join("\n");
    document.getElementById("blocklist").value = (s.blocklist || []).join("\n");
    document.getElementById("useBridge").checked = s.useBridge !== false;
    document.getElementById("localFallback").checked = s.localFallback !== false;
    renderStatus();
  });
}

function save() {
  const data = {
    enabled: document.getElementById("enabled").checked,
    allowlist: parseList(document.getElementById("allowlist").value),
    blocklist: parseList(document.getElementById("blocklist").value),
    useBridge: document.getElementById("useBridge").checked,
    localFallback: document.getElementById("localFallback").checked
  };
  chrome.storage.local.set(data, () => {
    const status = document.getElementById("status");
    status.textContent = "Saved.";
    setTimeout(() => (status.textContent = ""), 1500);
    renderStatus();
  });
}

function testBridge() {
  setStatusCell("s-bridge", "Checking…", "off");
  chrome.runtime.sendMessage({ type: "getStatus" }, (resp) => {
    if (!resp || !resp.ok) {
      const code = resp && resp.errorCode;
      if (!resp || code === "notInstalled" || code === "bridgeUnavailable") {
        setStatusCell("s-bridge", "Not installed — run the install script", "warn");
      } else {
        setStatusCell("s-bridge", "Error (" + (code || "unknown") + ")", "warn");
      }
      return;
    }
    if (!resp.providerConfigured) { setStatusCell("s-bridge", "Connected — add an API key in Bean Settings", "warn"); return; }
    if (!resp.webInlineEnabled) { setStatusCell("s-bridge", "Connected — turn on Web Inline Support in Bean", "warn"); return; }
    setStatusCell("s-bridge", "Connected to Bean " + (resp.appVersion || ""), "ok");
  });
}

document.getElementById("save").addEventListener("click", save);
document.getElementById("test").addEventListener("click", testBridge);
document.getElementById("useBridge").addEventListener("change", save);
document.getElementById("localFallback").addEventListener("change", save);
document.getElementById("copyCmd").addEventListener("click", () => {
  navigator.clipboard.writeText("./scripts/install_native_messaging_host.sh <extension-id>");
});
load();
