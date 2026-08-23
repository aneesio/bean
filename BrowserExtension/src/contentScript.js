// Bean content script — orchestrates inline proofreading in web text fields.
//
// On by default. Activates on ordinary web pages except sites the user blocks.
// Supports textarea, text inputs, and contenteditable. Skips password/search
// fields, code editors, and Google Docs. Applying one fix continues to the next.
//
// PRIVACY: no text is logged or stored by this script. Local checks never leave
// the page. After a real user edit, optional AI checks may send only the changed
// paragraph/block through the local Bean app—not the whole field.
(function () {
  const DEBOUNCE_MS = 1200;
  const BRIDGE_MIN_INTERVAL_MS = 15000;
  const BRIDGE_STATUS_TIMEOUT_MS = 6500;
  const TEXT_AUTHORIZATION_TTL_MS = 10000;
  const MAX_PENDING_TEXT_AUTHORIZATIONS = 8;
  // The localhost QA fixture runs these scripts in the page world. If the real
  // extension is also installed, its isolated-world copy yields to that mock so
  // users never see two overlays during manual verification. Bind this bypass
  // to the exact local fixture: an ordinary website must not be able to disable
  // Bean merely by copying a public data attribute.
  const qaFixtureHost = ["localhost", "127.0.0.1", "[::1]"].includes(location.hostname);
  const qaFixturePath = /\/test\/fixtures\/editor\.html$/.test(location.pathname);
  if (qaFixtureHost && qaFixturePath && document.documentElement &&
      document.documentElement.dataset.beanQaMode === "mock" &&
      chrome.runtime.id !== "bean-fixture-mock") return;
  if (window.__beanInlineContentScriptLoaded) return;
  window.__beanInlineContentScriptLoaded = true;

  const state = { active: null, entries: [], selectedId: null, fingerprint: 0, shownFingerprint: 0,
                  ignored: new Set(), reqGen: 0, groups: [], selectedGroupId: null,
                  correctedFps: new Set(), fixingGroup: false,
                  disabledFields: new WeakSet(),
                  aiContext: null, aiDetectionFingerprint: 0,
                  pendingTextAuthorizations: new Map(),
                  blockedSites: [], settingsAvailable: false,
                  undoRecord: null, applyingEdit: false,
                  disabledControlTarget: null };
  let debounce = null, scrollThrottle = null, focusoutTimer = null;
  let keyboardBridgeEl = null, keyboardBridgeResumeTimer = null;
  let lastBridgeAt = 0;

  // --- Settings -------------------------------------------------------------
  function host() { return canonicalBlockedHost(location.hostname) || ""; }
  function canonicalBlockedHost(value) {
    if (typeof value !== "string") return null;
    let raw = value.trim().toLowerCase();
    if (!raw || raw.length > 300 || /[\s/@*]/.test(raw)) return null;
    // A leading dot is common blocklist notation for a domain and all of its
    // subdomains. Canonicalize exactly one; malformed double-dot values make the
    // authorization state fail closed instead of becoming an inert rule.
    if (raw.startsWith(".")) {
      raw = raw.slice(1);
      if (!raw || raw.startsWith(".")) return null;
    }
    try {
      const parsed = new URL(`http://${raw}`);
      if (parsed.pathname !== "/" || parsed.search || parsed.hash ||
          parsed.username || parsed.password) return null;
      const normalized = parsed.hostname.toLowerCase().replace(/\.$/, "");
      if (!normalized || normalized.length > 253) return null;
      if (normalized.startsWith("[") && normalized.endsWith("]")) {
        return /^\[[0-9a-f:.]+\]$/.test(normalized) ? normalized : null;
      }
      if (!normalized.split(".").every((label) =>
        /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) return null;
      return normalized;
    } catch (e) { return null; }
  }
  function hostIsBlocked(currentHost, blockedHost) {
    return currentHost === blockedHost || currentHost.endsWith("." + blockedHost);
  }
  function siteAllowed() {
    return state.settingsAvailable
      && !state.blockedSites.some((blockedHost) => hostIsBlocked(host(), blockedHost));
  }
  function loadSettings(cb) {
    chrome.storage.local.get(["blockedSites"], (s) => {
      const readError = chrome.runtime.lastError;
      const rawSites = s && s.blockedSites;
      const normalizedSites = Array.isArray(rawSites)
        ? rawSites.map(canonicalBlockedHost) : [];
      const shapeValid = rawSites === undefined || (Array.isArray(rawSites)
        && normalizedSites.every(Boolean));
      state.settingsAvailable = !readError && !!s && shapeValid;
      state.blockedSites = state.settingsAvailable && Array.isArray(rawSites)
        ? [...new Set(normalizedSites)]
        : [];
      cb && cb();
    });
  }

  function uuid() { return (Date.now().toString(36) + Math.random().toString(36).slice(2)); }

  // Reason codes only — never any text. Debug logging is off by default.
  const DEBUG = false;
  function reason(code) { if (DEBUG) console.debug("[bean]", code); }

  // Ask the Bean app (native bridge) for issue candidates. Resolves to
  // { issues: array|null, code }. `issues === null` means "use local fallback".
  // Sets a cooldown for missing-key / web-inline-disabled so we don't spam.
  let bridgeCooldownUntil = 0, bridgeCooldownCode = "bridgeFallbackLocal";

  function requestBridgeStatus() {
    return new Promise((resolve) => {
      let done = false;
      const finish = (status) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        resolve(status);
      };
      const timer = setTimeout(() => finish(null), BRIDGE_STATUS_TIMEOUT_MS);
      try {
        chrome.runtime.sendMessage({ type: "getStatus" }, (status) => {
          void chrome.runtime.lastError;
          finish(status || null);
        });
      } catch (e) { finish(null); }
    });
  }

  // Bean owns the provider deadline (30 seconds by default, configurable up to
  // 120 seconds). Keep the content channel alive beyond the background/native
  // deadline so a paid success is never discarded and presented as a retry.
  function bridgeOperationTimeout(status) {
    const seconds = Number(status && (status.requestTimeoutSeconds || status.providerTimeoutSeconds));
    const providerMilliseconds = Number.isFinite(seconds) && seconds > 0
      ? Math.min(120000, Math.max(1000, Math.ceil(seconds * 1000)))
      : 30000;
    return providerMilliseconds + 12000;
  }

  function rememberBridgeUnavailable(code, now) {
    let cooldown = 30000;
    if (code === "bridgeProviderNotConfigured") cooldown = 60000;
    else if (code === "bridgeWebInlineDisabled") cooldown = 120000;
    else if (code === "bridgeAccountingUnavailable") cooldown = 60000;
    else if (code === "bridgeProtocolIncompatible") cooldown = 300000;
    else if (code === "bridgeConsentRequired") cooldown = 300000;
    bridgeCooldownUntil = now + cooldown;
    bridgeCooldownCode = code;
  }

  async function bridgeIssues(text, fieldType, maxIssues) {
    if (!bridgeTextAuthorized(text)) return Promise.resolve({ issues: null, code: "trustedEditRequired" });
    let now = Date.now();
    if (now < bridgeCooldownUntil) return Promise.resolve({ issues: null, code: bridgeCooldownCode });
    if (now - lastBridgeAt < BRIDGE_MIN_INTERVAL_MS) return Promise.resolve({ issues: null, code: "bridgeRateLimited" });

    // PRIVACY: getStatus is content-free and must succeed with the current
    // protocol before the text-bearing request is even constructed/sent.
    const status = await requestBridgeStatus();
    const readiness = BeanTrustPolicy.bridgeReadiness(
      status,
      BeanTrustPolicy.BRIDGE_PROTOCOL_VERSION
    );
    reason(readiness.code);
    if (!readiness.ready) {
      rememberBridgeUnavailable(readiness.code, Date.now());
      return { issues: null, code: readiness.code };
    }
    // Status and user edits race. Re-prove the captured block immediately before
    // text crosses the bridge.
    if (!bridgeTextAuthorized(text)) return { issues: null, code: "trustedEditRequired" };
    now = Date.now();
    if (now - lastBridgeAt < BRIDGE_MIN_INTERVAL_MS) return { issues: null, code: "bridgeRateLimited" };
    lastBridgeAt = now;
    return new Promise((resolve) => {
      let done = false;
      let requestId = null;
      const finish = (v) => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          if (requestId !== null) revokeTextAuthorization(requestId);
          reason(v.code);
          resolve(v);
        }
      };
      const timer = setTimeout(
        () => finish({ issues: null, code: "bridgeTimeout" }),
        bridgeOperationTimeout(status)
      );
      try {
        requestId = uuid();
        if (!registerTextAuthorization(requestId, text)) {
          finish({ issues: null, code: "trustedEditRequired" });
          return;
        }
        chrome.runtime.sendMessage(
          { type: "detectIssues", request: {
              id: requestId, type: "detectIssues",
              source: { surface: "browserExtension", urlHost: host(), fieldType },
              settings: { maxIssues }, text } },
          (resp) => {
            clearTimeout(timer);
            if (!resp) { finish({ issues: null, code: "bridgeUnavailable" }); return; }
            if (resp.ok && Array.isArray(resp.issues)) {
              finish({ issues: resp.issues, code: resp.issues.length ? "bridgeProviderIssues" : "bridgeNoIssues" });
              return;
            }
            const code = resp.errorCode || "bridgeMalformedResponse";
            if (code === "missingApiKey") { bridgeCooldownUntil = now + 60000; bridgeCooldownCode = "bridgeMissingApiKey"; }
            else if (code === "providerNotVerified") { bridgeCooldownUntil = now + 60000; bridgeCooldownCode = "bridgeProviderNotConfigured"; }
            else if (code === "webInlineDisabled") { bridgeCooldownUntil = now + 120000; bridgeCooldownCode = "bridgeWebInlineDisabled"; }
            else if (code === "bridgeUnavailable" || code === "notInstalled") { bridgeCooldownUntil = now + 30000; bridgeCooldownCode = "bridgeUnavailable"; }
            finish({ issues: null, code: "bridge_" + code });
          }
        );
      } catch (e) { clearTimeout(timer); finish({ issues: null, code: "bridgeUnavailable" }); }
    });
  }
  chrome.storage.onChanged.addListener(() => loadSettings(() => {
    bridgeCooldownUntil = 0; // settings changed → re-evaluate bridge
    if (!siteAllowed()) teardown();
    else activateInitiallyFocusedField();
  }));

  // --- Field helpers --------------------------------------------------------
  function isEditable(el) {
    if (!el || el.nodeType !== Node.ELEMENT_NODE) return false;
    if (el.isContentEditable) return true;
    if (el.tagName === "TEXTAREA") return true;
    if (el.tagName === "INPUT") {
      const t = (el.type || "text").toLowerCase();
      return t === "text"; // text only; email/url/search/etc. are excluded below
    }
    return false;
  }
  function editableSurface(el) {
    if (!el || el.nodeType !== Node.ELEMENT_NODE) return null;
    if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") return isEditable(el) ? el : null;
    if (!el.isContentEditable) return null;
    let root = typeof el.closest === "function" ? el.closest("[contenteditable]") : null;
    while (root && root.getAttribute("contenteditable") === "false") {
      root = root.parentElement && root.parentElement.closest
        ? root.parentElement.closest("[contenteditable]")
        : null;
    }
    return root || el;
  }
  function fieldAttribute(el, name) {
    if (!el || typeof el.getAttribute !== "function") return "";
    try { return String(el.getAttribute(name) || "").trim().toLowerCase(); }
    catch (e) { return ""; }
  }
  function hasSensitiveAutocomplete(el) {
    const tokens = fieldAttribute(el, "autocomplete").split(/\s+/).filter(Boolean);
    return tokens.some((token) => token === "one-time-code"
      || token === "current-password"
      || token === "new-password"
      || token === "webauthn"
      || token.startsWith("cc-")
      || token.startsWith("transaction-"));
  }
  function hasNumericOnlyPattern(el) {
    const pattern = fieldAttribute(el, "pattern").replace(/\s+/g, "");
    return /^\^?(?:\\d|\[0-9\])(?:[*+?]|\{\d+(?:,\d*)?\})?\$?$/.test(pattern);
  }
  function hasSensitiveNumericSemantics(el) {
    const inputMode = fieldAttribute(el, "inputmode");
    if (inputMode === "numeric" || inputMode === "decimal" || hasNumericOnlyPattern(el)) return true;
    const description = ["name", "id", "aria-label", "aria-describedby", "placeholder"]
      .map((name) => fieldAttribute(el, name)).filter(Boolean).join(" ");
    return /(?:\botp\b|one[\s_-]*time|verification[\s_-]*(?:code|number)|security[\s_-]*code|auth(?:entication)?[\s_-]*code|pass[\s_-]*code|\bpin\b|\bcvv\b|\bcvc\b|card[\s_-]*(?:number|no\.?))/i.test(description);
  }
  function isExcluded(el) {
    // Interactive controls nested in a contenteditable region inherit
    // `isContentEditable`; they still are not typing surfaces.
    if (el.closest("button, a[href], [role='button'], [role='link'], [role='checkbox'], [role='radio'], [role='switch'], [role='tab'], [role='menuitem'], [role='option']")) return true;
    if (el.closest("[inert], [aria-disabled='true'], [aria-readonly='true']")) return true;
    if (el.closest("[role='searchbox'], [role='search']")) return true;
    // Fields that look like ordinary text controls can still carry passwords,
    // one-time codes, card details, or numeric secrets through semantic attrs.
    // Bean must stay out of them before either local inspection or AI capture.
    if (hasSensitiveAutocomplete(el) || hasSensitiveNumericSemantics(el)) return true;
    // Secure / non-prose / non-editable inputs.
    if (el.tagName === "INPUT") {
      const t = (el.type || "text").toLowerCase();
      if (["password", "search", "email", "url", "tel", "number"].includes(t)) return true;
    }
    if (el.disabled || el.readOnly) return true;
    if (el.getAttribute("contenteditable") === "false") return true;
    const editableRoot = el.closest("[contenteditable]");
    if (editableRoot && editableRoot.getAttribute("contenteditable") === "false") return true;
    // Hidden / zero-size.
    if (!el.offsetParent && el.tagName !== "BODY") return true;
    const rect = el.getBoundingClientRect();
    if (rect.width < 8 || rect.height < 8) return true;
    // Code editors and Google Docs canvas.
    if (el.closest(".CodeMirror, .monaco-editor, .ace_editor, [role='code'], pre, code")) return true;
    if (location.host === "docs.google.com" && location.pathname.startsWith("/document")) return true;
    return false;
  }
  function eligibleEditableSurface(target) {
    if (!target || target.nodeType !== Node.ELEMENT_NODE || isExcluded(target)) return null;
    const surface = editableSurface(target);
    if (!surface || isExcluded(surface) || state.disabledFields.has(surface)) return null;
    return surface;
  }
  function getText(el) {
    return el.isContentEditable ? el.innerText : el.value;
  }
  function fingerprint(s) {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = (h * 16777619) >>> 0; }
    return h;
  }

  // Nearest block-level ancestor of a contenteditable text node, bounded by the
  // editor root. Used to group issues by visual paragraph. Returns null if the
  // node sits directly in the root with no block wrapper (then it won't group).
  const BLOCK_TAGS = { P: 1, DIV: 1, LI: 1, BLOCKQUOTE: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, TD: 1, SECTION: 1, ARTICLE: 1 };
  function blockAncestor(node, root) {
    let el = node && node.nodeType === 3 ? node.parentElement : node;
    while (el && el !== root) {
      if (BLOCK_TAGS[el.tagName]) return el;
      el = el.parentElement;
    }
    return null;
  }

  function textOffsetWithin(root, node, offset) {
    if (!root || !node || (node !== root && !root.contains(node))) return null;
    try {
      const range = document.createRange();
      range.selectNodeContents(root);
      range.setEnd(node, offset);
      return range.toString().length;
    } catch (e) { return null; }
  }

  // Capture the block containing the trusted edit and retain enough information
  // to prove it has not changed before any text crosses the native bridge.
  function captureAIContext(el) {
    const fullText = getText(el);
    const fullFingerprint = fingerprint(fullText);
    if (el.isContentEditable) {
      const selection = window.getSelection && window.getSelection();
      if (!selection || !selection.anchorNode || !el.contains(selection.anchorNode)) return null;
      const block = blockAncestor(selection.anchorNode, el) || el;
      const blockText = block.innerText;
      const caret = textOffsetWithin(block, selection.anchorNode, selection.anchorOffset);
      const scope = BeanTrustPolicy.boundedChangedBlock(blockText, caret == null ? blockText.length : caret, 2000);
      if (!scope) return null;
      return {
        text: scope.text, fullFingerprint,
        stillMatches: () => document.contains(block) && block.innerText.slice(scope.start, scope.end) === scope.text
      };
    }
    const caret = typeof el.selectionStart === "number" ? el.selectionStart : fullText.length;
    const scope = BeanTrustPolicy.boundedChangedBlock(fullText, caret, 2000);
    if (!scope) return null;
    return {
      text: scope.text, fullFingerprint,
      stillMatches: () => document.contains(el) && getText(el).slice(scope.start, scope.end) === scope.text
    };
  }

  function eligibleAIContext(el, fullText) {
    const context = state.aiContext;
    if (!context) return null;
    if (context.fullFingerprint !== fingerprint(fullText) || !context.stillMatches()) return null;
    return context;
  }

  function bridgeTextAuthorized(text) {
    const el = state.active;
    // Re-check live DOM semantics at the final send boundary too. A site can
    // add password/OTP/search/card attributes while the content-free status
    // handshake is in flight; text must not leave merely because the field was
    // ordinary when the debounce began.
    if (!el || !siteAllowed() || eligibleEditableSurface(el) !== el) return false;
    const context = eligibleAIContext(el, getText(el));
    return !!context && context.text === text;
  }

  function revokeTextAuthorization(requestId) {
    const authorization = state.pendingTextAuthorizations.get(requestId);
    if (authorization && authorization.cleanupTimer != null) {
      clearTimeout(authorization.cleanupTimer);
    }
    state.pendingTextAuthorizations.delete(requestId);
  }

  function clearPendingTextAuthorizations() {
    for (const requestId of state.pendingTextAuthorizations.keys()) {
      revokeTextAuthorization(requestId);
    }
  }

  function registerTextAuthorization(requestId, text) {
    if (typeof requestId !== "string" || !requestId || !bridgeTextAuthorized(text)) return false;
    const el = state.active;
    const fullText = getText(el);
    const context = eligibleAIContext(el, fullText);
    if (!context || context.text !== text) return false;

    const now = Date.now();
    for (const [id, authorization] of state.pendingTextAuthorizations) {
      if (!authorization || authorization.expiresAt <= now) {
        revokeTextAuthorization(id);
      }
    }
    while (state.pendingTextAuthorizations.size >= MAX_PENDING_TEXT_AUTHORIZATIONS) {
      const oldest = state.pendingTextAuthorizations.keys().next().value;
      if (oldest === undefined) break;
      revokeTextAuthorization(oldest);
    }
    const authorization = {
      element: el,
      context,
      requestGeneration: state.reqGen,
      expiresAt: now + TEXT_AUTHORIZATION_TTL_MS,
      cleanupTimer: null
    };
    state.pendingTextAuthorizations.set(requestId, authorization);
    authorization.cleanupTimer = setTimeout(() => {
      if (state.pendingTextAuthorizations.get(requestId) === authorization) {
        state.pendingTextAuthorizations.delete(requestId);
      }
    }, TEXT_AUTHORIZATION_TTL_MS);
    return true;
  }

  function consumeTextAuthorization(requestId) {
    if (typeof requestId !== "string") return false;
    const authorization = state.pendingTextAuthorizations.get(requestId);
    // Every challenge is single-use, including an expired or failed one.
    revokeTextAuthorization(requestId);
    if (!authorization || authorization.expiresAt <= Date.now()) return false;
    const el = authorization.element;
    if (authorization.requestGeneration !== state.reqGen || state.active !== el ||
        !document.contains(el) || !siteAllowed() || eligibleEditableSurface(el) !== el) return false;
    const fullText = getText(el);
    const context = eligibleAIContext(el, fullText);
    return context === authorization.context && context.stillMatches();
  }

  if (chrome.runtime.onMessage && typeof chrome.runtime.onMessage.addListener === "function") {
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
      if (!message || message.type !== "revalidateTextRequest") return false;
      const requestId = typeof message.requestId === "string" ? message.requestId : null;
      const senderIsBean = !!sender && sender.id === chrome.runtime.id;
      const ok = senderIsBean && requestId !== null && consumeTextAuthorization(requestId);
      sendResponse({ ok, requestId });
      return false;
    });
  }

  // --- Lifecycle ------------------------------------------------------------
  document.addEventListener("focusin", (e) => {
    if (!siteAllowed()) return;
    if (isBeanOverlayEvent(e)) return;
    const disabledSurface = editableSurface(e.target);
    if (disabledSurface && state.disabledFields.has(disabledSurface)) {
      teardown();
      state.disabledControlTarget = disabledSurface;
      setFieldDisabledOverlay(true, disabledSurface);
      return;
    }
    const el = eligibleEditableSurface(e.target);
    if (!el) {
      teardown();
      state.disabledControlTarget = null;
      setFieldDisabledOverlay(false);
      return;
    }
    setActive(el);
  }, true);

  // Defensive: don't tear down if focus moved INTO Bean's overlay UI. (With the
  // card's mousedown-preventDefault the field shouldn't blur at all, but guard
  // anyway — relatedTarget for a shadow element is retargeted to the host.)
  function isBeanOverlayNode(node) {
    if (!node) return false;
    if (node.id === "bean-inline-host" || (node.dataset && node.dataset.bean === "overlay")) return true;
    if (typeof node.closest === "function" && node.closest("[data-bean='overlay']")) return true;
    const root = typeof node.getRootNode === "function" ? node.getRootNode() : null;
    return !!(root && root.host && root.host.id === "bean-inline-host");
  }
  document.addEventListener("focusout", (e) => {
    // This listener is document-wide. Focus moving out of a temporary Bean
    // control must not deactivate the source field or stop future suggestions.
    const origin = e.target;
    if (!state.active || (origin !== state.active &&
        !(state.active.contains && state.active.contains(origin)))) return;
    const rt = e.relatedTarget;
    if (isBeanOverlayNode(rt)) return;
    if (rt && state.active && (rt === state.active || (state.active.contains && state.active.contains(rt)))) return;
    if (focusoutTimer) clearTimeout(focusoutTimer);
    focusoutTimer = setTimeout(() => {
      focusoutTimer = null;
      if (!state.active) return;
      const focused = document.activeElement;
      if (focused === state.active ||
          (state.active.contains && state.active.contains(focused)) ||
          isBeanOverlayNode(focused)) return;
      teardown();
    }, 0);
  }, true);

  function activateInitiallyFocusedField() {
    if (!siteAllowed()) { teardown(); return; }
    const el = eligibleEditableSurface(document.activeElement);
    if (el) setActive(el);
  }

  // True when an event originates inside Bean's overlay (card or highlight),
  // using composedPath so Shadow DOM is handled correctly.
  function isBeanOverlayEvent(e) {
    const path = e.composedPath ? e.composedPath() : [];
    return path.some((n) => n && (n.id === "bean-inline-host" || (n.dataset && n.dataset.bean === "overlay")));
  }

  window.addEventListener("scroll", () => {
    if (!state.active || !state.entries.length) return;
    if (scrollThrottle) return;
    scrollThrottle = setTimeout(() => { scrollThrottle = null; recomputeRects(); }, 60);
  }, true);
  window.addEventListener("resize", () => { if (state.active) recomputeRects(); });

  function setActive(el) {
    if (state.disabledFields.has(el)) return;
    if (state.active === el) return;
    teardown();
    state.disabledControlTarget = null;
    setFieldDisabledOverlay(false);
    state.active = el;
    state.aiContext = null;
    state.aiDetectionFingerprint = 0;
    el.addEventListener("input", onInput, true);
    document.addEventListener("mousedown", onDocMouseDown, true);
    document.addEventListener("keydown", onDocKeyDown, true);
    scheduleCheck();
  }

  function withBeanEdit(operation) {
    const wasApplying = state.applyingEdit;
    state.applyingEdit = true;
    try { return operation(); }
    finally { state.applyingEdit = wasApplying; }
  }

  function fieldRect(el) {
    if (!el || typeof el.getBoundingClientRect !== "function") return null;
    const r = el.getBoundingClientRect();
    return { x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height };
  }

  function offerUndo(record) {
    state.undoRecord = record;
    if (BeanOverlay && typeof BeanOverlay.showUndo === "function") {
      try { BeanOverlay.showUndo({ scope: record.scope, label: record.label }, undoLastApply); }
      catch (e) { reason("overlayUndoUnavailable"); }
    }
    syncKeyboardBridge();
    setTimeout(() => {
      if (state.undoRecord === record) syncKeyboardBridge();
    }, 8100);
  }

  function restoreFieldFocus(el) {
    if (!el || !document.contains(el) || typeof el.focus !== "function") return;
    try { el.focus({ preventScroll: true }); } catch (e) {
      try { el.focus(); } catch (_error) {}
    }
  }

  function removeKeyboardBridge() {
    if (keyboardBridgeResumeTimer) {
      clearTimeout(keyboardBridgeResumeTimer);
      keyboardBridgeResumeTimer = null;
    }
    if (keyboardBridgeEl) keyboardBridgeEl.remove();
    keyboardBridgeEl = null;
  }

  function exitKeyboardOverlay(direction) {
    const source = state.active;
    if (!source || !document.contains(source)) { teardown(); return; }
    if (direction < 0) {
      restoreFieldFocus(source);
      return;
    }

    // Let the browser perform its own sequential-focus navigation. Temporarily
    // remove Bean's adjacent entry bridge and put focus back on the source before
    // the current (un-cancelled) Tab keydown reaches its default action. This
    // preserves native positive-tabindex, radio-group, iframe, Shadow DOM, focus
    // proxy, wraparound, and browser-chrome behavior without trying to reproduce
    // the HTML focus algorithm here.
    removeKeyboardBridge();
    restoreFieldFocus(source);
    keyboardBridgeResumeTimer = setTimeout(() => {
      keyboardBridgeResumeTimer = null;
      // If native Tab did not leave the editor, keep Bean reachable on the next
      // attempt. A successful native move synchronously changes focus/state first.
      if (state.active === source && document.activeElement === source) syncKeyboardBridge();
    }, 0);
  }

  function syncKeyboardBridge() {
    removeKeyboardBridge();
    const source = state.active;
    if (!source || !document.contains(source) ||
        !BeanOverlay || typeof BeanOverlay.focusFirstControl !== "function" ||
        typeof BeanOverlay.hasKeyboardControls !== "function" ||
        !BeanOverlay.hasKeyboardControls()) return;
    const parent = source.parentNode;
    if (!parent) return;

    const bridge = document.createElement("span");
    bridge.tabIndex = source.tabIndex > 0 ? source.tabIndex : 0;
    bridge.dataset.bean = "overlay";
    bridge.dataset.beanKeyboardBridge = "";
    bridge.setAttribute("aria-label", "Bean writing suggestions");
    bridge.style.cssText = "position:fixed!important;width:1px!important;height:1px!important;" +
      "overflow:hidden!important;clip-path:inset(50%)!important;white-space:nowrap!important;" +
      "opacity:0!important;pointer-events:none!important;";
    bridge.addEventListener("focus", () => {
      if (state.active !== source || !BeanOverlay.focusFirstControl()) {
        removeKeyboardBridge();
        restoreFieldFocus(source);
      }
    });
    parent.insertBefore(bridge, source.nextSibling);
    keyboardBridgeEl = bridge;
  }

  if (BeanOverlay && typeof BeanOverlay.setKeyboardExitHandler === "function") {
    BeanOverlay.setKeyboardExitHandler(exitKeyboardOverlay);
  }

  function undoLastApply() {
    const record = state.undoRecord;
    if (!record || typeof record.undo !== "function") return false;
    const ok = withBeanEdit(() => record.undo());
    if (!ok) {
      reason("undoStateMismatch");
      state.undoRecord = null;
      if (BeanOverlay && typeof BeanOverlay.clearUndo === "function") BeanOverlay.clearUndo();
      removeKeyboardBridge();
      if (BeanOverlay && typeof BeanOverlay.clear === "function") BeanOverlay.clear();
      if (record.anchor) BeanOverlay.flash(record.anchor, "Couldn't undo — text changed");
      return false;
    }
    if (record.correctedFingerprint != null) state.correctedFps.delete(record.correctedFingerprint);
    state.undoRecord = null;
    if (BeanOverlay && typeof BeanOverlay.clearUndo === "function") BeanOverlay.clearUndo();
    removeKeyboardBridge();
    if (BeanOverlay && typeof BeanOverlay.clear === "function") BeanOverlay.clear();
    restoreFieldFocus(state.active);
    if (record.anchor) BeanOverlay.flash(record.anchor, "Undone");
    reason("undoSucceeded:" + record.scope);
    return true;
  }

  function onInput(event) {
    // Sites can change autocomplete/role/inputmode after focus (OTP widgets do
    // this often). Re-evaluate semantics before reading or capturing any text.
    if (!state.active || eligibleEditableSurface(state.active) !== state.active) {
      reason("fieldBecameIneligible");
      teardown();
      return;
    }
    // Typing hides the overlay; invalidate in-flight requests; re-check later.
    state.reqGen++;
    clearPendingTextAuthorizations();
    // Only browser-authenticated input unlocks AI for the current edited block.
    // Bean's own synthetic input events (and page scripts) reset to local-only,
    // preventing provider loops after an Apply action.
    if (!state.applyingEdit && state.undoRecord) {
      state.undoRecord = null;
      if (BeanOverlay && typeof BeanOverlay.clearUndo === "function") BeanOverlay.clearUndo();
    }
    if (!state.applyingEdit && event && event.isTrusted && !event.isComposing && state.active) {
      state.aiContext = captureAIContext(state.active);
      state.aiDetectionFingerprint = 0;
      reason(state.aiContext ? "trustedEditCaptured" : "trustedEditScopeUnavailable");
    } else {
      state.aiContext = null;
      state.aiDetectionFingerprint = 0;
      reason("programmaticInputLocalOnly");
    }
    removeKeyboardBridge();
    BeanOverlay.clear();
    state.entries = []; state.selectedId = null; state.shownFingerprint = 0;
    state.groups = []; state.selectedGroupId = null;
    scheduleCheck();
  }
  function scheduleCheck() {
    if (debounce) clearTimeout(debounce);
    debounce = setTimeout(check, DEBOUNCE_MS);
  }
  function clearOverlay() {
    state.entries = []; state.selectedId = null; state.shownFingerprint = 0;
    state.groups = []; state.selectedGroupId = null;
    removeKeyboardBridge();
    BeanOverlay.clear();
  }
  function teardown() {
    if (focusoutTimer) { clearTimeout(focusoutTimer); focusoutTimer = null; }
    if (debounce) { clearTimeout(debounce); debounce = null; }
    if (state.active) state.active.removeEventListener("input", onInput, true);
    document.removeEventListener("mousedown", onDocMouseDown, true);
    document.removeEventListener("keydown", onDocKeyDown, true);
    state.active = null;
    state.aiContext = null;
    state.aiDetectionFingerprint = 0;
    clearPendingTextAuthorizations();
    state.undoRecord = null;
    removeKeyboardBridge();
    if (BeanOverlay && typeof BeanOverlay.clearUndo === "function") BeanOverlay.clearUndo();
    state.reqGen++;
    clearOverlay();
  }

  // Click in our overlay UI → ignore; click into the active field → close card,
  // keep highlights; click anywhere else → clear overlay.
  function onDocMouseDown(e) {
    if (!state.active) return;
    if (isBeanOverlayEvent(e)) { reason("insideBeanUIClickIgnored"); return; } // never dismiss on our own UI
    if (e.target === state.active || (state.active.contains && state.active.contains(e.target))) {
      if (state.selectedId || state.selectedGroupId) { state.selectedId = null; state.selectedGroupId = null; renderOverlay(); }
      return;
    }
    reason("clickAwayDismiss");
    clearOverlay();
  }
  function onDocKeyDown(e) {
    if (isBeanOverlayEvent(e)) return;
    if (e.key === "Tab" && !e.defaultPrevented && !e.shiftKey && !e.ctrlKey &&
        !e.metaKey && !e.altKey && !e.isComposing && state.active &&
        state.active.isContentEditable && keyboardBridgeEl &&
        (e.target === state.active ||
          (state.active.contains && state.active.contains(e.target))) &&
        BeanOverlay && typeof BeanOverlay.focusFirstControl === "function" &&
        BeanOverlay.focusFirstControl()) {
      // Scoped fallback for rich editors such as Slack that consume plain Tab
      // before the adjacent focus bridge can receive it. Native inputs and
      // textareas always keep the browser's normal Tab path through the bridge.
      e.preventDefault();
      e.stopPropagation();
      reason("keyboardOverlayEntered");
      return;
    }
    if (e.key === "Escape" && state.entries.length) {
      if (state.selectedId || state.selectedGroupId) { state.selectedId = null; state.selectedGroupId = null; renderOverlay(); }
      else clearOverlay();
    }
  }

  // --- Detect + map ---------------------------------------------------------
  function check() {
    const el = state.active;
    if (!el || !document.contains(el) || eligibleEditableSurface(el) !== el) {
      teardown(); return;
    }
    const text = getText(el);
    if (!text || text.length < 4 || text.length > 5000) { clearOverlay(); return; }
    const fp = fingerprint(text);
    if (fp === state.shownFingerprint && state.entries.length) return; // already showing for this text
    const fieldType = el.isContentEditable ? "contenteditable" : (el.tagName || "").toLowerCase();
    const gen = ++state.reqGen;
    const localIssues = BeanDetector.detect(text);
    state.fingerprint = fp;
    state.shownFingerprint = fp;
    state.entries = mapEntries(el, text, localIssues);
    state.selectedId = null;
    renderOverlay();

    // Focus alone is deliberately local-only. AI becomes eligible only after a
    // trusted edit, and receives the captured changed block instead of the field.
    const context = eligibleAIContext(el, text);
    if (!context || context.text.length < 4 || state.aiDetectionFingerprint === fp) return;
    const remainingIssueSlots = Math.max(0, 8 - state.entries.length);
    // A provider call cannot add anything when local findings already fill the
    // visible issue budget. Avoid spending tokens on a result we would discard.
    if (remainingIssueSlots === 0) { reason("bridgeSkippedLocalIssueCap"); return; }
    state.aiDetectionFingerprint = fp;
    bridgeIssues(context.text, fieldType, remainingIssueSlots).then((result) => {
      // Stale typing/refocus is harmless, but a live sensitive-state change must
      // be handled before this callback reads the field or renders anything.
      if (gen !== state.reqGen || el !== state.active) return;
      if (eligibleEditableSurface(el) !== el) {
        reason("fieldBecameIneligible");
        teardown();
        return;
      }
      if (getText(el) !== text || !context.stillMatches()) return;
      const candidates = BeanTrustPolicy.mergeIssues(localIssues, result.issues || [], 16);
      state.fingerprint = fp;
      state.shownFingerprint = fp;
      state.entries = mapEntries(el, text, candidates);
      state.selectedId = null;
      renderOverlay();
    });
  }

  function isSafeCandidate(issue) {
    if (!issue || typeof issue.original !== "string" || typeof issue.suggestion !== "string") return false;
    if (!issue.original || !issue.suggestion || issue.original === issue.suggestion) return false;
    if (issue.original.length < 2 || issue.original.length > 200) return false; // localized only
    if (issue.suggestion.length > 200) return false;
    if (issue.suggestion === issue.original + issue.original) return false; // obvious duplication artifact
    // LINE-BREAK SAFETY: provider output may not add, remove, or change CR/LF
    // boundaries inside an issue. The final mapping layer repeats this guard.
    if (!BeanMapping.hasMatchingLineBreakStructure(issue.original, issue.suggestion)) {
      reason("lineBreakRiskRefused"); return false;
    }
    return true;
  }
  function ignoreKey(original) { return original + "::" + state.fingerprint; }

  // Builds entries whose rects come from the SAME source used to apply:
  //   contenteditable → a unique DOM Range over the text nodes (rects + apply)
  //   textarea/input  → a verified value offset (rects via mirror + apply)
  function mapEntries(el, text, candidates) {
    const kind = el.isContentEditable ? "ce" : "ta";
    const entries = [];
    let i = 0;
    for (const issue of candidates) {
      if (!isSafeCandidate(issue)) continue;
      if (state.ignored.has(ignoreKey(issue.original))) continue;
      let entry = null;
      if (kind === "ce") {
        const range = BeanMapping.findUniqueRange(el, issue.original); // null if missing/ambiguous/mismatch
        if (!range) { reason("mapMissingSkipped"); continue; }
        const rects = BeanMapping.rectsFromRange(range);
        if (!rects.length) continue;
        // Paragraph = nearest block ancestor (p/div/li/blockquote/heading) inside
        // the editor; null if none (then this issue won't group).
        const block = blockAncestor(range.startContainer, el);
        const paraText = block ? block.innerText : null;
        entry = { id: "i" + i++, issue, kind, original: issue.original, rects, blockEl: block, paraText,
                  sortKey: rects[0].y * 100000 + rects[0].x };
      } else {
        const off = BeanMapping.uniqueOffset(text, issue.original);
        if (!off) { reason("mapMissingSkipped"); continue; }
        if (el.value.slice(off.start, off.end) !== issue.original) continue; // exact verify
        const rects = BeanMapping.rectsForRange(el, off.start, off.end);
        if (!rects.length) continue;
        // Paragraph = the line (run between newlines); key by line-start offset.
        const lb = text.lastIndexOf("\n", off.start - 1);
        const lineStart = lb < 0 ? 0 : lb + 1;
        const nl = text.indexOf("\n", off.start);
        const paraText = text.slice(lineStart, nl < 0 ? text.length : nl);
        entry = { id: "i" + i++, issue, kind, original: issue.original, rects, start: off.start, end: off.end,
                  lineStart, paraText, sortKey: off.start };
      }
      // Suppress issues in a paragraph Bean just fully proofread (until it changes),
      // so Bean's own correction doesn't look like an endless stream of fixes.
      if (entry.paraText != null && state.correctedFps.has(fingerprint(entry.paraText))) { reason("paragraphSuppressed"); continue; }
      reason("mapUniqueMatch");
      entries.push(entry);
      if (entries.length >= 8) break;
    }
    return entries.sort((a, b) => a.sortKey - b.sortKey);
  }

  // The single safety guard: returns a verified target whose LIVE text equals
  // issue.original, or null. applyIssue only ever acts on this.
  function verifyTarget(el, entry) {
    if (!el || !document.contains(el)) return null;
    if (entry.kind === "ce") {
      const range = BeanMapping.findUniqueRange(el, entry.original);
      if (!range || range.toString() !== entry.original) return null;
      return { kind: "ce", range };
    }
    const v = el.value;
    if (entry.end > v.length || v.slice(entry.start, entry.end) !== entry.original) return null;
    return { kind: "ta", start: entry.start, end: entry.end };
  }

  function recomputeRects() {
    const el = state.active;
    if (!el) return;
    const kept = [];
    for (const entry of state.entries) {
      if (entry.kind === "ce") {
        const range = BeanMapping.findUniqueRange(el, entry.original);
        if (!range || range.toString() !== entry.original) continue; // stale → drop
        const rects = BeanMapping.rectsFromRange(range);
        if (!rects.length) continue;
        entry.rects = rects;
      } else {
        if (el.value.slice(entry.start, entry.end) !== entry.original) continue;
        const rects = BeanMapping.rectsForRange(el, entry.start, entry.end);
        if (!rects.length) continue;
        entry.rects = rects;
      }
      kept.push(entry);
    }
    state.entries = kept;
    if (state.selectedId && !kept.some((e) => e.id === state.selectedId)) state.selectedId = null;
    renderOverlay();
  }

  function dropIssue(id) {
    const i = state.entries.findIndex((e) => e.id === id);
    if (i < 0) return;
    state.entries.splice(i, 1);
    if (!state.entries.length) {
      clearOverlay();
      restoreFieldFocus(state.active);
      return;
    }
    if (state.selectedId === id) state.selectedId = state.entries[Math.min(i, state.entries.length - 1)].id;
    renderOverlay();
  }

  // --- Render + interaction -------------------------------------------------
  function position() {
    if (!state.selectedId) return null;
    const idx = state.entries.findIndex((e) => e.id === state.selectedId);
    return idx >= 0 ? { index: idx, total: state.entries.length } : null;
  }
  // Group issues by paragraph; only paragraphs with >=2 issues AND a reliable
  // anchor get an icon. Recomputed from entries on every render (entries are
  // rebuilt on every map, so group refs never go stale).
  function buildGroups() {
    const el = state.active;
    if (!el) return [];
    const byKey = new Map();
    let gid = 0;
    for (const e of state.entries) {
      const key = e.kind === "ce" ? e.blockEl : (e.lineStart != null ? "L" + e.lineStart : null);
      if (key == null) continue; // ce issue with no block wrapper → not groupable
      let g = byKey.get(key);
      if (!g) { g = { id: "g" + (gid++), kind: e.kind, entries: [] }; byKey.set(key, g); }
      g.entries.push(e);
    }
    const groups = [];
    for (const g of byKey.values()) {
      if (g.entries.length < 2) continue; // single-issue paragraphs get no icon
      const anchor = groupAnchor(el, g);
      if (!anchor) continue;              // unreliable anchor → no icon (never fake)
      g.anchor = anchor;
      g.count = g.entries.length;
      if (g.kind === "ce") {
        g.block = g.entries[0].blockEl;
        // "Fix Paragraph" replaces the whole block's text, so it's only offered
        // when that block is literal text nodes (no links/spans/images/<br>).
        g.canFix = ceBlockReplaceable(g.block);
      } else {
        g.lineStart = g.entries[0].lineStart;
        g.canFix = true;
      }
      const paragraphText = g.entries[0].paraText || "";
      const context = eligibleAIContext(el, getText(el));
      g.fixMode = context && context.text === paragraphText ? "ai" : "local";
      // Local mode is offered only when the deterministic pass will make an
      // actual edit. AI mode remains an explicit request whose result is checked.
      if (g.fixMode === "local" && localParagraphFix(paragraphText) === paragraphText) g.canFix = false;
      groups.push(g);
    }
    return groups;
  }

  // Paragraph replacement and provider capture must use the same coordinate
  // system. Any element child—including <br>—either carries markup or creates an
  // innerText/textContent boundary mismatch, so Fix Paragraph is disabled there.
  function ceBlockReplaceable(block) {
    return !!block && document.contains(block)
      && BeanTrustPolicy.isPlainTextContentEditableBlock(block);
  }

  function groupAnchor(el, g) {
    if (g.kind === "ce") {
      const block = g.entries[0].blockEl;
      if (!block || !document.contains(block)) return null;
      const r = block.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return null;
      return { x: r.left + window.scrollX, y: r.top + window.scrollY, h: Math.min(r.height, 22) };
    }
    const fr = el.getBoundingClientRect();
    const first = g.entries[0].rects[0];
    if (!first || fr.width < 1) return null;
    return { x: fr.left + window.scrollX, y: first.y, h: first.h };
  }

  function renderOverlay() {
    BeanOverlay.render(state.entries, state.selectedId, position(), {
      onActivate: (id) => {
        // Never open a card (and offer Apply) for an unverifiable range.
        const entry = state.entries.find((e) => e.id === id);
        if (!entry) return;
        if (!verifyTarget(state.active, entry)) { reason("applyRangeMismatch"); dropIssue(id); return; }
        state.selectedId = id; state.selectedGroupId = null; renderOverlay();
      },
      onClose: () => {
        state.selectedId = null;
        renderOverlay();
        restoreFieldFocus(state.active);
      },
      onNext: () => {
        reason("buttonNextClicked");
        const idx = state.entries.findIndex((e) => e.id === state.selectedId);
        if (idx < 0 || !state.entries.length) return;
        state.selectedId = state.entries[(idx + 1) % state.entries.length].id;
        renderOverlay();
      },
      onIgnore: (id) => {
        reason("buttonIgnoreClicked");
        const entry = state.entries.find((e) => e.id === id);
        if (entry) state.ignored.add(ignoreKey(entry.issue.original));
        dropIssue(id);
      },
      onApply: (id) => applyIssue(id),
      onUndo: () => undoLastApply(),
      onEnableField: () => enableDisabledField(state.disabledControlTarget),
      onDisableField: () => disableCurrentField(),
      onDisableSite: () => disableCurrentSite()
    });

    // Paragraph-level icons + card (priority: an open group card hides the issue
    // card and vice-versa; both live in the same overlay).
    state.groups = buildGroups();
    if (state.selectedGroupId && !state.groups.some((g) => g.id === state.selectedGroupId)) state.selectedGroupId = null;
    reason("paragraphGroupCount:" + state.groups.length);
    BeanOverlay.renderGroups(state.groups, state.selectedGroupId, {
      onActivateGroup: (gid) => {
        const g = state.groups.find((x) => x.id === gid);
        if (!g) return;
        state.selectedGroupId = gid; state.selectedId = null;
        reason("paragraphFixAvailable:" + (g.canFix ? 1 : 0));
        renderOverlay();
      },
      onCloseGroup: () => {
        state.selectedGroupId = null;
        renderOverlay();
        restoreFieldFocus(state.active);
      },
      onReviewGroup: (gid) => {
        reason("paragraphReviewOneByOne");
        const g = state.groups.find((x) => x.id === gid);
        if (!g || !g.entries.length) return;
        const first = g.entries[0];
        state.selectedGroupId = null;
        if (!verifyTarget(state.active, first)) { dropIssue(first.id); return; }
        state.selectedId = first.id; renderOverlay();
      },
      onIgnoreAllGroup: (gid) => {
        reason("paragraphIgnoreAll");
        const g = state.groups.find((x) => x.id === gid);
        if (!g) return;
        const ids = g.entries.map((e) => e.id);
        for (const e of g.entries) state.ignored.add(ignoreKey(e.issue.original));
        state.selectedGroupId = null;
        state.entries = state.entries.filter((e) => !ids.includes(e.id));
        if (!state.entries.length) {
          clearOverlay();
          restoreFieldFocus(state.active);
          return;
        }
        renderOverlay();
        restoreFieldFocus(state.active);
      },
      onFixParagraph: (gid) => fixParagraph(gid),
      onUndo: () => undoLastApply(),
      onEnableField: () => enableDisabledField(state.disabledControlTarget),
      onDisableField: () => disableCurrentField(),
      onDisableSite: () => disableCurrentSite()
    });
    syncKeyboardBridge();
  }

  function setFieldDisabledOverlay(disabled, field) {
    if (BeanOverlay && typeof BeanOverlay.setFieldDisabled === "function") {
      try {
        BeanOverlay.setFieldDisabled(disabled, {
          onEnable: () => enableDisabledField(field)
        });
      } catch (e) { reason("overlayEnableUnavailable"); }
    }
  }

  function disableCurrentField() {
    const el = state.active;
    if (!el) return;
    const rect = fieldRect(el);
    state.disabledFields.add(el);
    teardown();
    state.disabledControlTarget = el;
    if (rect) BeanOverlay.flash(rect, "Bean disabled for this field");
    // New overlays expose a reversible local opt-out. Older overlays simply
    // ignore this optional hook; no page text or preference is persisted.
    setFieldDisabledOverlay(true, el);
    // Keyboard activation removes the focused More menu along with the rest of
    // the overlay. Return focus to the still-editable source instead of leaving
    // it on the document body; the persistent re-enable control remains announced.
    restoreFieldFocus(el);
  }

  function enableDisabledField(el) {
    if (!el || !state.disabledFields.has(el)) return false;
    state.disabledFields.delete(el);
    if (state.disabledControlTarget === el) {
      state.disabledControlTarget = null;
      setFieldDisabledOverlay(false);
    }
    if (!document.contains(el) || !siteAllowed()) return false;
    try {
      if (document.activeElement !== el && typeof el.focus === "function") el.focus({ preventScroll: true });
    } catch (e) {}
    const eligible = eligibleEditableSurface(el);
    if (eligible) setActive(eligible);
    const rect = fieldRect(el);
    if (rect) BeanOverlay.flash(rect, "Bean enabled for this field");
    reason("fieldReenabled");
    return !!eligible;
  }

  function disableCurrentSite() {
    const currentHost = host();
    const el = state.active;
    const rect = el ? el.getBoundingClientRect() : null;
    chrome.runtime.sendMessage({
      type: "mutateBlockedSites",
      operation: "blockCurrentSite"
    }, (result) => {
      const mutationError = chrome.runtime.lastError;
      if (mutationError || !result || !result.ok || !Array.isArray(result.blockedSites)) {
        if (rect) {
          BeanOverlay.flash({ x: rect.left + window.scrollX, y: rect.top + window.scrollY,
                              w: rect.width, h: rect.height }, "Couldn’t block this website");
        }
        reason("siteBlockSaveFailed");
        return;
      }
      state.settingsAvailable = true;
      state.blockedSites = result.blockedSites;
      teardown();
      if (rect) {
        BeanOverlay.flash({ x: rect.left + window.scrollX, y: rect.top + window.scrollY,
                            w: rect.width, h: rect.height }, `Bean disabled on ${currentHost}`);
      }
    });
  }

  // Ask the Bean app to proofread a whole paragraph. Resolves to
  // { text: string|null, code, reviewRequired, message }.
  async function bridgeProofreadParagraph(text, fieldType) {
    if (!bridgeTextAuthorized(text)) {
      return { text: null, code: "trustedEditRequired", reviewRequired: false };
    }
    const now = Date.now();
    if (now < bridgeCooldownUntil) {
      return { text: null, code: bridgeCooldownCode, reviewRequired: false };
    }
    // A fresh, content-free handshake is mandatory before every paragraph text
    // request, even if issue detection connected moments earlier.
    const status = await requestBridgeStatus();
    const readiness = BeanTrustPolicy.bridgeReadiness(
      status,
      BeanTrustPolicy.BRIDGE_PROTOCOL_VERSION
    );
    reason(readiness.code);
    if (!readiness.ready) {
      rememberBridgeUnavailable(readiness.code, Date.now());
      return { text: null, code: readiness.code, reviewRequired: false };
    }
    if (!bridgeTextAuthorized(text)) {
      return { text: null, code: "trustedEditRequired", reviewRequired: false };
    }
    return new Promise((resolve) => {
      let done = false;
      let requestId = null;
      const finish = (v) => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          if (requestId !== null) revokeTextAuthorization(requestId);
          reason(v.code);
          resolve(v);
        }
      };
      const timer = setTimeout(
        () => finish({ text: null, code: "bridgeTimeout", reviewRequired: false }),
        bridgeOperationTimeout(status)
      );
      try {
        requestId = uuid();
        if (!registerTextAuthorization(requestId, text)) {
          finish({ text: null, code: "trustedEditRequired", reviewRequired: false });
          return;
        }
        chrome.runtime.sendMessage(
          { type: "proofreadParagraph", request: {
              id: requestId, type: "proofreadParagraph",
              source: { surface: "browserExtension", urlHost: host(), fieldType }, text } },
          (resp) => {
            clearTimeout(timer);
            if (!resp) { finish({ text: null, code: "bridgeUnavailable", reviewRequired: false }); return; }
            if (resp.ok && typeof resp.text === "string") {
              finish({ text: resp.text, code: resp.reviewRequired ? "paragraphReviewRequired" : "paragraphProofreadSucceeded",
                       reviewRequired: !!resp.reviewRequired, message: resp.message || "" });
              return;
            }
            finish({ text: null, code: "bridge_" + (resp.errorCode || "malformed"), reviewRequired: false });
          }
        );
      } catch (e) { clearTimeout(timer); finish({ text: null, code: "bridgeUnavailable" }); }
    });
  }

  // Local fallback: produce a cleaned paragraph using ONLY the offline detector's
  // obvious fixes (typos/spacing). Safe + boundary-preserving on the string.
  function localParagraphFix(paragraph) {
    return BeanDetector.fixObvious(paragraph);
  }

  function valueUndoRecord(el, start, before, after, original, replacement, scope, label, anchor) {
    return {
      scope, label, anchor,
      undo: () => {
        if (!document.contains(el) || eligibleEditableSurface(el) !== el || el.value !== after ||
            el.value.slice(start, start + replacement.length) !== replacement) return false;
        if (eligibleEditableSurface(el) !== el) return false;
        const result = BeanMapping.applyTextControlRange(
          el, start, start + replacement.length, original
        );
        return result.ok && el.value === before;
      }
    };
  }

  function contentEditableUndoRecord(el, start, before, after, original, replacement, scope, label, anchor) {
    return {
      scope, label, anchor,
      undo: () => {
        if (!document.contains(el) || eligibleEditableSurface(el) !== el || el.textContent !== after) return false;
        const range = BeanMapping.rangeFromOffsets(el, start, start + replacement.length);
        if (!range || range.toString() !== replacement) return false;
        if (eligibleEditableSurface(el) !== el) return false;
        const result = BeanMapping.applyContentEditableRange(el, range, original, before);
        return result.ok && el.textContent === before;
      }
    };
  }

  // Read the live paragraph text + a verifier/replacer for this group. Returns
  // null if the paragraph boundary can't be located safely.
  function paragraphTarget(el, g) {
    if (g.kind === "ce") {
      const block = g.block;
      if (!block || !document.contains(block) || !ceBlockReplaceable(block)) return null;
      return {
        text: block.innerText,
        stillMatches: (sent) => document.contains(block) && block.innerText === sent,
        replace: (corrected) => {
          const range = document.createRange();
          range.selectNodeContents(block);     // whole block, not the editor
          const offsets = BeanMapping.rangeOffsets(el, range);
          if (!offsets) return null;
          const before = el.textContent;
          const original = before.slice(offsets.start, offsets.end);
          const after = BeanMapping.replaceRangePreservingBoundaries(
            before, offsets.start, offsets.end, corrected
          );
          if (after === null) return null;
          if (eligibleEditableSurface(el) !== el) return null;
          const result = withBeanEdit(() =>
            BeanMapping.applyContentEditableRange(el, range, corrected, after)
          );
          if (!result.ok || el.textContent !== after || block.innerText !== corrected) return null;
          return contentEditableUndoRecord(
            el, offsets.start, before, after, original, corrected,
            "block", "Undo block fix", fieldRect(el)
          );
        }
      };
    }
    const v = el.value;
    const ls = g.lineStart;
    if (ls == null || ls > v.length) return null;
    const nl = v.indexOf("\n", ls);
    const le = nl < 0 ? v.length : nl;
    return {
      text: v.slice(ls, le),
      stillMatches: (sent) => el.value.slice(ls, le) === sent,
      replace: (corrected) => {
        const cur = el.value;
        // Boundary-preserving splice: only [ls, le) changes; the trailing newline
        // and everything outside stay byte-for-byte identical.
        const next = BeanMapping.replaceRangePreservingBoundaries(cur, ls, le, corrected);
        if (next === null ||
            next.slice(0, ls) !== cur.slice(0, ls) ||
            next.slice(ls + corrected.length) !== cur.slice(le)) {
          return null;
        }
        if (eligibleEditableSurface(el) !== el) return null;
        const result = withBeanEdit(() =>
          BeanMapping.applyTextControlRange(el, ls, le, corrected)
        );
        if (!result.ok || el.value !== next) return null;
        return valueUndoRecord(
          el, ls, cur, next, cur.slice(ls, le), corrected,
          "paragraph", "Undo paragraph fix", fieldRect(el)
        );
      }
    };
  }

  function rememberCorrected(text) {
    state.correctedFps.add(fingerprint(text));
    if (state.correctedFps.size > 32) { // bound the set
      state.correctedFps = new Set(Array.from(state.correctedFps).slice(-16));
    }
  }

  // "Fix Paragraph": proofread and replace the WHOLE paragraph in one pass, so the
  // user never has to apply repeatedly. Safety: verify the paragraph boundary,
  // re-verify it hasn't changed before replacing, preserve everything outside it,
  // sanitize the model output (zero-width / wrappers), and suppress immediate
  // re-detection of the just-corrected paragraph.
  async function fixParagraph(gid) {
    if (state.fixingGroup) return;
    const el = state.active;
    const g = state.groups.find((x) => x.id === gid);
    if (!el || !g || !document.contains(el)) { teardown(); return; }
    if (!g.canFix) { reason("paragraphProofreadUnavailable"); flashAt(g, "Review one by one"); return; }

    const target = paragraphTarget(el, g);
    if (!target) { reason("paragraphReplacementRefused"); flashAt(g, "Review one by one"); return; }
    const sent = target.text;
    if (!sent || !sent.trim() || sent.length > 2000) { reason("paragraphReplacementRefused"); return; }

    state.fixingGroup = true;
    state.selectedGroupId = null;
    const context = eligibleAIContext(el, getText(el));
    const useAI = !!context && context.text === sent;
    reason(useAI ? "paragraphProofreadRequested" : "paragraphLocalFixRequested");
    removeKeyboardBridge();
    BeanOverlay.clear();
    if (BeanOverlay && typeof BeanOverlay.showParagraphBusy === "function") {
      BeanOverlay.showParagraphBusy(
        g.anchor,
        useAI ? "Proofreading changed paragraph with AI…" : "Fixing obvious issues locally…"
      );
    } else {
      flashAt(g, useAI ? "Proofreading changed paragraph with AI…" : "Fixing obvious issues locally…", 4000);
    }

    const fieldType = el.isContentEditable ? "contenteditable" : (el.tagName || "").toLowerCase();
    let bridge;
    try {
      bridge = useAI
        ? await bridgeProofreadParagraph(sent, fieldType)
        : { text: null, code: "localOnly", reviewRequired: false, message: "" };
    }
    finally { /* fixingGroup cleared below */ }

    if (BeanOverlay && typeof BeanOverlay.clearParagraphBusy === "function") {
      BeanOverlay.clearParagraphBusy();
    }

    // Field/selection may have changed while we waited → bail safely.
    if (el !== state.active || !document.contains(el) || eligibleEditableSurface(el) !== el) {
      state.fixingGroup = false;
      reason("fieldBecameIneligible");
      teardown();
      return;
    }

    let corrected = null, usedFallback = false;
    if (bridge.text !== null) {
      const clean = BeanMapping.sanitizeProofreadParagraphOutput(bridge.text);
      if (clean.zeroWidthStripped > 0) reason("zeroWidthStripped:" + clean.zeroWidthStripped);
      if (BeanTrustPolicy.isMeaningfulEdit(sent, clean.text)) corrected = clean.text;
      else reason("paragraphAINoEdit");
    }
    if (corrected === null) {
      if (bridge.text === null) reason("paragraphProofreadUnavailable");
      const local = localParagraphFix(sent);
      const clean = BeanMapping.sanitizeProofreadParagraphOutput(local);
      corrected = clean.text;
      usedFallback = true;
    }

    state.fixingGroup = false;

    if (corrected === null) {
      reason("paragraphProofreadUnavailable");
      flashAt(g, "Fix Paragraph unavailable");
      renderOverlay();
      restoreFieldFocus(el);
      return;
    }
    if (!corrected.trim()) {
      reason("paragraphProofreadUnsafeOutput");
      flashAt(g, "Couldn't fix paragraph");
      renderOverlay();
      restoreFieldFocus(el);
      return;
    }

    if (!usedFallback && bridge.reviewRequired) {
      const approved = await BeanOverlay.reviewParagraph(
        g.anchor, sent, corrected, bridge.message || "This result is unusually shaped. Review it before applying.");
      if (!approved) {
        state.fixingGroup = false;
        reason("paragraphReviewCancelled");
        renderOverlay();
        restoreFieldFocus(el);
        return;
      }
      reason("paragraphReviewApproved");
    }

    if (eligibleEditableSurface(el) !== el) {
      reason("fieldBecameIneligible");
      teardown();
      return;
    }

    // SAFETY: the paragraph must be byte-for-byte what we sent for proofread.
    if (!target.stillMatches(sent)) {
      reason("paragraphReplacementRefused");
      renderOverlay();
      restoreFieldFocus(el);
      return;
    }

    if (!BeanTrustPolicy.isMeaningfulEdit(sent, corrected)) {
      // Never turn unchanged provider output into an Apply/success state, and do
      // not hide existing local findings behind a misleading "looks good" result.
      reason("paragraphNoEdit");
      const noEditMessage = bridge.text !== null
        ? "AI found no additional changes"
        : (useAI ? "AI unavailable · no local fixes" : "No obvious local fixes");
      flashAt(g, noEditMessage);
      renderOverlay();
      restoreFieldFocus(el);
      return;
    }

    if (eligibleEditableSurface(el) !== el) {
      reason("fieldBecameIneligible");
      teardown();
      return;
    }

    const undoRecord = target.replace(corrected);
    if (!undoRecord) {
      reason("paragraphReplacementRefused");
      renderOverlay();
      restoreFieldFocus(el);
      return;
    }
    restoreFieldFocus(el);
    reason("paragraphReplacementVerified");
    reason(usedFallback ? "paragraphProofreadSucceededLocal" : "paragraphProofreadSucceeded");

    // Suppress re-detection of the paragraph we just corrected, drop its issues,
    // and resync fingerprints so we don't immediately re-show the same paragraph.
    rememberCorrected(corrected);
    undoRecord.correctedFingerprint = fingerprint(corrected);
    const ids = g.entries.map((e) => e.id);
    state.entries = state.entries.filter((e) => !ids.includes(e.id));
    const newText = getText(el);
    state.fingerprint = fingerprint(newText);
    state.shownFingerprint = state.fingerprint;
    flashAt(g, usedFallback ? "Fixed obvious issues locally" : "AI proofread applied");
    offerUndo(undoRecord);

    // The replace() dispatched input (onInput already cleared + rescheduled). The
    // rescheduled check will suppress the just-fixed paragraph via correctedFps.
  }

  function flashAt(g, msg, ms) {
    if (g && g.anchor) BeanOverlay.flash({ x: g.anchor.x, y: g.anchor.y, h: g.anchor.h || 18 }, msg, ms);
  }

  function applyIssue(id) {
    reason("buttonApplyClicked");
    const el = state.active;
    const entry = state.entries.find((e) => e.id === id);
    if (!el || !entry || !document.contains(el)) { teardown(); return; }
    if (eligibleEditableSurface(el) !== el) {
      reason("fieldBecameIneligible");
      teardown();
      return;
    }

    // SAFETY: only apply to a range whose live text equals issue.original.
    const verified = verifyTarget(el, entry);
    if (!verified) { reason("applyRangeMismatch"); dropIssue(id); return; } // drop, never replace nearby text
    reason("applyVerified");

    // Capture remaining BEFORE editing: the input event clears state.entries.
    const remaining = state.entries.filter((e) => e.id !== id).map((e) => e.issue);

    let ok = false, undoRecord = null;
    const anchor = fieldRect(el);
    if (verified.kind === "ce") {
      const offsets = BeanMapping.rangeOffsets(el, verified.range);
      const before = el.textContent;
      if (!offsets || before.slice(offsets.start, offsets.end) !== entry.issue.original) {
        reason("applyRangeMismatch"); dropIssue(id); return;
      }
      const after = BeanMapping.replaceRangePreservingBoundaries(
        before, offsets.start, offsets.end, entry.issue.suggestion
      );
      if (after === null) { reason("lineBreakRiskRefused"); dropIssue(id); return; }
      if (eligibleEditableSurface(el) !== el) {
        reason("fieldBecameIneligible"); teardown(); return;
      }
      const result = withBeanEdit(() =>
        BeanMapping.applyContentEditableRange(el, verified.range, entry.issue.suggestion, after)
      );
      ok = result.ok && el.textContent === after;
      if (ok) {
        undoRecord = contentEditableUndoRecord(
          el, offsets.start, before, after, entry.issue.original, entry.issue.suggestion,
          "issue", "Undo correction", anchor
        );
      }
    } else {
      const v = el.value;
      const next = BeanMapping.replaceRangePreservingBoundaries(v, verified.start, verified.end, entry.issue.suggestion);
      // Assert everything outside the replaced range is byte-for-byte unchanged.
      if (next === null || next.slice(0, verified.start) !== v.slice(0, verified.start) ||
          next.slice(verified.start + entry.issue.suggestion.length) !== v.slice(verified.end)) {
        reason("lineBreakRiskRefused"); dropIssue(id); return;
      }
      if (eligibleEditableSurface(el) !== el) {
        reason("fieldBecameIneligible"); teardown(); return;
      }
      const result = withBeanEdit(() =>
        BeanMapping.applyTextControlRange(el, verified.start, verified.end, entry.issue.suggestion)
      );
      ok = result.ok && el.value === next;
      if (ok) {
        undoRecord = valueUndoRecord(
          el, verified.start, v, next, entry.issue.original, entry.issue.suggestion,
          "issue", "Undo correction", anchor
        );
      }
    }
    if (!ok || !undoRecord) { teardown(); return; }
    restoreFieldFocus(el);
    reason("lineBreakPreserved");
    reason("applySucceeded");

    // Re-map remaining FROM SCRATCH against the new text (no offset shifting, no
    // stale ranges). Drop anything that no longer maps uniquely.
    state.reqGen++;
    const newText = getText(el);
    state.fingerprint = fingerprint(newText);
    state.shownFingerprint = state.fingerprint;
    state.entries = mapEntries(el, newText, remaining);
    if (!state.entries.length) {
      reason("remapDropped");
      clearOverlay();
    } else {
      reason("remapSucceeded");
      state.selectedId = state.entries[0].id;
      renderOverlay();
    }
    offerUndo(undoRecord);
  }

  // Content scripts often arrive after a page's autofocus event. Inspect the
  // already-focused element once blocklist settings are known, then repeat on
  // the next task for editors that finish focus setup during document_idle.
  loadSettings(() => {
    activateInitiallyFocusedField();
    setTimeout(activateInitiallyFocusedField, 0);
  });
})();
