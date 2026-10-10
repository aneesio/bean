// Bean extension service worker. Registers the content script on ordinary web
// pages except sites the user blocks, and forwards optional provider requests
// to the local Bean native-messaging host. It never stores request text.
if (typeof importScripts === "function") importScripts("src/sitePolicy.js");
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
const SUPPRESSION_SCRIPT_ID = "bean-disabled-site-ownership";
const SCRIPT_FILES = [
  "src/sitePolicy.js",
  "src/localDetector.js",
  "src/trustPolicy.js",
  "src/issueMapping.js",
  "src/overlay.js",
  "src/contentScript.js"
];
const LOCAL_POLICY_KEYS = new Set([
  "pausedSites", "blockedSites", "legacyAIOptOut", "enabled", "useBridge", "settingsSchemaVersion"
]);
let localPolicyRevision = 0;
const assistanceMetrics = [];
const METRIC_KINDS = ["browserAnalysis","typingPauseToFeedback","browserAcceptance"];
const METRIC_OUTCOMES = ["complete","basic","applied","partial","refused"];
function recordAssistanceMetric(message,sender,completion) {
  const sample = message.sample, page = senderPage(sender);
  const allowedKeys = ["kind","inputLength","issueCount","elapsedMilliseconds","outcome"];
  const valid = !page.error && sample && typeof sample === "object" && !Array.isArray(sample) &&
    Object.keys(sample).length === allowedKeys.length && Object.keys(sample).every((key) => allowedKeys.includes(key)) &&
    METRIC_KINDS.includes(sample.kind) && METRIC_OUTCOMES.includes(sample.outcome) &&
    Number.isInteger(sample.inputLength) && sample.inputLength >= 0 && sample.inputLength <= 50000 &&
    Number.isInteger(sample.issueCount) && sample.issueCount >= 0 && sample.issueCount <= 64 &&
    Number.isInteger(sample.elapsedMilliseconds) && sample.elapsedMilliseconds >= 0 && sample.elapsedMilliseconds <= 180000;
  if (!valid) { completion({ok:false,errorCode:"invalidMetric"}); return; }
  assistanceMetrics.push(Object.fromEntries(allowedKeys.map((key) => [key,sample[key]])));
  if (assistanceMetrics.length > 500) assistanceMetrics.shift();
  completion({ok:true});
}
function assistanceMetricSummary() {
  return {sampleCount:assistanceMetrics.length,capacity:500,persisted:false,
    measurements:METRIC_KINDS.map((kind) => {
      const values=assistanceMetrics.filter((sample) => sample.kind === kind);
      const durations=values.map((sample) => sample.elapsedMilliseconds).sort((a,b) => a-b);
      const percentile=(fraction) => durations.length ? durations[Math.max(0,Math.ceil(durations.length * fraction)-1)] : null;
      return {kind,count:values.length,p50Milliseconds:percentile(0.5),p95Milliseconds:percentile(0.95),
        outcomes:Object.fromEntries(METRIC_OUTCOMES.map((outcome) => [outcome,values.filter((sample) => sample.outcome === outcome).length]))};
    })};
}

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
  chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID,SUPPRESSION_SCRIPT_ID] }, () => {
    // A missing previous registration sets runtime.lastError; reading it keeps
    // Chrome from reporting an unchecked error.
    void chrome.runtime.lastError;
    chrome.storage.local.get(["blockedSites"], (settings) => {
      const storageError = chrome.runtime.lastError;
      if (storageError) {
        finishRegistrationCycle(registrationFailure(storageError.message));
        return;
      }
      const blockedPatterns = patternsForHosts(settings && settings.blockedSites);
      const scripts = [{
        id: SCRIPT_ID,
        matches: ["http://*/*", "https://*/*"],
        excludeMatches: blockedPatterns,
        js: SCRIPT_FILES,
        runAt: "document_idle",
        persistAcrossSessions: true
      }];
      // Disabled websites load only a semantic focus guard. It captures no
      // writing and prevents the native Chrome layer from bypassing opt-out.
      if (blockedPatterns.length) scripts.push({
        id:SUPPRESSION_SCRIPT_ID,matches:blockedPatterns,
        js:["src/sitePolicy.js","src/ownershipGuard.js"],
        runAt:"document_idle",persistAcrossSessions:true
      });
      chrome.scripting.registerContentScripts(scripts, () => {
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

// Dynamic registration applies to future documents. An extension update also
// refreshes already-open pages in place, preserving their drafts and selection.
// A probe binds the later file injection to one document, so navigation cannot
// transfer an old page's policy decision to its replacement.
function refreshExistingDocuments() {
  if (!chrome.tabs || typeof chrome.tabs.query !== "function" ||
      !chrome.scripting || typeof chrome.scripting.executeScript !== "function") return;
  chrome.tabs.query({url:["http://*/*","https://*/*"]}, (tabs) => {
    if (chrome.runtime.lastError || !Array.isArray(tabs)) return;
    for (const tab of tabs) {
      if (!Number.isInteger(tab.id) || tab.discarded || tab.status !== "complete") continue;
      chrome.scripting.executeScript({target:{tabId:tab.id,frameIds:[0]},func:prepareExistingDocument}, (results) => {
        if (chrome.runtime.lastError || !Array.isArray(results)) return;
        const frame = results.find((result) => result.frameId === 0);
        const host = frame && frame.result && normalizeHost(frame.result.host);
        if (!host || typeof frame.documentId !== "string" || !frame.documentId) return;
        readLocalPolicy((policy) => {
          if (!policy.ok || policy.revision !== localPolicyRevision ||
              blocklistMutationRunning || blocklistMutationQueue.length ||
              sitePauseMutationRunning || sitePauseMutationQueue.length) return;
          const blocked = policy.blockedSites.some((blockedHost) => hostIsBlocked(host,blockedHost));
          // Paused sites use the normal script's content-free pause handling;
          // blocked sites receive only the no-writing native suppression guard.
          const files = blocked ? ["src/sitePolicy.js","src/ownershipGuard.js"] : SCRIPT_FILES;
          chrome.scripting.executeScript({target:{tabId:tab.id,documentIds:[frame.documentId]},files}, () => {
            // A closing/navigating tab or revoked host grant is a harmless skip.
            void chrome.runtime.lastError;
          });
        });
      });
    }
  });
}

function prepareExistingDocument() {
  if (!/^https?:$/.test(location.protocol) || window.top !== window ||
      window.__beanInlineContentScriptLoaded || window.__beanOwnershipGuardLoaded) return null;
  // The local QA page intentionally owns its mock overlay in the main world.
  if (["localhost","127.0.0.1","[::1]"].includes(location.hostname) &&
      /\/test\/fixtures\/editor\.html$/.test(location.pathname) &&
      document.documentElement?.dataset.beanQaMode === "mock") return null;
  // Old invalidated worlds cannot receive a shutdown message. Retire only
  // their marked presentation nodes; no editor text/focus/selection is touched.
  for (const node of document.querySelectorAll(
    "#bean-inline-host[data-bean-overlay][data-bean='overlay'],[data-bean-keyboard-bridge][data-bean='overlay']"
  )) node.remove();
  return {host:location.hostname};
}

chrome.runtime.onInstalled.addListener(() => {
  const refreshAfterRegistration = () => syncRegisteredContentScript((result) => {
    if (result.ok) refreshExistingDocuments();
  });
  chrome.storage.local.get(
    ["blockedSites", "enabled", "useBridge", "legacyAIOptOut", "settingsSchemaVersion"],
    (settings) => {
      const readError = chrome.runtime.lastError;
      if (readError || !settings) {
        // Never mutate privacy choices from an incomplete settings read.
        refreshAfterRegistration();
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
      const finish = refreshAfterRegistration;
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

function blockedByLocalStatus(status) {
  if (!status || !status.ok || !status.bridgeAvailable || !status.compatible
      || status.protocolVersion !== BRIDGE_PROTOCOL_VERSION) {
    return Object.assign({},status,{ok:false,errorCode:status && (status.errorCode || status.compatibilityCode) || "bridgeUnavailable",
      message:status && status.message || "Open Bean to connect local spelling checks."});
  }
  return status.localCheckAvailable === true ? null
    : errorResponse(null, "localCheckerUnavailable", "Update Bean to connect local spelling checks.");
}

function blockedByExplicitStatus(status) {
  if (!status || !status.ok || !status.bridgeAvailable || !status.compatible
      || status.protocolVersion !== BRIDGE_PROTOCOL_VERSION) {
    return Object.assign({},status,{ok:false,errorCode:status && (status.errorCode || status.compatibilityCode) || "bridgeUnavailable",
      message:status && status.message || "Open Bean to connect writing actions."});
  }
  if (status.performActionAvailable !== true) {
    return errorResponse(null, "actionUnavailable", "Update Bean to use writing actions here.");
  }
  return status.providerConfigured ? null
    : errorResponse(null, "missingApiKey", "Add and verify an API key in Bean Settings to use AI writing actions.");
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

let sitePauseMutationRunning = false;
const sitePauseMutationQueue = [];
function runNextSitePauseMutation() {
  if (sitePauseMutationRunning || !sitePauseMutationQueue.length) return;
  sitePauseMutationRunning = true;
  const item = sitePauseMutationQueue.shift();
  const finish = (result) => {
    try { item.completion(result); } catch (_error) {}
    sitePauseMutationRunning = false;
    runNextSitePauseMutation();
  };
  chrome.storage.local.get(["pausedSites"], (settings) => {
    const readError = chrome.runtime.lastError;
    const pausedSites = !readError && settings
      ? BeanSitePolicy.mutate(settings.pausedSites, item.host, item.operation) : null;
    if (!pausedSites) { finish(errorResponse(null,"settingsUnavailable","Bean could not verify website pauses.")); return; }
    chrome.storage.local.set({pausedSites}, () => {
      const writeError = chrome.runtime.lastError;
      if (writeError) { finish(errorResponse(null,"settingsUnavailable","Bean could not save this website pause.")); return; }
      markLocalPolicyChanged();
      finish({ok:true,pausedSites});
    });
  });
}

function mutateSitePause(message, sender, completion) {
  const extensionOwned = extensionPageSender(sender), page = extensionOwned ? null : senderPage(sender);
  const operation = message.operation;
  const host = extensionOwned ? BeanSitePolicy.host(message.host) : page && page.host;
  if ((!extensionOwned && (page.error || message.host !== undefined && BeanSitePolicy.host(message.host) !== host)) || !host || !["pause","resume"].includes(operation)) {
    completion(errorResponse(null,"unauthorizedSender","Only Bean controls can pause this website.")); return;
  }
  sitePauseMutationQueue.push({host,operation,completion});
  runNextSitePauseMutation();
}

const cancelledActions = new Map(), activeTextJobs = new Map();
function actionKey(job) { return `${job.tabID}:${job.documentID}:${job.request.id}`; }
function actionWasCancelled(job) {
  for (const [key, expiry] of cancelledActions) if (expiry <= Date.now()) cancelledActions.delete(key);
  return cancelledActions.has(actionKey(job));
}
function cancellationError(job) {
  return errorResponse(job.request.id,"cancelled","Cancelled. Bean will not apply this writing action.");
}
function cancelWritingAction(message, sender, completion) {
  const page = senderPage(sender), id = message.requestId;
  if (page.error || typeof id !== "string" || !/^[A-Za-z0-9._:-]{1,128}$/.test(id)) {
    completion(errorResponse(null,"unauthorizedSender","Bean could not verify this cancellation.")); return;
  }
  const active = activeTextJobs.get(id);
  if (active && (active.tabID !== page.tabID || active.documentID !== page.documentID || active.request.type !== "performAction")) {
    completion(errorResponse(id,"unauthorizedSender","Cancel the writing action in its original field.")); return;
  }
  const key = actionKey({tabID:page.tabID,documentID:page.documentID,request:{id}});
  cancelledActions.set(key,Date.now() + 180000);
  while (cancelledActions.size > 128) cancelledActions.delete(cancelledActions.keys().next().value);
  completion({ok:true,requestId:id,cancelled:true});
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
      || !["detectIssues", "proofreadParagraph", "localCheck", "performAction", "learnDictionaryTerm"].includes(message.type)) {
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
  const textLimit = message.type === "learnDictionaryTerm" ? 96 : ["detectIssues", "localCheck", "performAction"].includes(message.type) ? MAX_DETECT_TEXT_CHARS : MAX_PROOFREAD_TEXT_CHARS;
  if (rawRequest.text.length > textLimit || utf8ByteLength(rawRequest.text) > MAX_TEXT_BYTES) {
    return { error: errorResponse(candidateID, "textTooLong", "This text is too long for browser AI.") };
  }
  if (message.type === "learnDictionaryTerm" && !/^\p{L}[\p{L}\p{M}]*(?:['’\-]\p{L}[\p{L}\p{M}]*)*$/u.test(rawRequest.text)) {
    return {error:errorResponse(candidateID,"invalidDictionaryTerm","Choose one word to add to your dictionary.")};
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
  if (["detectIssues", "localCheck"].includes(message.type) && rawRequest.settings !== undefined) {
    if (!rawRequest.settings || typeof rawRequest.settings !== "object" || Array.isArray(rawRequest.settings)) {
      return { error: errorResponse(candidateID, "invalidSettings", "Bean received invalid issue settings.") };
    }
    if (rawRequest.settings.maxIssues !== undefined) {
      const limit = message.type === "localCheck" ? 32 : 8;
      if (!Number.isInteger(rawRequest.settings.maxIssues)
          || rawRequest.settings.maxIssues < 1 || rawRequest.settings.maxIssues > limit) {
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
  if (["detectIssues", "localCheck"].includes(message.type)) request.settings = { maxIssues };
  if (message.type === "performAction") {
    if (!["proofread", "makeCasual", "makeProfessional", "makeConcise", "makeClearer"].includes(rawRequest.action)) {
      return { error:errorResponse(candidateID, "invalidAction", "Choose a supported writing action.") };
    }
    request.action = rawRequest.action;
  }
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
          || blocklistMutationRunning || blocklistMutationQueue.length > 0 || sitePauseMutationRunning || sitePauseMutationQueue.length > 0) {
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
    { type: "revalidateTextRequest", requestId: job.request.id, purpose:job.request.type },
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
          || blocklistMutationRunning || blocklistMutationQueue.length > 0 || sitePauseMutationRunning || sitePauseMutationQueue.length > 0) {
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
    ["pausedSites", "blockedSites", "legacyAIOptOut", "enabled", "useBridge", "settingsSchemaVersion"],
    (settings) => {
    const runtimeError = chrome.runtime.lastError;
    if (runtimeError || !settings || typeof settings !== "object") {
      completion({ ok: false, blockedSites: [], legacyAIOptOut: true });
      return;
    }
    const blockedSites = normalizedPolicyBlocklist(settings.blockedSites);
    const pausedSites = BeanSitePolicy.normalize(settings.pausedSites);
    const policyTypesAreValid = ["legacyAIOptOut", "enabled", "useBridge"].every((key) =>
      settings[key] === undefined || typeof settings[key] === "boolean");
    if (!blockedSites || !pausedSites || !policyTypesAreValid) {
      // Privacy controls are authorization state. If their persisted shape is
      // corrupt or from an unknown writer, local checks may continue but page
      // text must not cross the native/provider boundary.
      completion({ ok: false, blockedSites: [], legacyAIOptOut: true });
      return;
    }
    completion({
      ok: true,
      blockedSites,
      pausedSites,
      legacyAIOptOut: preservesLegacyAIOptOut(settings),
      revision: localPolicyRevision
    });
    }
  );
}

function localPolicyError(policy, host, id, automaticAI = true) {
  if (!policy.ok) {
    return errorResponse(id, "settingsUnavailable", "Bean could not verify browser privacy settings.");
  }
  if (policy.blockedSites.some((blockedHost) => hostIsBlocked(host, blockedHost))) {
    return errorResponse(id, "siteBlocked", "Bean is disabled on this website.");
  }
  if (BeanSitePolicy.until(policy.pausedSites, host)) return errorResponse(id,"sitePaused","Bean is paused on this website for one hour.");
  if (automaticAI && policy.legacyAIOptOut) {
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
    if (actionWasCancelled(job)) { completion(cancellationError(job)); return; }
    const offline = ["localCheck", "learnDictionaryTerm"].includes(job.request.type);
    const explicit = job.request.type === "performAction";
    const blocked = job.request.type === "learnDictionaryTerm"
      ? (status && status.ok === true && status.compatible === true && status.learnWordAvailable === true ? null
        : errorResponse(job.request.id,"dictionaryUnavailable","Open Bean to save words to your dictionary."))
      : offline ? blockedByLocalStatus(status)
      : explicit ? blockedByExplicitStatus(status) : blockedByStatus(status);
    if (blocked) {
      completion(blocked);
      return;
    }
    // Re-read immediately after the asynchronous status handshake. A user may
    // have blocked the site or retained an old AI opt-out while status was in
    // flight; in either case no text is allowed to cross the native boundary.
    readLocalPolicy((policy) => {
      if (actionWasCancelled(job)) { completion(cancellationError(job)); return; }
      const policyError = localPolicyError(policy, job.host, job.request.id, !offline && !explicit);
      if (policyError) {
        completion(policyError);
        return;
      }
      // The status and privacy reads above are asynchronous. Re-resolve the
      // tab at the last possible boundary so text captured from a page that
      // navigated, closed, or began navigating is never sent onward.
      revalidateTextJobPage(job, policy.revision, (pageError) => {
        if (actionWasCancelled(job)) { completion(cancellationError(job)); return; }
        if (pageError) {
          completion(pageError);
          return;
        }
        revalidateTextJobDocument(job, policy.revision, (documentError) => {
          if (actionWasCancelled(job)) { completion(cancellationError(job)); return; }
          if (documentError) {
            completion(documentError);
            return;
          }
          const nativeRequest = Object.assign({}, job.request, {
            protocolVersion: BRIDGE_PROTOCOL_VERSION,
            extensionVersion: extensionVersion(),
            minimumAppVersion: MINIMUM_APP_VERSION
          });
          sendNativeText(nativeRequest, offline ? 8000 : textRequestTimeoutMs(status), completion);
        });
      });
    });
  }, true);
}

let textRequestInFlight = false;
let localRequestInFlight = false;
const activeRequestIDs = new Set();

function startTextRequest(job) {
  sendTextAfterStatus(job, (response) => {
    // A pause or cancel arriving during provider work suppresses late output.
    // The slot remains occupied until the actual work ends; Cancel cannot
    // promise a provider refund or create a second overlapping paid attempt.
    const finish = (result) => {
      try { job.sendResponse(result); } catch (_error) {}
      activeRequestIDs.delete(job.request.id);
      activeTextJobs.delete(job.request.id);
      if (["localCheck", "learnDictionaryTerm"].includes(job.request.type)) localRequestInFlight = false;
      else textRequestInFlight = false;
    };
    if (!response || response.ok !== true) {
      finish(actionWasCancelled(job) ? cancellationError(job) : response); return;
    }
    readLocalPolicy((policy) => finish(actionWasCancelled(job) ? cancellationError(job)
      : localPolicyError(policy,job.host,job.request.id,false) || response));
  });
}

function enqueueTextRequest(job) {
  if (actionWasCancelled(job)) { job.sendResponse(cancellationError(job)); return; }
  if (activeRequestIDs.has(job.request.id)) {
    job.sendResponse(errorResponse(job.request.id, "duplicateRequest", "This browser AI request is already running."));
    return;
  }
  const offline = ["localCheck", "learnDictionaryTerm"].includes(job.request.type);
  if (offline ? localRequestInFlight : textRequestInFlight) {
    job.sendResponse(errorResponse(
      job.request.id,
      "bridgeBusy",
      "Bean is checking another browser field. Try this field again shortly."
    ));
    return;
  }
  if (offline) localRequestInFlight = true;
  else textRequestInFlight = true;
  activeRequestIDs.add(job.request.id);
  activeTextJobs.set(job.request.id,job);
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

let ownershipTimestamp = 0;
let ownershipSequence = 0;
const latestOwnershipByTab = new Map();

function forwardFieldOwnership(message, sender, completion) {
  // Timestamp before asynchronous policy/tab/window checks. A slow old focus
  // claim must never replace a newer field or its release.
  ownershipTimestamp = Math.max(Date.now(), ownershipTimestamp + 1);
  const observedAtMilliseconds = ownershipTimestamp;
  const ownership = message.ownership;
  if (!ownership || typeof ownership.active !== "boolean" ||
      typeof ownership.fieldToken !== "string" ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(ownership.fieldToken)) {
    completion(errorResponse(null,"invalidOwnership","Bean could not verify this writing field."));
    return;
  }
  let page;
  if (ownership.active) {
    page = senderPage(sender);
    if (page.error) { completion(page.error); return; }
  } else {
    // A departing document can release its own token after its tab navigates.
    // Its identity was recorded at promotion; a URL is never needed to revoke.
    const identity = sender && sender.tab && latestOwnershipByTab.get(sender.tab.id);
    if (!sender || sender.id !== chrome.runtime.id || (sender.frameId !== undefined && sender.frameId !== 0) ||
        !identity || identity.token !== ownership.fieldToken || identity.documentID !== sender.documentId) {
      completion({ok:false,ownershipAccepted:false}); return;
    }
    page = {tabID:sender.tab.id,documentID:sender.documentId};
  }
  const identity = {token:ownership.fieldToken,documentID:page.documentID,active:ownership.active,time:observedAtMilliseconds};
  latestOwnershipByTab.set(page.tabID,identity);
  if (latestOwnershipByTab.size > 128) latestOwnershipByTab.delete(latestOwnershipByTab.keys().next().value);
  const current = () => latestOwnershipByTab.get(page.tabID) === identity;
  const reject = () => completion({ ok:false, ownershipAccepted:false });
  const send = () => {
    if (!current()) { reject(); return; }
    ownershipSequence++;
    sendNative({ id:`field-${observedAtMilliseconds}-${ownershipSequence}`,
      type:"fieldOwnership", protocolVersion:BRIDGE_PROTOCOL_VERSION,
      extensionVersion:extensionVersion(), minimumAppVersion:MINIMUM_APP_VERSION,
      ownership:{ fieldToken:ownership.fieldToken, active:ownership.active, observedAtMilliseconds }
    }, { timeoutMs:STATUS_TIMEOUT_MS, notInstalledCode:"notInstalled" }, (response) => completion(response));
  };
  // Releases cannot promote any field and must still reach the host after blur
  // or a tab switch. Native token checks ensure they only revoke their own lease.
  if (!ownership.active) { send(); return; }
  readLocalPolicy((policy) => {
    const policyError = localPolicyError(policy,page.host,null,false);
    // A paused website still suppresses native Chrome assistance. This lease
    // carries no text and is challenged against its focused eligible field;
    // every text-bearing request remains blocked by the pause.
    if (!current() || policyError && !["sitePaused","siteBlocked"].includes(policyError.errorCode)) { reject(); return; }
    const job = { ...page, request:{id:ownership.fieldToken} };
    revalidateTextJobPage(job, policy.revision, (error) => {
      if (error || !current()) { reject(); return; }
      chrome.tabs.get(page.tabID, (tab) => {
        if (chrome.runtime.lastError || !current() || !tab || tab.active !== true ||
            !Number.isInteger(tab.windowId) || !chrome.windows || typeof chrome.windows.get !== "function") {
          reject(); return;
        }
        chrome.windows.get(tab.windowId, (window) => {
          if (chrome.runtime.lastError || !current() || !window || window.focused !== true) { reject(); return; }
          chrome.tabs.sendMessage(page.tabID,
            {type:"revalidateFieldOwnership",fieldToken:ownership.fieldToken},
            {frameId:0,documentId:page.documentID}, (response) => {
              if (chrome.runtime.lastError || !current() || !response || response.ok !== true ||
                  response.fieldToken !== ownership.fieldToken || localPolicyRevision !== policy.revision ||
                  blocklistMutationRunning || blocklistMutationQueue.length || sitePauseMutationRunning || sitePauseMutationQueue.length) { reject(); return; }
              send();
            });
        });
      });
    });
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === "recordAssistanceMetric") {
    recordAssistanceMetric(message,sender,sendResponse);return true;
  }
  if (message && message.type === "getAssistanceMetrics") {
    sendResponse(extensionPageSender(sender) ? {ok:true,metrics:assistanceMetricSummary()}
      : {ok:false,errorCode:"unauthorizedSender"});return true;
  }
  if (message && message.type === "cancelWritingAction") {
    cancelWritingAction(message,sender,sendResponse); return true;
  }
  if (message && message.type === "mutateSitePause") {
    mutateSitePause(message,sender,sendResponse); return true;
  }
  if (message && message.type === "fieldOwnership") {
    forwardFieldOwnership(message, sender, sendResponse);
    return true;
  }
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
  if (message && ["detectIssues", "proofreadParagraph", "localCheck", "performAction", "learnDictionaryTerm"].includes(message.type)) {
    const validated = validateAndBuildTextRequest(message, sender);
    if (validated.error) {
      sendResponse(validated.error);
      return true;
    }
    readLocalPolicy((policy) => {
      const policyError = localPolicyError(policy, validated.host, validated.request.id,
        !["localCheck", "performAction", "learnDictionaryTerm"].includes(message.type));
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
