// Bean extension service worker. Registers the content script on ordinary web
// pages except sites the user blocks, and forwards optional provider requests
// to the local Bean native-messaging host. It never stores request text.
const HOST = "com.bean.nativehost";
const SETTINGS_SCHEMA_VERSION = 6;
const BRIDGE_PROTOCOL_VERSION = 1;
const MINIMUM_APP_VERSION = "1.6.0";
const STATUS_TIMEOUT_MS = 3500;
const DEFAULT_PROVIDER_TIMEOUT_SECONDS = 30;
const MAX_PROVIDER_TIMEOUT_SECONDS = 120;
const NATIVE_TIMEOUT_HEADROOM_MS = 5000;
const MINIMUM_TEXT_TIMEOUT_MS = 15000;
const LIVE_STATUS_MAX_AGE_MS = 2000;
const MAX_REQUEST_ID_LENGTH = 128;
const MAX_DETECT_TEXT_CHARS = 8000;
const MAX_PROOFREAD_TEXT_CHARS = 2000;
const MAX_TEXT_BYTES = 40000;
const SCRIPT_ID = "bean-inline";
const SCRIPT_FILES = [
  "src/localDetector.js",
  "src/trustPolicy.js",
  "src/issueMapping.js",
  "src/overlay.js",
  "src/contentScript.js"
];
const LOCAL_POLICY_KEYS = new Set([
  "blockedSites", "legacyAIOptOut", "enabled", "useBridge", "settingsSchemaVersion"
]);
let localPolicyRevision = 0;

function markLocalPolicyChanged() {
  localPolicyRevision += 1;
}

if (chrome.storage && chrome.storage.onChanged
    && typeof chrome.storage.onChanged.addListener === "function") {
  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName === "local"
        && changes && Object.keys(changes).some((key) => LOCAL_POLICY_KEYS.has(key))) {
      markLocalPolicyChanged();
    }
  });
}

function patternsForHosts(hosts) {
  if (!Array.isArray(hosts)) return [];
  const normalizedHosts = [...new Set(hosts.map((value) => {
    if (typeof value !== "string") return null;
    const host = requestHost(value.trim());
    if (!host || host.includes("*")) return null;
    // A corrupt or manually edited storage value must never make Chrome reject
    // the entire persistent content-script registration. URL accepts a few
    // non-DNS hostname characters which Chrome match patterns do not.
    if (host.startsWith("[") && host.endsWith("]")) {
      return /^\[[0-9a-f:.]+\]$/.test(host) ? host : null;
    }
    return host.split(".").every((label) =>
      /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) ? host : null;
  }).filter(Boolean))];
  return normalizedHosts.flatMap((host) => {
    const exact = [`http://${host}/*`, `https://${host}/*`];
    // IPv4/IPv6 addresses have no meaningful subdomain wildcard, and Chrome
    // rejects a wildcard prefix on an IPv6 literal.
    const isIPAddress = host.startsWith("[")
      || /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host);
    return isIPAddress || !host.includes(".")
      ? exact
      : [...exact, `http://*.${host}/*`, `https://*.${host}/*`];
  });
}

let registrationSyncRunning = false;
let registrationSyncPending = false;
let registrationSyncCallbacks = [];

function registrationFailure(message) {
  return {
    ok: false,
    errorCode: "registrationFailed",
    message: String(message || "Bean could not update website access.")
  };
}

function finishRegistrationCycle(result) {
  if (registrationSyncPending) {
    registrationSyncPending = false;
    runRegistrationCycle();
    return;
  }
  registrationSyncRunning = false;
  const callbacks = registrationSyncCallbacks;
  registrationSyncCallbacks = [];
  for (const callback of callbacks) {
    try { callback(result); } catch (_error) {}
  }
}

function runRegistrationCycle() {
  chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] }, () => {
    // A missing previous registration sets runtime.lastError; reading it keeps
    // Chrome from reporting an unchecked error.
    void chrome.runtime.lastError;
    chrome.storage.local.get(["blockedSites"], (settings) => {
      const storageError = chrome.runtime.lastError;
      if (storageError) {
        finishRegistrationCycle(registrationFailure(storageError.message));
        return;
      }
      chrome.scripting.registerContentScripts([{
        id: SCRIPT_ID,
        matches: ["http://*/*", "https://*/*"],
        excludeMatches: patternsForHosts(settings && settings.blockedSites),
        js: SCRIPT_FILES,
        runAt: "document_idle",
        persistAcrossSessions: true
      }], () => {
        const registrationError = chrome.runtime.lastError;
        finishRegistrationCycle(registrationError
          ? registrationFailure(registrationError.message)
          : { ok: true });
      });
    });
  });
}

// Registration is a replace operation (unregister → read policy → register).
// Serialize it so two settings surfaces cannot interleave those three steps and
// leave Chrome with a stale exclude list. Calls arriving mid-cycle coalesce into
// one final pass that reads the newest blocklist; every caller completes only
// after that final pass.
function syncRegisteredContentScript(done = () => {}) {
  registrationSyncCallbacks.push(typeof done === "function" ? done : () => {});
  if (registrationSyncRunning) {
    registrationSyncPending = true;
    return;
  }
  registrationSyncRunning = true;
  runRegistrationCycle();
}

function preservesLegacyAIOptOut(settings) {
  return !!settings && (settings.legacyAIOptOut === true
    || settings.useBridge === false
    || settings.enabled === false);
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get(
    ["blockedSites", "enabled", "useBridge", "legacyAIOptOut", "settingsSchemaVersion"],
    (settings) => {
      const readError = chrome.runtime.lastError;
      if (readError || !settings) {
        // Never mutate privacy choices from an incomplete settings read.
        syncRegisteredContentScript();
        return;
      }
      const update = {};
      const previousVersion = settings.settingsSchemaVersion || 0;
      // Preserve old explicit privacy choices without keeping the old global
      // UI switch. Local checks remain available; paid browser AI stays off
      // until the user confirms the one-time migration prompt.
      const legacyOptOut = preservesLegacyAIOptOut(settings);
      if (previousVersion < SETTINGS_SCHEMA_VERSION) {
        // Schema 6 makes the native bridge capability-driven. There is no
        // extension-side AI toggle: Bean's provider and Web Inline settings are
        // the single source of truth, while the blocklist retains user control.
        Object.assign(update, {
          blockedSites: previousVersion >= 4 ? (settings.blockedSites || []) : [],
          localFallback: true,
          settingsSchemaVersion: SETTINGS_SCHEMA_VERSION
        });
      }
      if (legacyOptOut && settings.legacyAIOptOut !== true) {
        update.legacyAIOptOut = true;
      }
      const finish = () => syncRegisteredContentScript();
      const removeLegacyControls = (done) => {
        const keys = ["enabled", "useBridge"].filter((key) =>
          Object.prototype.hasOwnProperty.call(settings, key));
        if (keys.length) {
          chrome.storage.local.remove(keys, () => {
            if (!chrome.runtime.lastError) markLocalPolicyChanged();
            done();
          });
        } else {
          done();
        }
      };
      if (Object.keys(update).length) {
        chrome.storage.local.set(update, () => {
          // Removing the only old opt-out after a failed marker write would
          // silently enable paid browser AI. Leave every legacy key intact.
          if (chrome.runtime.lastError) { finish(); return; }
          markLocalPolicyChanged();
          removeLegacyControls(finish);
        });
      } else {
        removeLegacyControls(finish);
      }
    }
  );
});

chrome.runtime.onStartup.addListener(() => syncRegisteredContentScript());

function extensionVersion() {
  try {
    const manifest = chrome.runtime.getManifest && chrome.runtime.getManifest();
    return (manifest && manifest.version) || "0.0.0";
  } catch (_error) {
    return "0.0.0";
  }
}

function versionAtLeast(candidate, minimum) {
  const parse = (value) => {
    if (typeof value !== "string" || !/^\d+(\.\d+){0,3}$/.test(value)) return null;
    return value.split(".").map((part) => Number(part));
  };
  const left = parse(candidate);
  const right = parse(minimum);
  if (!left || !right) return false;
  const count = Math.max(left.length, right.length);
  for (let index = 0; index < count; index += 1) {
    const lhs = left[index] || 0;
    const rhs = right[index] || 0;
    if (lhs !== rhs) return lhs > rhs;
  }
  return true;
}

let statusSequence = 0;
let latestLiveStatus = null;
let latestLiveStatusAt = 0;
function makeStatusRequest() {
  statusSequence += 1;
  return {
    id: `status-${Date.now().toString(36)}-${statusSequence}`,
    type: "getStatus",
    protocolVersion: BRIDGE_PROTOCOL_VERSION,
    extensionVersion: extensionVersion(),
    minimumAppVersion: MINIMUM_APP_VERSION
  };
}

function nativeTransportFailure(message, notInstalledCode) {
  const value = String(message || "").toLowerCase();
  if (value.includes("forbidden")
      || value.includes("access to the specified native messaging host is forbidden")) {
    return {
      response: {
        ok: false,
        errorCode: "nativeHostForbidden",
        message: "Bean's native host is installed but does not authorize this browser extension. Repair the browser connection in Bean Settings."
      },
      metadata: { responseReceived: false, nativeHostInstalled: true }
    };
  }
  const missing = value.includes("not found") || value.includes("not registered");
  return {
    response: {
      ok: false,
      errorCode: missing ? notInstalledCode : "bridgeDisconnected",
      message: String(message || "Bean's native host disconnected.")
    },
    metadata: { responseReceived: false, nativeHostInstalled: !missing }
  };
}

function validateNativeResponse(message, response) {
  if (typeof response !== "object" || response === null || Array.isArray(response)) {
    return {
      ok: false,
      errorCode: "bridgeMalformedResponse",
      message: "Bean returned an unreadable response."
    };
  }
  if (message && message.id && response.id !== message.id) {
    return {
      ok: false,
      errorCode: "bridgeResponseMismatch",
      message: "Bean returned a response for a different request."
    };
  }
  return response;
}

function sendNative(message, options, completion) {
  let finished = false;
  let timer = null;
  const finish = (response, metadata) => {
    if (finished) return;
    finished = true;
    if (timer !== null) clearTimeout(timer);
    completion(response, metadata);
  };
  timer = setTimeout(() => {
    finish({
      ok: false,
      errorCode: "bridgeTimeout",
      message: "Bean did not respond in time."
    }, { responseReceived: false, nativeHostInstalled: true });
  }, options.timeoutMs);
  try {
    chrome.runtime.sendNativeMessage(HOST, message, (response) => {
      const runtimeError = chrome.runtime.lastError;
      if (runtimeError || !response) {
        const runtimeMessage = (runtimeError || {}).message || "";
        const failure = nativeTransportFailure(runtimeMessage, options.notInstalledCode);
        finish(failure.response, failure.metadata);
        return;
      }
      finish(validateNativeResponse(message, response), {
        responseReceived: true,
        nativeHostInstalled: true
      });
    });
  } catch (error) {
    const failure = nativeTransportFailure(String(error), options.notInstalledCode);
    finish(failure.response, failure.metadata);
  }
}

// Text requests use a long-lived native port. The port keeps the MV3 worker and
// native process tied to one request lifecycle, lets us close late operations,
// and avoids the fixed 10-second timeout that previously encouraged duplicate
// retries while a provider call was still running.
function sendNativeText(message, timeoutMs, completion) {
  let finished = false;
  let timer = null;
  let port = null;
  const finish = (response) => {
    if (finished) return;
    finished = true;
    if (timer !== null) clearTimeout(timer);
    completion(response);
    try { if (port) port.disconnect(); } catch (_error) {}
  };

  try {
    port = chrome.runtime.connectNative(HOST);
    port.onMessage.addListener((response) => {
      finish(validateNativeResponse(message, response));
    });
    port.onDisconnect.addListener(() => {
      const runtimeError = chrome.runtime.lastError;
      if (finished) return;
      const runtimeMessage = (runtimeError || {}).message || "";
      const failure = nativeTransportFailure(runtimeMessage, "bridgeUnavailable");
      finish(failure.response);
    });
    timer = setTimeout(() => {
      finish({
        ok: false,
        errorCode: "bridgeTimeout",
        message: "Bean's AI request took longer than the configured provider timeout."
      });
    }, timeoutMs);
    port.postMessage(message);
  } catch (error) {
    const failure = nativeTransportFailure(String(error), "bridgeUnavailable");
    finish(failure.response);
  }
}

function compatibilityMessage(code) {
  switch (code) {
  case "protocolMismatch":
    return "Bean and the browser extension use different connection protocols. Update both, then try again.";
  case "extensionUpdateRequired":
    return "This Bean app needs a newer browser extension.";
  case "beanUpdateRequired":
    return "This browser extension needs a newer Bean app.";
  case "bridgeUnavailable":
    return "The Bean native host is connected but unavailable.";
  default:
    return "Bean and the browser extension are not compatible.";
  }
}

function providerTimeoutSeconds(response) {
  const candidate = Number(response && response.providerTimeoutSeconds);
  if (!Number.isFinite(candidate) || candidate < 1) return DEFAULT_PROVIDER_TIMEOUT_SECONDS;
  return Math.min(candidate, MAX_PROVIDER_TIMEOUT_SECONDS);
}

function requestTimeoutSeconds(response) {
  const candidate = Number(response && response.requestTimeoutSeconds);
  if (!Number.isFinite(candidate) || candidate < 1) return providerTimeoutSeconds(response);
  return Math.min(candidate, MAX_PROVIDER_TIMEOUT_SECONDS);
}

function textRequestTimeoutMs(status) {
  const providerMs = requestTimeoutSeconds(status) * 1000;
  return Math.max(
    MINIMUM_TEXT_TIMEOUT_MS,
    Math.min(
      (MAX_PROVIDER_TIMEOUT_SECONDS * 1000) + NATIVE_TIMEOUT_HEADROOM_MS,
      Math.ceil(providerMs) + NATIVE_TIMEOUT_HEADROOM_MS
    )
  );
}

function normalizeStatus(response, metadata, request) {
  const connection = {
    nativeHostInstalled: !!metadata.nativeHostInstalled,
    nativeHostConnected: !!metadata.responseReceived,
    extensionVersion: request.extensionVersion,
    minimumAppVersion: MINIMUM_APP_VERSION
  };
  if (!metadata.responseReceived) {
    return Object.assign({}, response, connection, {
      ok: false,
      bridgeAvailable: false,
      compatible: false,
      providerConfigured: false,
      webInlineEnabled: false,
      automaticAccountingAvailable: false
    });
  }

  const bridgeAvailable = response.bridgeAvailable === true;
  const protocolMatches = response.protocolVersion === BRIDGE_PROTOCOL_VERSION;
  const appVersionSupported = versionAtLeast(response.appVersion, MINIMUM_APP_VERSION);
  const extensionVersionSupported = typeof response.minimumExtensionVersion !== "string"
    || versionAtLeast(request.extensionVersion, response.minimumExtensionVersion);

  let compatibilityCode = response.compatibilityCode || "compatible";
  if (!bridgeAvailable) compatibilityCode = "bridgeUnavailable";
  else if (!protocolMatches) compatibilityCode = "protocolMismatch";
  else if (!appVersionSupported) compatibilityCode = "beanUpdateRequired";
  else if (!extensionVersionSupported) compatibilityCode = "extensionUpdateRequired";

  const compatible = response.ok === true
    && bridgeAvailable
    && protocolMatches
    && appVersionSupported
    && extensionVersionSupported
    && response.compatible !== false;
  if (!compatible && compatibilityCode === "compatible") {
    compatibilityCode = response.errorCode || "bridgeIncompatible";
  }

  const configuredProviderTimeout = providerTimeoutSeconds(response);
  const configuredRequestTimeout = requestTimeoutSeconds(response);

  return Object.assign({}, response, connection, {
    ok: response.ok === true,
    bridgeAvailable,
    protocolVersion: response.protocolVersion,
    compatible,
    compatibilityCode,
    providerConfigured: response.providerConfigured === true,
    webInlineEnabled: response.webInlineEnabled === true,
    automaticAccountingAvailable: response.automaticAccountingAvailable === true,
    providerTimeoutSeconds: configuredProviderTimeout,
    requestTimeoutSeconds: configuredRequestTimeout,
    requestTimeoutMs: textRequestTimeoutMs({ requestTimeoutSeconds: configuredRequestTimeout }),
    message: compatible ? response.message : (response.message || compatibilityMessage(compatibilityCode))
  });
}

function getLiveStatus(completion, allowRecent = false) {
  if (allowRecent && latestLiveStatus
      && Date.now() - latestLiveStatusAt <= LIVE_STATUS_MAX_AGE_MS) {
    completion(latestLiveStatus);
    return;
  }
  const request = makeStatusRequest();
  sendNative(request, {
    timeoutMs: STATUS_TIMEOUT_MS,
    notInstalledCode: "notInstalled"
  }, (response, metadata) => {
    const status = normalizeStatus(response, metadata, request);
    // Only a response from a live host is reusable. Transport failures always
    // get a fresh attempt, while a just-completed content-script preflight can
    // feed the immediately following text request without launching the host
    // twice.
    if (status.nativeHostConnected) {
      latestLiveStatus = status;
      latestLiveStatusAt = Date.now();
    }
    completion(status);
  });
}

function blockedByStatus(status) {
  if (!status.ok) return status;
  let errorCode = null;
  let message = null;
  if (status.bridgeAvailable !== true) {
    errorCode = "bridgeUnavailable";
    message = "The Bean native host is unavailable.";
  } else if (status.protocolVersion !== BRIDGE_PROTOCOL_VERSION || status.compatible === false) {
    errorCode = status.compatibilityCode || "bridgeIncompatible";
    message = status.message || compatibilityMessage(errorCode);
  } else if (!status.providerConfigured) {
    errorCode = "missingApiKey";
    message = "Add and verify an API key in Bean Settings.";
  } else if (!status.webInlineEnabled) {
    errorCode = "webInlineDisabled";
    message = "Allow deeper AI checks from the browser in Bean Settings → Browser.";
  } else if (!status.automaticAccountingAvailable) {
    errorCode = "usageReservationUnavailable";
    message = "Bean couldn't verify its usage safety data. Local checks still work. Open Bean → Settings → AI & Usage and choose Check Accounting Again. If the warning remains after reopening Bean, Privacy & Help → Full Reset is a data-erasing last resort; contact Support if reset fails.";
  }
  return errorCode ? Object.assign({}, status, { ok: false, errorCode, message }) : null;
}

function errorResponse(id, errorCode, message) {
  return { id: typeof id === "string" ? id : null, ok: false, errorCode, message };
}

function normalizeHost(value) {
  if (typeof value !== "string") return null;
  let host = value.trim().toLowerCase().replace(/\.$/, "");
  // A leading dot is a common way to express "this domain and its
  // subdomains". Bean already gives every blocked hostname that meaning, so
  // canonicalize exactly one dot instead of persisting a rule that neither the
  // runtime matcher nor Chrome's match-pattern parser can enforce.
  if (host.startsWith(".")) {
    host = host.slice(1);
    if (host.startsWith(".")) return null;
  }
  if (!host || host.length > 253 || /[\s/@*]/.test(host)) return null;
  if (host.startsWith("[") && host.endsWith("]")) {
    return /^\[[0-9a-f:.]+\]$/.test(host) ? host : null;
  }
  if (!host.split(".").every((label) =>
    /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) return null;
  return host;
}

function hostIsBlocked(host, blockedHost) {
  const normalized = normalizeHost(blockedHost);
  return !!normalized && (host === normalized || host.endsWith(`.${normalized}`));
}

function utf8ByteLength(value) {
  let count = 0;
  for (const character of value) {
    const code = character.codePointAt(0);
    if (code <= 0x7f) count += 1;
    else if (code <= 0x7ff) count += 2;
    else if (code <= 0xffff) count += 3;
    else count += 4;
  }
  return count;
}

function senderPage(sender) {
  if (!sender || !sender.tab || !Number.isInteger(sender.tab.id)) {
    return { error: errorResponse(null, "unauthorizedSender", "Browser AI requests must come from a Bean page field.") };
  }
  if (sender.id !== chrome.runtime.id) {
    return { error: errorResponse(null, "unauthorizedSender", "The request did not come from this Bean extension.") };
  }
  if (sender.frameId !== undefined && sender.frameId !== 0) {
    return { error: errorResponse(null, "unauthorizedSender", "Browser AI is limited to the page's main editing surface.") };
  }
  if (typeof sender.documentId !== "string" || !sender.documentId
      || sender.documentId.length > 256) {
    return { error: errorResponse(null, "unauthorizedSender", "Bean could not bind this request to the current page document.") };
  }
  const rawURL = sender.url || sender.tab.url;
  try {
    const pageURL = new URL(rawURL);
    if (pageURL.protocol !== "http:" && pageURL.protocol !== "https:") {
      return { error: errorResponse(null, "unauthorizedSender", "Bean only accepts text from ordinary web pages.") };
    }
    const host = normalizeHost(pageURL.hostname);
    if (!host) throw new Error("invalid host");
    if (sender.tab.url) {
      const tabURL = new URL(sender.tab.url);
      const tabHost = normalizeHost(tabURL.hostname);
      if ((tabURL.protocol !== "http:" && tabURL.protocol !== "https:") || tabHost !== host) {
        return { error: errorResponse(null, "senderNavigationMismatch", "The page changed before Bean could check it.") };
      }
    }
    if (sender.origin && sender.origin !== pageURL.origin) {
      return { error: errorResponse(null, "senderOriginMismatch", "The page origin changed before Bean could check it.") };
    }
    return {
      host,
      origin: pageURL.origin,
      pageURL: pageURL.href,
      tabID: sender.tab.id,
      documentID: sender.documentId
    };
  } catch (_error) {
    return { error: errorResponse(null, "unauthorizedSender", "Bean could not verify the page requesting AI help.") };
  }
}

function requestHost(value) {
  if (typeof value !== "string" || value.length > 300 || /[\s/@]/.test(value)) return null;
  try {
    const parsed = new URL(`http://${value}`);
    if (parsed.pathname !== "/" || parsed.search || parsed.hash || parsed.username || parsed.password) return null;
    return normalizeHost(parsed.hostname);
  } catch (_error) {
    return null;
  }
}

function normalizedPolicyBlocklist(value) {
  if (value === undefined) return [];
  if (!Array.isArray(value)) return null;
  const normalized = [];
  for (const candidate of value) {
    if (typeof candidate !== "string") return null;
    const host = requestHost(candidate.trim());
    if (!host || host.includes("*")) return null;
    normalized.push(host);
  }
  return [...new Set(normalized)];
}

let blocklistMutationRunning = false;
const blocklistMutationQueue = [];

function blocklistMutationError(code, message) {
  return { ok: false, errorCode: code, message };
}

function validatedMutationHosts(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 100) return null;
  const hosts = [];
  for (const candidate of value) {
    if (typeof candidate !== "string") return null;
    const host = requestHost(candidate.trim());
    if (!host || host.includes("*")) return null;
    hosts.push(host);
  }
  return [...new Set(hosts)];
}

function applyBlocklistMutation(currentSites, mutation) {
  if (mutation.operation === "add") {
    return [...new Set([...currentSites, ...mutation.hosts])].sort();
  }
  if (mutation.operation === "remove") {
    const removed = new Set(mutation.hosts);
    return currentSites.filter((site) => !removed.has(site)).sort();
  }
  if (mutation.operation === "allowHost") {
    return currentSites.filter((site) => !hostIsBlocked(mutation.host, site)).sort();
  }
  return null;
}

function finishBlocklistMutation(item, result) {
  try { item.completion(result); } catch (_error) {}
  blocklistMutationRunning = false;
  runNextBlocklistMutation();
}

function runNextBlocklistMutation() {
  if (blocklistMutationRunning || blocklistMutationQueue.length === 0) return;
  blocklistMutationRunning = true;
  const item = blocklistMutationQueue.shift();
  chrome.storage.local.get(["blockedSites"], (settings) => {
    const readError = chrome.runtime.lastError;
    const currentSites = !readError && settings
      ? normalizedPolicyBlocklist(settings.blockedSites)
      : null;
    if (!currentSites) {
      finishBlocklistMutation(item, blocklistMutationError(
        "settingsUnavailable", "Bean could not verify blocked websites."
      ));
      return;
    }
    const blockedSites = applyBlocklistMutation(currentSites, item.mutation);
    if (!blockedSites) {
      finishBlocklistMutation(item, blocklistMutationError(
        "invalidBlocklistMutation", "Bean received an invalid website choice."
      ));
      return;
    }
    chrome.storage.local.set({
      blockedSites,
      localFallback: true,
      settingsSchemaVersion: SETTINGS_SCHEMA_VERSION
    }, () => {
      const writeError = chrome.runtime.lastError;
      if (writeError) {
        finishBlocklistMutation(item, blocklistMutationError(
          "settingsUnavailable", "Bean could not save that website choice."
        ));
        return;
      }
      markLocalPolicyChanged();
      // The persisted blocklist is already authoritative for every loaded
      // content script. Registration is a performance/visibility layer; report
      // its failure separately instead of pretending the privacy write rolled
      // back when it did not.
      syncRegisteredContentScript((registration) => {
        finishBlocklistMutation(item, {
          ok: true,
          blockedSites,
          previousBlockedSites: currentSites,
          registrationUpdated: !!registration && registration.ok === true,
          registrationErrorCode: registration && registration.ok === false
            ? registration.errorCode : undefined
        });
      });
    });
  });
}

function enqueueBlocklistMutation(mutation, completion) {
  blocklistMutationQueue.push({
    mutation,
    completion: typeof completion === "function" ? completion : () => {}
  });
  runNextBlocklistMutation();
}

function validatedBlocklistMutation(message, sender) {
  const extensionOwned = extensionPageSender(sender);
  const page = extensionOwned ? null : senderPage(sender);
  if (!extensionOwned && page.error) return { error: page.error };

  const operation = message && message.operation;
  if (!extensionOwned) {
    // A page content script may only block the page it is currently bound to.
    if (operation !== "blockCurrentSite") {
      return { error: errorResponse(null, "unauthorizedSender", "A page can only block its own website.") };
    }
    return { mutation: { operation: "add", hosts: [page.host] } };
  }

  if (operation === "add" || operation === "remove") {
    const hosts = validatedMutationHosts(message.hosts);
    return hosts
      ? { mutation: { operation, hosts } }
      : { error: errorResponse(null, "invalidBlocklistMutation", "Bean received an invalid website choice.") };
  }
  if (operation === "allowHost") {
    const hosts = validatedMutationHosts([message.host]);
    return hosts
      ? { mutation: { operation, host: hosts[0] } }
      : { error: errorResponse(null, "invalidBlocklistMutation", "Bean received an invalid website choice.") };
  }
  return { error: errorResponse(null, "invalidBlocklistMutation", "Bean received an invalid website choice.") };
}

function validateAndBuildTextRequest(message, sender) {
  const page = senderPage(sender);
  const rawRequest = message && message.request;
  const candidateID = rawRequest && rawRequest.id;
  if (page.error) return { error: Object.assign({}, page.error, { id: typeof candidateID === "string" ? candidateID : null }) };
  if (!rawRequest || typeof rawRequest !== "object" || Array.isArray(rawRequest)) {
    return { error: errorResponse(null, "invalidRequest", "Bean received an invalid browser request.") };
  }
  if (rawRequest.type !== message.type
      || (message.type !== "detectIssues" && message.type !== "proofreadParagraph")) {
    return { error: errorResponse(candidateID, "invalidRequestType", "Bean received a mismatched browser request.") };
  }
  if (typeof candidateID !== "string" || candidateID.length < 1
      || candidateID.length > MAX_REQUEST_ID_LENGTH
      || !/^[A-Za-z0-9._:-]+$/.test(candidateID)) {
    return { error: errorResponse(null, "invalidRequestID", "Bean received an invalid request identifier.") };
  }
  if (typeof rawRequest.text !== "string" || !rawRequest.text.trim()) {
    return { error: errorResponse(candidateID, "emptyText", "There is no text to check.") };
  }
  const textLimit = message.type === "detectIssues" ? MAX_DETECT_TEXT_CHARS : MAX_PROOFREAD_TEXT_CHARS;
  if (rawRequest.text.length > textLimit || utf8ByteLength(rawRequest.text) > MAX_TEXT_BYTES) {
    return { error: errorResponse(candidateID, "textTooLong", "This text is too long for browser AI.") };
  }
  if (!rawRequest.source || typeof rawRequest.source !== "object" || Array.isArray(rawRequest.source)) {
    return { error: errorResponse(candidateID, "invalidSource", "Bean could not verify the source field.") };
  }
  if (rawRequest.source.surface !== undefined && rawRequest.source.surface !== "browserExtension") {
    return { error: errorResponse(candidateID, "invalidSource", "Bean could not verify the source surface.") };
  }
  if (requestHost(rawRequest.source.urlHost) !== page.host) {
    return { error: errorResponse(candidateID, "sourceHostMismatch", "The request host does not match the active page.") };
  }
  const fieldType = rawRequest.source.fieldType;
  if (!["input", "textarea", "contenteditable"].includes(fieldType)) {
    return { error: errorResponse(candidateID, "invalidFieldType", "Bean does not support AI in this field type.") };
  }

  let maxIssues = 8;
  if (message.type === "detectIssues" && rawRequest.settings !== undefined) {
    if (!rawRequest.settings || typeof rawRequest.settings !== "object" || Array.isArray(rawRequest.settings)) {
      return { error: errorResponse(candidateID, "invalidSettings", "Bean received invalid issue settings.") };
    }
    if (rawRequest.settings.maxIssues !== undefined) {
      if (!Number.isInteger(rawRequest.settings.maxIssues)
          || rawRequest.settings.maxIssues < 1 || rawRequest.settings.maxIssues > 8) {
        return { error: errorResponse(candidateID, "invalidSettings", "Issue count must be between 1 and 8.") };
      }
      maxIssues = rawRequest.settings.maxIssues;
    }
  }

  const request = {
    id: candidateID,
    type: message.type,
    text: rawRequest.text
  };
  if (message.type === "detectIssues") request.settings = { maxIssues };
  return {
    request,
    host: page.host,
    origin: page.origin,
    pageURL: page.pageURL,
    tabID: page.tabID,
    documentID: page.documentID
  };
}

function revalidateTextJobPage(job, expectedPolicyRevision, completion) {
  if (!chrome.tabs || typeof chrome.tabs.get !== "function") {
    completion(errorResponse(
      job.request.id,
      "senderNavigationMismatch",
      "Bean could not confirm that the original page is still open."
    ));
    return;
  }
  chrome.tabs.get(job.tabID, (tab) => {
    const runtimeError = chrome.runtime.lastError;
    if (runtimeError || !tab || tab.id !== job.tabID || typeof tab.url !== "string") {
      completion(errorResponse(
        job.request.id,
        "senderNavigationMismatch",
        "The page closed or changed before Bean could check it."
      ));
      return;
    }
    try {
      const currentURL = new URL(tab.url);
      const currentHost = normalizeHost(currentURL.hostname);
      const pendingNavigation = typeof tab.pendingUrl === "string" && tab.pendingUrl.length > 0;
      if ((currentURL.protocol !== "http:" && currentURL.protocol !== "https:")
          || !currentHost
          || currentHost !== job.host
          || currentURL.origin !== job.origin
          || currentURL.href !== job.pageURL
          || pendingNavigation) {
        completion(errorResponse(
          job.request.id,
          "senderNavigationMismatch",
          "The page changed before Bean could check it."
        ));
        return;
      }
      // A block/opt-out mutation can complete while tabs.get is in flight.
      // The service worker is run-to-completion from this callback onward, so
      // this synchronous revision/queue check closes that final privacy gap.
      if (localPolicyRevision !== expectedPolicyRevision
          || blocklistMutationRunning || blocklistMutationQueue.length > 0) {
        completion(errorResponse(
          job.request.id,
          "privacySettingsChanged",
          "Browser privacy settings changed before Bean could check this text."
        ));
        return;
      }
      completion(null);
    } catch (_error) {
      completion(errorResponse(
        job.request.id,
        "senderNavigationMismatch",
        "Bean could not confirm that the original page is still open."
      ));
    }
  });
}

// `tabs.get` can prove the tab URL, but not that the exact document and field
// which captured the text still exist. Target a content-free challenge to the
// original document ID and require that content script to single-use its
// in-memory request proof after rechecking the live field and fingerprint.
function revalidateTextJobDocument(job, expectedPolicyRevision, completion) {
  if (!chrome.tabs || typeof chrome.tabs.sendMessage !== "function") {
    completion(errorResponse(
      job.request.id,
      "senderDocumentMismatch",
      "Bean could not confirm that the original writing field is still available."
    ));
    return;
  }
  chrome.tabs.sendMessage(
    job.tabID,
    { type: "revalidateTextRequest", requestId: job.request.id },
    { frameId: 0, documentId: job.documentID },
    (response) => {
      const runtimeError = chrome.runtime.lastError;
      if (runtimeError || !response || response.ok !== true
          || response.requestId !== job.request.id) {
        completion(errorResponse(
          job.request.id,
          "senderDocumentMismatch",
          "The page or writing field changed before Bean could check it."
        ));
        return;
      }
      // Blocking a site while the exact-document challenge is in flight must
      // still win before any captured text crosses the native boundary.
      if (localPolicyRevision !== expectedPolicyRevision
          || blocklistMutationRunning || blocklistMutationQueue.length > 0) {
        completion(errorResponse(
          job.request.id,
          "privacySettingsChanged",
          "Browser privacy settings changed before Bean could check this text."
        ));
        return;
      }
      completion(null);
    }
  );
}

function readLocalPolicy(completion) {
  chrome.storage.local.get(
    ["blockedSites", "legacyAIOptOut", "enabled", "useBridge", "settingsSchemaVersion"],
    (settings) => {
    const runtimeError = chrome.runtime.lastError;
    if (runtimeError || !settings || typeof settings !== "object") {
      completion({ ok: false, blockedSites: [], legacyAIOptOut: true });
      return;
    }
    const blockedSites = normalizedPolicyBlocklist(settings.blockedSites);
    const policyTypesAreValid = ["legacyAIOptOut", "enabled", "useBridge"].every((key) =>
      settings[key] === undefined || typeof settings[key] === "boolean");
    if (!blockedSites || !policyTypesAreValid) {
      // Privacy controls are authorization state. If their persisted shape is
      // corrupt or from an unknown writer, local checks may continue but page
      // text must not cross the native/provider boundary.
      completion({ ok: false, blockedSites: [], legacyAIOptOut: true });
      return;
    }
    completion({
      ok: true,
      blockedSites,
      legacyAIOptOut: preservesLegacyAIOptOut(settings),
      revision: localPolicyRevision
    });
    }
  );
}

function localPolicyError(policy, host, id) {
  if (!policy.ok) {
    return errorResponse(id, "settingsUnavailable", "Bean could not verify browser privacy settings.");
  }
  if (policy.blockedSites.some((blockedHost) => hostIsBlocked(host, blockedHost))) {
    return errorResponse(id, "siteBlocked", "Bean is disabled on this website.");
  }
  if (policy.legacyAIOptOut) {
    return errorResponse(
      id,
      "browserAIConsentRequired",
      "Confirm browser AI once to keep your previous opt-out private after updating Bean."
    );
  }
  return null;
}

function sendTextAfterStatus(job, completion) {
  getLiveStatus((status) => {
    const blocked = blockedByStatus(status);
    if (blocked) {
      completion(blocked);
      return;
    }
    // Re-read immediately after the asynchronous status handshake. A user may
    // have blocked the site or retained an old AI opt-out while status was in
    // flight; in either case no text is allowed to cross the native boundary.
    readLocalPolicy((policy) => {
      const policyError = localPolicyError(policy, job.host, job.request.id);
      if (policyError) {
        completion(policyError);
        return;
      }
      // The status and privacy reads above are asynchronous. Re-resolve the
      // tab at the last possible boundary so text captured from a page that
      // navigated, closed, or began navigating is never sent onward.
      revalidateTextJobPage(job, policy.revision, (pageError) => {
        if (pageError) {
          completion(pageError);
          return;
        }
        revalidateTextJobDocument(job, policy.revision, (documentError) => {
          if (documentError) {
            completion(documentError);
            return;
          }
          const nativeRequest = Object.assign({}, job.request, {
            protocolVersion: BRIDGE_PROTOCOL_VERSION,
            extensionVersion: extensionVersion(),
            minimumAppVersion: MINIMUM_APP_VERSION
          });
          sendNativeText(nativeRequest, textRequestTimeoutMs(status), completion);
        });
      });
    });
  }, true);
}

let textRequestInFlight = false;
const activeRequestIDs = new Set();

function startTextRequest(job) {
  sendTextAfterStatus(job, (response) => {
    try { job.sendResponse(response); } catch (_error) {}
    activeRequestIDs.delete(job.request.id);
    textRequestInFlight = false;
  });
}

function enqueueTextRequest(job) {
  if (activeRequestIDs.has(job.request.id)) {
    job.sendResponse(errorResponse(job.request.id, "duplicateRequest", "This browser AI request is already running."));
    return;
  }
  if (textRequestInFlight) {
    job.sendResponse(errorResponse(
      job.request.id,
      "bridgeBusy",
      "Bean is checking another browser field. Try this field again shortly."
    ));
    return;
  }
  textRequestInFlight = true;
  activeRequestIDs.add(job.request.id);
  startTextRequest(job);
}

function extensionPageSender(sender) {
  if (!sender || sender.id !== chrome.runtime.id) return false;
  try {
    const senderURL = new URL(sender.url || "");
    if (senderURL.protocol !== "chrome-extension:" || senderURL.hostname !== chrome.runtime.id) {
      return false;
    }
    // Chrome includes sender.tab when Options is displayed in a normal browser
    // tab. That does not make it a page content script: sender.url remains the
    // authenticated chrome-extension:// URL. If a tab URL is present, verify it
    // belongs to this same extension as an additional consistency check.
    if (sender.tab && sender.tab.url) {
      const tabURL = new URL(sender.tab.url);
      if (tabURL.protocol !== "chrome-extension:" || tabURL.hostname !== chrome.runtime.id) {
        return false;
      }
    }
    return true;
  } catch (_error) {
    return false;
  }
}

function statusWithLocalPolicy(status, completion) {
  readLocalPolicy((policy) => {
    completion(Object.assign({}, status, {
      browserAIConsentRequired: !policy.ok || policy.legacyAIOptOut,
      browserAIEnabled: policy.ok && !policy.legacyAIOptOut,
      browserAIStatusCode: !policy.ok
        ? "settingsUnavailable"
        : (policy.legacyAIOptOut ? "browserAIConsentRequired" : "ready")
    }));
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === "mutateBlockedSites") {
    const validated = validatedBlocklistMutation(message, sender);
    if (validated.error) {
      sendResponse(validated.error);
      return true;
    }
    enqueueBlocklistMutation(validated.mutation, sendResponse);
    return true;
  }
  if (message && message.type === "refreshRegistration") {
    // Options/popup pages and a verified top-frame content script may request
    // this after changing the blocklist. It carries no text or preferences.
    if (!extensionPageSender(sender) && senderPage(sender).error) {
      sendResponse(errorResponse(null, "unauthorizedSender", "Only Bean Settings can refresh browser access."));
      return true;
    }
    syncRegisteredContentScript((result) => sendResponse(result));
    return true;
  }
  if (message && message.type === "confirmBrowserAI") {
    if (!extensionPageSender(sender)) {
      sendResponse(errorResponse(null, "unauthorizedSender", "Only Bean's browser controls can confirm browser AI."));
      return true;
    }
    chrome.storage.local.remove(["legacyAIOptOut", "enabled", "useBridge"], () => {
      const runtimeError = chrome.runtime.lastError;
      if (!runtimeError) markLocalPolicyChanged();
      sendResponse(runtimeError
        ? errorResponse(null, "settingsUnavailable", "Bean could not save browser AI confirmation.")
        : { ok: true, browserAIConsentRequired: false, browserAIEnabled: true });
    });
    return true;
  }
  if (message && message.type === "getStatus") {
    getLiveStatus((status) => statusWithLocalPolicy(status, sendResponse));
    return true;
  }
  if (message && (message.type === "detectIssues" || message.type === "proofreadParagraph")) {
    const validated = validateAndBuildTextRequest(message, sender);
    if (validated.error) {
      sendResponse(validated.error);
      return true;
    }
    readLocalPolicy((policy) => {
      const policyError = localPolicyError(policy, validated.host, validated.request.id);
      if (policyError) {
        sendResponse(policyError);
        return;
      }
      enqueueTextRequest({
        request: validated.request,
        host: validated.host,
        origin: validated.origin,
        pageURL: validated.pageURL,
        tabID: validated.tabID,
        documentID: validated.documentID,
        sendResponse
      });
    });
    return true;
  }
  return false;
});
